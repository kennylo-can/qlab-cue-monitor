import Foundation
import Network
import CryptoKit

// MARK: - Lightweight WebSocket Server + State Broadcaster

final class DashboardWebSocketServer {
    private var listener: NWListener?
    private var clients: Set<NWConnection> = []
    private let queue = DispatchQueue(label: "com.codex.dashboard.ws")
    private let port: UInt16
    var onClientCountChange: ((Int) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            listener?.start(queue: queue)
        } catch {
            print("WebSocket server start failed: \(error)")
        }
    }

    func stop() {
        for client in clients { client.cancel() }
        clients.removeAll()
        listener?.cancel()
        listener = nil
    }

    func broadcast(json: String) {
        guard !json.isEmpty else { return }
        let frame = encodeWebSocketFrame(text: json)
        for client in clients {
            client.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    // Also serve HTTP for initial page load
    private func handleNewConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                if request.contains("Upgrade: websocket") {
                    self?.upgradeToWebSocket(conn, request: request)
                } else {
                    self?.serveHTTP(conn, request: request)
                }
            } else {
                conn.cancel()
            }
        }
    }

    private func upgradeToWebSocket(_ conn: NWConnection, request: String) {
        let key = request.components(separatedBy: "Sec-WebSocket-Key: ")
            .dropFirst().first?
            .components(separatedBy: "\r\n").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let acceptKey = Data("\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8)
        let sha1 = Insecure.SHA1.hash(data: acceptKey)
        let accept = Data(sha1).base64EncodedString()

        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "",
            "",
        ].joined(separator: "\r\n")

        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        clients.insert(conn)

        DispatchQueue.main.async { [weak self] in
            self?.onClientCountChange?(self?.clients.count ?? 0)
        }

        // Send initial state
        if let json = WebSocketState.shared.lastJSON {
            conn.send(content: encodeWebSocketFrame(text: json), completion: .contentProcessed { _ in })
        }

        receiveWS(conn)
    }

    private func receiveWS(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.clients.remove(conn)
                conn.cancel()
                DispatchQueue.main.async {
                    self?.onClientCountChange?(self?.clients.count ?? 0)
                }
            } else {
                self?.receiveWS(conn)
            }
        }
    }

    private func serveHTTP(_ conn: NWConnection, request: String) {
        let pathLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = pathLine.components(separatedBy: " ")
        let path = parts.count > 1 ? parts[1] : "/"

        if parts.first == "HEAD" {
            conn.send(content: httpResponse(status: "200 OK", contentType: "text/html", body: Data()), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        let (status, contentType, body): (String, String, Data) = {
            switch path {
            case "/", "/index.html":
                return ("200 OK", "text/html; charset=utf-8", DashboardHTML.content)
            case "/app.js":
                return ("200 OK", "text/javascript; charset=utf-8", DashboardHTML.appJS)
            case "/styles.css":
                return ("200 OK", "text/css; charset=utf-8", DashboardHTML.stylesCSS)
            default:
                return ("404 Not Found", "text/plain", Data("Not found".utf8))
            }
        }()

        conn.send(content: httpResponse(status: status, contentType: contentType, body: body), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        let h = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "",
            "",
        ].joined(separator: "\r\n")
        var d = Data(h.utf8)
        d.append(body)
        return d
    }
}

// MARK: - WebSocket State Singleton

final class WebSocketState {
    static let shared = WebSocketState()

    private let lock = NSLock()
    private var state: [String: Any] = [:]
    private(set) var lastJSON: String?
    private var server: DashboardWebSocketServer?

    func startServer(port: UInt16) {
        server = DashboardWebSocketServer(port: port)
        server?.start()
    }

    func stopServer() {
        server?.stop()
        server = nil
    }

    func update(_ dict: [String: Any]) {
        lock.lock()
        for (key, value) in dict { state[key] = value }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: []),
           let json = String(data: data, encoding: .utf8) {
            lastJSON = json
            server?.broadcast(json: json)
        }
        lock.unlock()
    }

    func currentState() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

// MARK: - WebSocket Frame Encoder

private func encodeWebSocketFrame(text: String) -> Data {
    let payload = Data(text.utf8)
    let len = payload.count
    let header: Data
    if len < 126 {
        var h = Data(capacity: 2)
        h.append(0x81)
        h.append(UInt8(len))
        header = h
    } else if len < 65536 {
        var h = Data(capacity: 4)
        h.append(0x81)
        h.append(126)
        var s = UInt16(len).bigEndian
        h.append(Data(bytes: &s, count: 2))
        header = h
    } else {
        var h = Data(capacity: 10)
        h.append(0x81)
        h.append(127)
        var s = UInt64(len).bigEndian
        h.append(Data(bytes: &s, count: 8))
        header = h
    }
    var frame = header
    frame.append(payload)
    return frame
}

// MARK: - Embedded Dashboard HTML/JS/CSS

enum DashboardHTML {
    static let content = Data(
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>QLab Direct OSC Dashboard</title>
    <link rel="stylesheet" href="styles.css">
    </head>
    <body>
    <div class="container">
      <header>
        <h1 id="workspace-label">QLab Dashboard</h1>
        <span id="status-badge" class="badge disconnected">DISCONNECTED</span>
      </header>
      <main>
        <section class="cue-section">
          <div class="cue-card" id="current-cue-card">
            <div class="label">CURRENT CUE</div>
            <div class="cue-name" id="current-cue-name">--</div>
            <div class="cue-number" id="current-cue-number">--</div>
            <div class="cue-type" id="current-cue-type"></div>
          </div>
          <div class="cue-card" id="next-cue-card">
            <div class="label">NEXT CUE</div>
            <div class="cue-name" id="next-cue-name">--</div>
            <div class="cue-number" id="next-cue-number">--</div>
            <div class="cue-type" id="next-cue-type"></div>
          </div>
        </section>
        <section class="time-section">
          <div class="time-box">
            <div class="label">TIMECODE</div>
            <div class="value large" id="timecode">--:--:--:--</div>
          </div>
          <div class="time-box">
            <div class="label">COUNTDOWN</div>
            <div class="value large" id="countdown">--:--</div>
          </div>
          <div class="time-box">
            <div class="label">ELAPSED</div>
            <div class="value" id="elapsed">--:--</div>
          </div>
          <div class="time-box">
            <div class="label">PROGRESS</div>
            <div class="progress-bar"><div class="progress-fill" id="progress-bar"></div></div>
            <div class="value" id="progress-text">0%</div>
          </div>
        </section>
        <section class="log-section">
          <div class="label">EVENT LOG</div>
          <div class="log-container" id="log-container"></div>
        </section>
      </main>
    </div>
    <script src="app.js"></script>
    </body>
    </html>
    """.utf8
    )

    static let stylesCSS = Data(
    """
    :root { --bg: #0d1117; --card: #161b22; --border: #30363d; --accent: #58a6ff; --text: #c9d1d9; --muted: #8b949e; --green: #3fb950; --red: #f85149; --orange: #d2991d; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'SF Mono', monospace; background: var(--bg); color: var(--text); min-height: 100vh; }
    .container { max-width: 1200px; margin: 0 auto; padding: 24px; }
    header { display: flex; align-items: center; gap: 16px; margin-bottom: 32px; }
    header h1 { font-size: 28px; font-weight: 700; }
    .badge { padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
    .badge.connected { background: RGBA(63, 185, 80, 0.15); color: var(--green); }
    .badge.disconnected { background: RGBA(248, 81, 73, 0.15); color: var(--red); }
    .badge.waiting { background: RGBA(210, 153, 29, 0.15); color: var(--orange); }
    .cue-section { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 24px; }
    .cue-card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 24px; }
    .cue-card .label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 8px; }
    .cue-name { font-size: 32px; font-weight: 700; margin-bottom: 4px; }
    .cue-number { font-size: 20px; color: var(--accent); font-weight: 600; }
    .cue-type { font-size: 13px; color: var(--muted); margin-top: 4px; }
    .time-section { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
    .time-box { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
    .time-box .label { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 6px; }
    .time-box .value { font-size: 18px; font-weight: 600; }
    .time-box .value.large { font-size: 24px; font-family: 'SF Mono', monospace; }
    .progress-bar { width: 100%; height: 8px; background: var(--border); border-radius: 4px; margin: 8px 0; overflow: hidden; }
    .progress-fill { height: 100%; background: var(--accent); border-radius: 4px; transition: width 0.2s ease; width: 0%; }
    .log-section { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
    .log-container { max-height: 200px; overflow-y: auto; font-size: 13px; font-family: 'SF Mono', monospace; }
    .log-entry { padding: 4px 0; border-bottom: 1px solid var(--border); color: var(--muted); }
    .log-entry .time { color: var(--accent); margin-right: 8px; }
    @media (max-width: 768px) { .cue-section, .time-section { grid-template-columns: 1fr; } }
    """.utf8
    )

    static let appJS = Data(
    """
    const $ = (s) => document.querySelector(s);
    const log = (msg) => { const el = document.createElement('div'); el.className = 'log-entry'; const t = new Date().toLocaleTimeString(); el.innerHTML = `<span class="time">${t}</span>${msg}`; const c = $('#log-container'); c.prepend(el); if (c.children.length > 50) c.lastChild.remove(); };

    let ws;
    function connect() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(`${proto}//${location.host}`);
      ws.onopen = () => { log('WebSocket connected'); $('#status-badge').className = 'badge connected'; $('#status-badge').textContent = 'CONNECTED'; };
      ws.onclose = () => { log('WebSocket disconnected, retrying...'); $('#status-badge').className = 'badge disconnected'; $('#status-badge').textContent = 'DISCONNECTED'; setTimeout(connect, 2000); };
      ws.onerror = () => ws.close();
      ws.onmessage = (e) => {
        try {
          const s = JSON.parse(e.data);
          if (s.currentCueName) $('#current-cue-name').textContent = s.currentCueName;
          if (s.currentCueNumber) $('#current-cue-number').textContent = s.currentCueNumber;
          if (s.currentCueType) $('#current-cue-type').textContent = s.currentCueType;
          if (s.nextCueName) $('#next-cue-name').textContent = s.nextCueName;
          if (s.nextCueNumber) $('#next-cue-number').textContent = s.nextCueNumber;
          if (s.nextCueType) $('#next-cue-type').textContent = s.nextCueType;
          if (s.timecode) $('#timecode').textContent = s.timecode;
          if (s.countdown) $('#countdown').textContent = s.countdown;
          if (s.elapsed) $('#elapsed').textContent = s.elapsed;
          if (typeof s.progress === 'number') { $('#progress-bar').style.width = `${s.progress}%`; $('#progress-text').textContent = `${s.progress}%`; }
          if (s.connectionState) $('#status-badge').textContent = s.connectionState;
          if (s.workspaceName) $('#workspace-label').textContent = s.workspaceName;
          if (s.eventLog) { s.eventLog.forEach(log); }
        } catch {}
      };
    }
    connect();
    """.utf8
    )
}
