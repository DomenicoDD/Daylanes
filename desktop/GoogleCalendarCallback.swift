import Foundation
import Network

@MainActor
final class GoogleCalendarCallback {
    struct Response {
        let code: String
        let redirect: URL
    }

    private static let path = "/oauth2/callback"
    private static let consentTimeout: Duration = .seconds(10 * 60)
    private let state: String
    private let listener: NWListener
    private var continuation: CheckedContinuation<Response, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var accepting = true

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleCalendarError.callbackUnavailable
        }
    }

    func receive(openBrowser: @escaping (URL) -> Bool) async throws -> Response {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: Self.consentTimeout) } catch { return }
                    self?.finish(.failure(GoogleCalendarError.consentTimedOut))
                }
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated { self?.listenerChanged(state, openBrowser: openBrowser) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated { self?.accept(connection) }
                }
                listener.start(queue: .main)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError())) }
        }
    }

    private var redirect: URL? {
        listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)" + Self.path) }
    }

    private func listenerChanged(_ update: NWListener.State, openBrowser: (URL) -> Bool) {
        switch update {
        case .ready:
            guard let redirect else {
                finish(.failure(GoogleCalendarError.callbackUnavailable))
                return
            }
            if !openBrowser(redirect) { finish(.failure(GoogleCalendarError.browserUnavailable)) }
        case .failed, .cancelled:
            finish(.failure(GoogleCalendarError.callbackUnavailable))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard accepting, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, header: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func read(_ connection: NWConnection, header: Data) {
        let limit = 8192
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit - header.count) {
            [weak self] chunk, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                let received = header + (chunk ?? Data())
                if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(to: connection, header: received.prefix(upTo: end.lowerBound))
                } else if done || error != nil || received.count >= limit {
                    self.close(connection)
                } else {
                    self.read(connection, header: received)
                }
            }
        }
    }

    private func respond(to connection: NWConnection, header: Data) {
        let result = accepting ? Self.result(header, state: state) : nil
        if result != nil { accepting = false }
        let message = result == nil ? "Invalid Daylanes sign-in request." : "You can close this tab and return to Daylanes."
        let status = result == nil ? "400 Bad Request" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n"
            + "Content-Length: \(message.utf8.count)\r\n\r\n\(message)"
        let redirect = self.redirect
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.close(connection)
                if let result, let redirect {
                    self.finish(result.map { Response(code: $0, redirect: redirect) })
                }
            }
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }

    private func finish(_ result: Result<Response, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        accepting = false
        timeout?.cancel()
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        continuation.resume(with: result)
    }

    /// Invalid or unrelated requests must leave the listener available for the real browser redirect.
    static func result(_ header: Data, state: String) -> Result<String, Error>? {
        guard let line = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first else { return nil }
        let request = line.split(separator: " ")
        guard request.count == 3, request[0] == "GET",
              request[1].hasPrefix(path + "?"),
              let query = URLComponents(string: String(request[1]))?.queryItems else { return nil }
        let states = query.filter { $0.name == "state" }
        let codes = query.filter { $0.name == "code" }
        let errors = query.filter { $0.name == "error" }
        guard states.count == 1, states.first?.value == state else { return nil }
        if errors.count == 1, codes.isEmpty { return .failure(GoogleCalendarError.consentDenied) }
        guard errors.isEmpty, codes.count == 1, let code = codes.first?.value, !code.isEmpty else { return nil }
        return .success(code)
    }
}
