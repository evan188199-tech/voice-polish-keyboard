import Foundation
import Network

enum BridgeFrame {
    static let delimiter: UInt8 = 0x0A
    static let maxBytes = 1_048_576

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(delimiter)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Server

final class BridgeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var running = false
    private var generation: UInt64 = 0
    private let ports: [UInt16]
    private let messageHandler: @Sendable (WireMessage, NWConnection) -> Void

    init(ports: [UInt16] = AppConstants.bridgePorts, messageHandler: @escaping @Sendable (WireMessage, NWConnection) -> Void) {
        self.ports = ports
        self.messageHandler = messageHandler
    }

    func start() {
        stop()
        lock.lock()
        generation &+= 1
        let epoch = generation
        running = true
        lock.unlock()
        var created: [NWListener] = []
        for port in ports {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            guard let listener = try? NWListener(using: parameters) else {
                continue
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.handleConnection(connection, epoch: epoch)
            }
            listener.start(queue: .global(qos: .userInitiated))
            created.append(listener)
        }
        lock.lock()
        let valid = running && generation == epoch
        if valid { listeners = created }
        lock.unlock()
        if !valid { created.forEach { $0.cancel() } }
    }

    func stop() {
        lock.lock()
        running = false
        generation &+= 1
        let current = listeners
        let activeConnections = Array(connections.values)
        listeners.removeAll()
        connections.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
        activeConnections.forEach { $0.cancel() }
    }

    private func handleConnection(_ connection: NWConnection, epoch: UInt64) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        guard running, generation == epoch else { lock.unlock(); connection.cancel(); return }
        connections[id] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forgetConnection(id)
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        let state = ConnectionBuffer()

        @Sendable func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                if let data {
                    state.append(data)
                }
                while true {
                    switch state.nextFrame() {
                    case .frame(let frame):
                        if let message = try? BridgeFrame.decode(WireMessage.self, from: frame) {
                            self.messageHandler(message, connection)
                        }
                    case .tooLarge:
                        self.forgetConnection(id)
                        connection.cancel()
                        return
                    case .incomplete:
                        if isComplete { self.forgetConnection(id); connection.cancel() } else { readMore() }
                        return
                    }
                }
            }
        }
        readMore()
    }

    private func forgetConnection(_ id: ObjectIdentifier) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }

    static func send(response: WireResponse, over connection: NWConnection) {
        guard let data = try? BridgeFrame.encode(response) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

final class ConnectionBuffer: @unchecked Sendable {
    enum Result: Equatable { case frame(Data), incomplete, tooLarge }
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func nextFrame() -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = buffer.firstIndex(of: BridgeFrame.delimiter) else {
            return buffer.count > BridgeFrame.maxBytes ? .tooLarge : .incomplete
        }
        guard buffer.distance(from: buffer.startIndex, to: idx) <= BridgeFrame.maxBytes else { return .tooLarge }
        let frame = Data(buffer[..<idx])
        buffer.removeSubrange(...idx)
        return .frame(frame)
    }
}

// MARK: - Client

actor BridgeClient {
    private var connection: NWConnection?
    private let token: String
    private let ports: [UInt16]
    /// NWConnection supports streaming, but this client previously issued
    /// overlapping receives for concurrent commands. Serialize requests so a
    /// response can never be delivered to the wrong caller.
    private var requestInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(token: String = BuildToken.generate(), ports: [UInt16] = AppConstants.bridgePorts) {
        self.token = token
        self.ports = ports
    }

    func connect() async -> Bool {
        if let connection, connection.state == .ready {
            return true
        }
        for port in ports {
            if await tryPort(port) { return true }
        }
        return false
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func send(
        _ command: BridgeCommand,
        polishEnabled: Bool? = nil,
        polishMode: String? = nil,
        chineseScript: String? = nil,
        jobID: UUID? = nil,
        clipboardEntries: [ClipboardEntry]? = nil,
        translationPayload: TranslationBridgePayload? = nil,
        timeoutSeconds: Double = 4
    ) async throws -> WireResponse {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }

        try Task.checkCancellation()
        if connection?.state != .ready {
            guard await connect() else { throw BridgeError.notConnected }
        }
        do { try Task.checkCancellation() }
        catch { disconnect(); throw error }
        guard let connection else { throw BridgeError.notConnected }

        let message = WireMessage(
            command: command,
            token: token,
            polishEnabled: polishEnabled,
            polishMode: polishMode,
            jobID: jobID,
            chineseScript: chineseScript,
            clipboardEntries: clipboardEntries,
            translationPayload: translationPayload
        )
        let data = try BridgeFrame.encode(message)

        // A suspended companion may keep TCP open without replying. Bound the
        // request so a lost start acknowledgement cannot lock the keyboard forever.
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer { timeout.cancel() }

        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WireResponse, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    Self.receive(on: connection, buffer: Data(), continuation: continuation)
                })
            }
        } catch {
            connection.cancel()
            if self.connection === connection {
                self.connection = nil
            }
            throw error
        }
    }

    private func acquireRequestSlot() async {
        if !requestInFlight {
            requestInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            requestInFlight = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    private func tryPort(_ port: UInt16) async -> Bool {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let ready = await withCheckedContinuation { continuation in
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                private let continuation: CheckedContinuation<Bool, Never>

                init(_ continuation: CheckedContinuation<Bool, Never>) {
                    self.continuation = continuation
                }

                func resume(_ value: Bool) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: value)
                }
            }

            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(true)
                case .failed, .cancelled:
                    once.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                if connection.state != .ready {
                    connection.cancel()
                    once.resume(false)
                }
            }
        }
        if ready { self.connection = connection } else { connection.cancel() }
        return ready
    }

    private nonisolated static func receive(
        on connection: NWConnection,
        buffer: Data,
        continuation: CheckedContinuation<WireResponse, Error>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            let frameLength = accumulated.firstIndex(of: BridgeFrame.delimiter).map { accumulated.distance(from: accumulated.startIndex, to: $0) } ?? accumulated.count
            guard frameLength <= BridgeFrame.maxBytes else {
                connection.cancel()
                continuation.resume(throwing: BridgeError.frameTooLarge)
                return
            }
            guard let idx = accumulated.firstIndex(of: BridgeFrame.delimiter) else {
                if isComplete {
                    continuation.resume(throwing: BridgeError.connectionClosed)
                } else {
                    Self.receive(on: connection, buffer: accumulated, continuation: continuation)
                }
                return
            }
            do {
                let response = try BridgeFrame.decode(WireResponse.self, from: Data(accumulated[..<idx]))
                continuation.resume(returning: response)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum BridgeError: Error, LocalizedError {
    case notConnected
    case decodeFailed
    case connectionClosed
    case frameTooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected: return "未连接主应用"
        case .decodeFailed: return "通信解析失败"
        case .connectionClosed: return "连接已断开"
        case .frameTooLarge: return "通信内容过长，请在历史记录中恢复文本"
        }
    }

    var bridgeErrorCode: BridgeErrorCode {
        switch self {
        case .notConnected, .connectionClosed: return .companionNotRunning
        case .decodeFailed, .frameTooLarge: return .unknown
        }
    }
}
