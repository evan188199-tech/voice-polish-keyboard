import Foundation
import Network

enum BridgeFrame {
    static let delimiter: UInt8 = 0x0A

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
    private let messageHandler: @Sendable (WireMessage, NWConnection) -> Void

    init(messageHandler: @escaping @Sendable (WireMessage, NWConnection) -> Void) {
        self.messageHandler = messageHandler
    }

    func start() {
        stop()
        var created: [NWListener] = []
        for port in AppConstants.bridgePorts {
            guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else {
                continue
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            created.append(listener)
        }
        lock.lock()
        listeners = created
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let current = listeners
        listeners.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        let state = ConnectionBuffer()

        @Sendable func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                if let data {
                    state.append(data)
                }
                while let frame = state.nextFrame() {
                    if let message = try? BridgeFrame.decode(WireMessage.self, from: frame) {
                        self.messageHandler(message, connection)
                    }
                }
                if isComplete {
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    static func send(response: WireResponse, over connection: NWConnection) {
        guard let data = try? BridgeFrame.encode(response) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

private final class ConnectionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func nextFrame() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = buffer.firstIndex(of: BridgeFrame.delimiter) else { return nil }
        let frame = Data(buffer[..<idx])
        buffer.removeSubrange(...idx)
        return frame
    }
}

// MARK: - Client

actor BridgeClient {
    private var connection: NWConnection?
    private let token: String

    init(token: String = BuildToken.generate()) {
        self.token = token
    }

    func connect() async -> Bool {
        if let connection, connection.state == .ready {
            return true
        }
        for port in AppConstants.bridgePorts {
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
        jobID: UUID? = nil
    ) async throws -> WireResponse {
        if connection?.state != .ready {
            guard await connect() else { throw BridgeError.notConnected }
        }
        guard let connection else { throw BridgeError.notConnected }

        let message = WireMessage(
            command: command,
            token: token,
            polishEnabled: polishEnabled,
            polishMode: polishMode,
            jobID: jobID,
            chineseScript: chineseScript
        )
        let data = try BridgeFrame.encode(message)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WireResponse, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                Self.receive(on: connection, continuation: continuation)
            })
        }
    }

    private func tryPort(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
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
            let connection = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { await self?.setConnection(connection) }
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
    }

    private func setConnection(_ connection: NWConnection) {
        self.connection = connection
    }

    private nonisolated static func receive(
        on connection: NWConnection,
        continuation: CheckedContinuation<WireResponse, Error>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let data, let idx = data.firstIndex(of: BridgeFrame.delimiter) else {
                if isComplete {
                    continuation.resume(throwing: BridgeError.connectionClosed)
                } else {
                    Self.receive(on: connection, continuation: continuation)
                }
                return
            }
            do {
                let response = try BridgeFrame.decode(WireResponse.self, from: Data(data[..<idx]))
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

    var errorDescription: String? {
        switch self {
        case .notConnected: return "未连接主应用"
        case .decodeFailed: return "通信解析失败"
        case .connectionClosed: return "连接已断开"
        }
    }

    var bridgeErrorCode: BridgeErrorCode {
        switch self {
        case .notConnected, .connectionClosed: return .companionNotRunning
        case .decodeFailed: return .unknown
        }
    }
}
