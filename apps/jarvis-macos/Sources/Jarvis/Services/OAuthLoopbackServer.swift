import AppKit
import Foundation
import Network

final class OAuthLoopbackServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case unavailable
        case invalidCallback
        case browserUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Le retour OAuth local est indisponible."
            case .invalidCallback: return "Le retour OAuth Google est invalide."
            case .browserUnavailable: return "Le navigateur n'a pas pu ouvrir Google."
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.adansonia.jarvis.google-oauth")
    private let callbackLock = NSLock()
    private var didCompleteCallback = false

    private init(port: NWEndpoint.Port) throws {
        listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { connection in connection.cancel() }
    }

    static func start() async throws -> OAuthLoopbackServer {
        var lastError: Error?
        for _ in 0..<20 {
            guard let port = NWEndpoint.Port(rawValue: UInt16.random(in: 49_152...65_535)) else { continue }
            do {
                let server = try OAuthLoopbackServer(port: port)
                try await server.startListening()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ServerError.unavailable
    }

    var redirectURI: String {
        // Safari permits HTTP loopback callbacks through localhost when HTTPS-only mode is enabled.
        "http://localhost:\(listener.port?.rawValue ?? 0)/oauth2callback"
    }

    func cancel() {
        listener.cancel()
    }

    func receiveCallback(opening authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection, continuation: continuation)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ServerError.browserUnavailable)
                    return
                }
                // Chrome does not inherit Safari's HTTPS-only preference, which blocks HTTP loopback redirects.
                if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                    NSWorkspace.shared.open([authorizationURL], withApplicationAt: chrome, configuration: .init()) { _, error in
                        if error != nil {
                            self.listener.cancel()
                            continuation.resume(throwing: ServerError.browserUnavailable)
                        }
                    }
                } else if !NSWorkspace.shared.open(authorizationURL) {
                    self.listener.cancel()
                    continuation.resume(throwing: ServerError.browserUnavailable)
                }
            }
        }
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: ServerError.unavailable)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection, continuation: CheckedContinuation<URL, Error>) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            defer {
                connection.cancel()
                self.listener.cancel()
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\r\n").first,
                  firstLine.hasPrefix("GET "),
                  let target = firstLine.split(separator: " ").dropFirst().first,
                  let callbackURL = URL(string: "http://localhost\(target)") else {
                guard self.claimCallback() else { return }
                continuation.resume(throwing: ServerError.invalidCallback)
                return
            }

            guard self.claimCallback() else { return }

            let body = "<html><body style='font-family:-apple-system;padding:40px'><h2>Gmail est connecte a Jarvis.</h2><p>Tu peux fermer cette page.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            continuation.resume(returning: callbackURL)
        }
    }

    private func claimCallback() -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard !didCompleteCallback else { return false }
        didCompleteCallback = true
        return true
    }
}
