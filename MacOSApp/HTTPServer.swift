import Foundation
import Network

final class HTTPServer {
    private let config: AppConfig
    private var listener: NWListener?

    init(config: AppConfig) {
        self.config = config
    }

    func start() {
        do {
            let params = NWParameters.tcp
            let port = NWEndpoint.Port(rawValue: config.webPort)!
            listener = try NWListener(using: params, on: port)
            listener?.newConnectionHandler = { connection in
                connection.start(queue: .global())
                self.handle(connection: connection)
            }
            listener?.start(queue: .global())
        } catch {
            print("HTTP server start failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                let request = String(decoding: data, as: UTF8.self)
                let response = self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func respond(to request: String) -> Data {
        let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
        if path.hasPrefix("/api/state") {
            return httpResponse(status: "200 OK", contentType: "application/json", body: DashboardState.shared.jsonData)
        }
        if path == "/" || path == "/index.html" {
            return httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Resources.indexHTML)
        }
        if path == "/styles.css" {
            return httpResponse(status: "200 OK", contentType: "text/css; charset=utf-8", body: Resources.stylesCSS)
        }
        if path == "/app.js" {
            return httpResponse(status: "200 OK", contentType: "text/javascript; charset=utf-8", body: Resources.appJS)
        }
        return httpResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var data = Data(headers.utf8)
        data.append(body)
        return data
    }
}
