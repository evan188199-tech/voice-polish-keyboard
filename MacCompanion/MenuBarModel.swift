import Foundation
import Combine
import SwiftUI

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var title = "语音"
    @Published var symbolName = "mic"
    private var coordinator: VoiceSessionCoordinator?

    func bind(coordinator: VoiceSessionCoordinator) {
        self.coordinator = coordinator
        // Poll lightweight status for menu label.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let coordinator = self.coordinator else { return }
                self.apply(
                    state: coordinator.state,
                    message: coordinator.statusMessage,
                    inputName: coordinator.currentInputName,
                    inputReady: coordinator.isInputReady
                )
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func apply(
        state: BridgeStatus.State,
        message: String?,
        inputName: String?,
        inputReady: Bool
    ) {
        switch state {
        case .inactive:
            title = "未启动"
            symbolName = "mic.slash"
        case .ready:
            if !inputReady {
                title = "切换中"
                symbolName = "mic.badge.xmark"
            } else if let inputName, !inputName.isEmpty {
                title = shortMicTitle(inputName)
                symbolName = "mic"
            } else {
                title = "就绪"
                symbolName = "mic"
            }
        case .recording:
            title = "录音中"
            symbolName = "mic.fill"
        case .transcribing:
            title = "识别中"
            symbolName = "waveform"
        case .polishing:
            title = message ?? "润色中"
            symbolName = "sparkles"
        case .error:
            title = "错误"
            symbolName = "exclamationmark.triangle"
        }
        _ = message
    }

    private func shortMicTitle(_ name: String) -> String {
        // Keep menu bar compact: "AirPods 麦克风" -> "AirPods"
        let trimmed = name
            .replacingOccurrences(of: " 麦克风", with: "")
            .replacingOccurrences(of: "麦克风", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "就绪" }
        if trimmed.count <= 10 { return trimmed }
        return String(trimmed.prefix(9)) + "…"
    }
}
