import Foundation
import Network

actor KeyboardBridgeServer {
    private var server: BridgeServer?
    // Main-actor object; bridge hops back with await on each call.
    nonisolated(unsafe) private weak var coordinator: VoiceSessionCoordinator?

    init(coordinator: VoiceSessionCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        server = BridgeServer { [weak self] message, connection in
            guard let self else { return }
            Task { await self.handle(message, connection) }
        }
        server?.start()
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func handle(_ message: WireMessage, _ connection: NWConnection) async {
        guard BuildToken.validate(message.token) else {
            BridgeServer.send(
                response: WireResponse(requestID: message.requestID, response: .unauthorized),
                over: connection
            )
            return
        }

        if message.protocolVersion != AppConstants.protocolVersion {
            BridgeServer.send(
                response: WireResponse(
                    requestID: message.requestID,
                    response: .error("桥接协议版本不匹配，请重新安装主应用与键盘扩展", code: .unknown)
                ),
                over: connection
            )
            return
        }

        guard let coordinator else {
            BridgeServer.send(
                response: WireResponse(requestID: message.requestID, response: .error("主应用不可用", code: .companionNotRunning)),
                over: connection
            )
            return
        }

        switch message.command {
        case .ping:
            let status = await coordinator.currentStatus
            BridgeServer.send(
                response: WireResponse(requestID: message.requestID, response: .ok(status: status)),
                over: connection
            )
        case .start:
            let statusBefore = await coordinator.currentStatus
            if statusBefore.state == .inactive {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("请先在伴随应用中启动语音会话", status: statusBefore, code: .companionNotRunning)
                    ),
                    over: connection
                )
                return
            }
            if statusBefore.state == .error {
                let code = await coordinator.lastErrorCode ?? .unknown
                if code == .micDenied || code == .modelNotReady {
                    BridgeServer.send(
                        response: WireResponse(
                            requestID: message.requestID,
                            response: .error(statusBefore.message ?? "不可用", status: statusBefore, code: code)
                        ),
                        over: connection
                    )
                    return
                }
            }
            // Retries cover PCM finalize and short microphone route-recovery windows
            // after Bluetooth headset connect/disconnect.
            var status = await coordinator.currentStatus
            var started = false
            for attempt in 0..<12 {
                started = await coordinator.startRecording()
                status = await coordinator.currentStatus
                if started || status.state == .recording {
                    started = true
                    break
                }
                if status.state == .inactive { break }
                let code = await coordinator.lastErrorCode
                if status.state == .error {
                    if code == .micDenied || code == .modelNotReady { break }
                }
                if attempt < 11 {
                    let delay: UInt64 = (code == .inputSessionInvalid) ? 100_000_000 : 30_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
            if started, status.state == .recording {
                BridgeServer.send(
                    response: WireResponse(requestID: message.requestID, response: .ok(status: status)),
                    over: connection
                )
            } else {
                // Re-read once more in case finalize just completed.
                status = await coordinator.currentStatus
                if status.state == .recording {
                    BridgeServer.send(
                        response: WireResponse(requestID: message.requestID, response: .ok(status: status)),
                        over: connection
                    )
                } else {
                    let code = await coordinator.lastErrorCode ?? .busy
                    BridgeServer.send(
                        response: WireResponse(
                            requestID: message.requestID,
                            response: .error(status.message ?? "启动失败", status: status, code: code)
                        ),
                        over: connection
                    )
                }
            }
        case .finish:
            // Enqueue only; do not wait for ASR / polish.
            let jobID = await coordinator.finishRecordingAndEnqueue()
            let status = await coordinator.currentStatus
            if let jobID {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, message: "已提交", jobID: jobID)
                    ),
                    over: connection
                )
            } else {
                let msg = status.message ?? "结束录音失败"
                let code: BridgeErrorCode = status.state == .recording ? .unknown : .notRecording
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error(msg, status: status, code: code)
                    ),
                    over: connection
                )
            }
        case .cancel:
            await coordinator.cancelRecording()
            let status = await coordinator.currentStatus
            BridgeServer.send(
                response: WireResponse(requestID: message.requestID, response: .ok(status: status)),
                over: connection
            )
        case .status:
            let requestedJobID = message.jobID
            let delivery = await coordinator.takeBridgeOutcome(jobID: requestedJobID)
            if let outcome = delivery.outcome {
                switch outcome {
                case .text(let text):
                    let status = await coordinator.currentStatus
                    BridgeServer.send(
                        response: WireResponse(
                            requestID: message.requestID,
                            response: .text(text, status: status, jobID: delivery.jobID)
                        ),
                        over: connection
                    )
                case .failed(let failureMessage):
                    let status = await coordinator.statusForJob(requestedJobID)
                    BridgeServer.send(
                        response: WireResponse(
                            requestID: message.requestID,
                            response: .error(failureMessage, status: status, code: .unknown, jobID: requestedJobID)
                        ),
                        over: connection
                    )
                case .discarded:
                    let status = await coordinator.currentStatus
                    BridgeServer.send(
                        response: WireResponse(
                            requestID: message.requestID,
                            response: .error("已丢弃", status: status, code: .discarded, jobID: requestedJobID)
                        ),
                        over: connection
                    )
                case .pending:
                    let status = await coordinator.statusForJob(requestedJobID)
                    BridgeServer.send(
                        response: WireResponse(
                            requestID: message.requestID,
                            response: .ok(status: status, jobID: requestedJobID)
                        ),
                        over: connection
                    )
                }
            } else {
                let status = await coordinator.statusForJob(requestedJobID)
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, jobID: requestedJobID)
                    ),
                    over: connection
                )
            }
        case .setPolishEnabled:
            guard let enabled = message.polishEnabled else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("缺少润色开关参数", code: .unknown)
                    ),
                    over: connection
                )
                return
            }
            let ok = await coordinator.setPolishEnabled(enabled)
            let status = await coordinator.currentStatus
            if ok {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, message: enabled ? "已开启润色" : "已关闭润色")
                    ),
                    over: connection
                )
            } else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("主应用设置不可用", status: status, code: .companionNotRunning)
                    ),
                    over: connection
                )
            }
        case .setPolishMode:
            guard let raw = message.polishMode, let mode = PolishMode(rawValue: raw) else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("缺少或无效的润色模式", code: .unknown)
                    ),
                    over: connection
                )
                return
            }
            let ok = await coordinator.setPolishMode(mode)
            let status = await coordinator.currentStatus
            if ok {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, message: "已切换到\(mode.displayName)")
                    ),
                    over: connection
                )
            } else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("主应用设置不可用", status: status, code: .companionNotRunning)
                    ),
                    over: connection
                )
            }
        case .cyclePolishMode:
            let ok = await coordinator.cyclePolishMode()
            let status = await coordinator.currentStatus
            let summary = await coordinator.polishStateSummary
            if ok {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, message: "模式：\(summary)")
                    ),
                    over: connection
                )
            } else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("主应用设置不可用", status: status, code: .companionNotRunning)
                    ),
                    over: connection
                )
            }
        case .setChineseScript:
            guard let raw = message.chineseScript,
                  let pref = ChineseScriptPreference(rawValue: raw) else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("缺少或无效的字体参数", code: .unknown)
                    ),
                    over: connection
                )
                return
            }
            let ok = await coordinator.setChineseScript(pref)
            let status = await coordinator.currentStatus
            if ok {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, message: "已切换到\(pref.shortLabel)体")
                    ),
                    over: connection
                )
            } else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("主应用设置不可用", status: status, code: .companionNotRunning)
                    ),
                    over: connection
                )
            }
        case .armAskFollowUp:
            let ok = await coordinator.armAskFollowUp()
            let status = await coordinator.currentStatus
            if ok {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .ok(status: status, message: "追问已就绪 · 按住说话")
                    ),
                    over: connection
                )
            } else {
                BridgeServer.send(
                    response: WireResponse(
                        requestID: message.requestID,
                        response: .error("暂无可以追问的问答上下文", status: status, code: .unknown)
                    ),
                    over: connection
                )
            }
        case .clearAskConversation:
            await coordinator.clearAskConversation()
            let status = await coordinator.currentStatus
            BridgeServer.send(
                response: WireResponse(
                    requestID: message.requestID,
                    response: .ok(status: status, message: "已开始新的问答")
                ),
                over: connection
            )
        case .syncClipboardHistory:
            let incoming = message.clipboardEntries ?? []
            let visible = ClipboardMirrorStore.shared.merge(incoming)
            let status = await coordinator.currentStatus
            BridgeServer.send(
                response: WireResponse(
                    requestID: message.requestID,
                    response: .ok(status: status, message: "已同步", clipboardEntries: visible)
                ),
                over: connection
            )
        case .clearClipboardHistory:
            ClipboardMirrorStore.shared.clear()
            let status = await coordinator.currentStatus
            BridgeServer.send(
                response: WireResponse(
                    requestID: message.requestID,
                    response: .ok(status: status, message: "已清空剪切板镜像")
                ),
                over: connection
            )
        }
    }
}
