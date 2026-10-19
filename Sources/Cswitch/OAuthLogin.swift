import CswitchCore
import CryptoKit
import Foundation
import Network

/// An in-app PKCE flow; neither a terminal nor a CLI login process is launched.
/// The callback listener is bound only to IPv4 loopback, never a public interface.
@MainActor
final class OAuthLogin {
    nonisolated static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    nonisolated static let redirectURI = "http://localhost:53692/callback"
    let verifier = OAuthLogin.randomURLSafe(bytes: 64)
    let state = OAuthLogin.randomURLSafe(bytes: 32)
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, Error>?
    private var pending: CheckedContinuation<String, Error>?
    private var receivedCode: String?
    private var timeout: Task<Void, Never>?
    private var stopped = false
    private var stopError: Error?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func begin() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 53692)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] value in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                switch value {
                case .ready:
                    self.ready?.resume(); self.ready = nil
                case .failed:
                    self.fail(CswitchError.message("Could not start the sign-in callback on localhost:53692. Close another pending OAuth login and try again."))
                default: break
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready = continuation
            listener.start(queue: .global(qos: .userInitiated))
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.fail(CswitchError.message("Sign-in timed out. Start a new sign-in and try again."))
        }
        var url = URLComponents(string: "https://claude.ai/oauth/authorize")!
        let challenge = Self.urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
        url.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return url.url!
    }

    func waitForCode() async throws -> String {
        if let receivedCode { return receivedCode }
        if stopped { throw stopError ?? CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in pending = continuation }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func submit(_ pasted: String) throws {
        guard !stopped else { throw CswitchError.message("Start a new sign-in first.") }
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        var code: String
        if let url = URLComponents(string: text), url.scheme != nil {
            guard url.scheme == "http", url.user == nil, url.password == nil,
                  url.host == "localhost" || url.host == "127.0.0.1",
                  url.path == "/callback", url.port == 53692,
                  url.queryItems?.filter({ $0.name == "state" }).count == 1,
                  url.queryItems?.first(where: { $0.name == "state" })?.value == state else {
                throw CswitchError.message("This callback does not match the current sign-in.")
            }
            if url.queryItems?.contains(where: { $0.name == "error" }) == true {
                fail(CswitchError.message("Claude did not authorize this sign-in. Start a new sign-in and try again."))
                return
            }
            guard url.queryItems?.filter({ $0.name == "code" }).count == 1,
                  let value = url.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw CswitchError.message("This callback does not match the current sign-in.")
            }
            code = value
        } else {
            let pieces = text.split(separator: "#", maxSplits: 1).map(String.init)
            code = pieces.first ?? ""
            if pieces.count > 1, pieces[1] != state { throw CswitchError.message("This code belongs to a different sign-in.") }
        }
        guard !code.isEmpty, code.count < 4096, !code.contains(where: \.isWhitespace) else {
            throw CswitchError.message("Paste the authorization code or the localhost callback URL.")
        }
        complete(code)
    }

    func cancel() { fail(CancellationError()) }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .global(qos: .userInitiated))
        read(connection, accumulated: Data())
        Task { [weak self, weak connection] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if let connection { self?.close(connection) }
        }
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, finished, error in
            Task { @MainActor in
                guard let self, !self.stopped else { connection.cancel(); return }
                let all = accumulated + (data ?? Data())
                guard all.count <= 16384 else { self.respond(connection, status: "400 Bad Request", text: "Invalid callback."); return }
                if let request = String(data: all, encoding: .utf8), request.contains("\r\n\r\n") {
                    self.handle(request, connection: connection)
                } else if error != nil || finished { self.close(connection) }
                else { self.read(connection, accumulated: all) }
            }
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        let line = request.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
        guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/callback?"),
              let url = URLComponents(string: Self.redirectURI + String(line[1].dropFirst("/callback".count)))?.url else {
            respond(connection, status: "400 Bad Request", text: "This callback does not match the current sign-in.")
            return
        }
        do {
            try submit(url.absoluteString)
            respond(connection, status: "200 OK", text: "Authorization received. Return to Cswitch to finish signing in. You can close this window.")
        } catch {
            respond(connection, status: "400 Bad Request", text: "This callback does not match the current sign-in.")
        }
    }

    private func respond(_ connection: NWConnection, status: String, text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel(); connections[ObjectIdentifier(connection)] = nil
    }

    private func complete(_ code: String) {
        guard !stopped else { return }
        receivedCode = code
        pending?.resume(returning: code); pending = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        stopped = true
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true; stopError = error
        ready?.resume(throwing: error); ready = nil
        pending?.resume(throwing: error); pending = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var random = SystemRandomNumberGenerator()
        return urlSafe(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
    }

    private static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
