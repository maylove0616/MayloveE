import Foundation
import os

enum JSONRPCError: LocalizedError {
    case server(code: Int, message: String)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .server(let code, let message): return "Language server error \(code): \(message)"
        case .connectionClosed: return "Language server connection closed"
        }
    }
}

/// JSON-RPC 2.0 over a pair of pipes. All callbacks are delivered on the main actor, in order.
@MainActor
final class JSONRPCConnection {
    nonisolated private static let logger = Logger(subsystem: "MayloveE", category: "JSONRPC")

    /// Called for server notifications.
    var onNotification: ((String, JSONValue) -> Void)?
    /// Called for server-to-client requests; the return value is sent back as the result.
    var onRequest: ((String, JSONValue) -> JSONValue)?
    var onClose: (() -> Void)?

    private let output: FileHandle
    private let writeQueue = DispatchQueue(label: "MayloveE.jsonrpc.write")
    private var framer = MessageFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var isClosed = false

    init(readingFrom input: FileHandle, writingTo output: FileHandle) {
        self.output = output
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            // The main queue is FIFO, which keeps messages in arrival order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if data.isEmpty {
                        self?.close()
                    } else {
                        self?.receive(data)
                    }
                }
            }
        }
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard !isClosed else { throw JSONRPCError.connectionClosed }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        guard !isClosed else { return }
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: JSONRPCError.connectionClosed) }
        onClose?()
    }

    private func send(_ message: JSONValue) {
        let body: Data
        do {
            body = try JSONEncoder().encode(message)
        } catch {
            Self.logger.error("Cannot encode message: \(String(describing: error), privacy: .public)")
            return
        }
        let output = self.output
        writeQueue.async {
            do {
                try output.write(contentsOf: MessageFramer.frame(body))
            } catch {
                Self.logger.error("Write to language server failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func receive(_ data: Data) {
        for body in framer.append(data) {
            let message: JSONValue
            do {
                message = try JSONDecoder().decode(JSONValue.self, from: body)
            } catch {
                Self.logger.error("Malformed message from language server: \(String(describing: error), privacy: .public)")
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        let id = message["id"]
        if let method = message["method"]?.stringValue {
            let params = message["params"] ?? .null
            if let id {
                let result = onRequest?(method, params) ?? .null
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } else {
                onNotification?(method, params)
            }
            return
        }

        guard let requestID = id?.intValue, let continuation = pending.removeValue(forKey: requestID) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: JSONRPCError.server(code: error["code"]?.intValue ?? 0,
                                                             message: error["message"]?.stringValue ?? ""))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }
}
