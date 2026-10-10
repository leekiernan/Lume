import Foundation
import Network

/// Real loopback HTTP: URLProtocol stubs do not exercise download-file and 304
/// handling reliably. Each test owns a listener on its own ephemeral port.
final nonisolated class GuideHTTPServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = "<tv></tv>"
        var delay: TimeInterval = 0
    }

    private let listener: NWListener

    init(reply: @escaping @Sendable (String) -> Response) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.receive(connection, collected: Data(), reply: reply)
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/guide.xml")!)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }

    private static func receive(_ connection: NWConnection, collected: Data, reply: @escaping @Sendable (String) -> Response) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            let bytes = collected + (data ?? Data())
            let request = String(data: bytes, encoding: .utf8) ?? ""
            guard request.contains("\r\n\r\n") else {
                if complete || error != nil {
                    connection.cancel()
                } else {
                    receive(connection, collected: bytes, reply: reply)
                }
                return
            }
            let response = reply(request)
            let body = response.status == 304 ? Data() : Data(response.body.utf8)
            let headers = response.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            let head = "HTTP/1.1 \(response.status) Response\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(headers)\r\n"
            let content = Data(head.utf8) + body
            if response.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) {
                    connection.send(content: content, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else {
                connection.send(content: content, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
