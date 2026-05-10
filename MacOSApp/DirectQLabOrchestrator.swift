import Foundation
import Combine

// MARK: - Orchestrator: QLab Data Provider + WebSocket Dashboard Bridge

final class DirectQLabOrchestrator: ObservableObject {
    let host: String
    let port: UInt16
    let useTCP: Bool
    let passcode: String
    let workspace: String
    let webPort: UInt16

    @Published var snapshot = CueSnapshot()
    @Published var logs: [String] = []
    @Published var connectionState = "WAITING FOR QLAB"

    private var provider: QLabDataProvider?
    private var wsServer: DashboardWebSocketServer?

    init(host: String, port: UInt16, useTCP: Bool, passcode: String, workspace: String, webPort: UInt16) {
        self.host = host
        self.port = port
        self.useTCP = useTCP
        self.passcode = passcode
        self.workspace = workspace
        self.webPort = webPort
    }

    func start() {
        let server = DashboardWebSocketServer(port: webPort)
        server.start()
        wsServer = server

        provider = QLabDataProvider(
            host: host, port: port, useTCP: useTCP,
            passcode: passcode, workspace: workspace
        )
        provider?.delegate = self
        provider?.start()
    }

    func stop() {
        provider?.stop()
        provider = nil
        wsServer?.stop()
        wsServer = nil
    }

    // Passthrough actions
    func go()    { provider?.go() }
    func pause()  { provider?.pause() }
    func stop()   { provider?.stop() }
    func resume() { provider?.resume() }
    func panic()  { provider?.panic() }

    private func pushToDashboard() {
        let dict = snapshot.asDictionary(workspace: workspace)
        var payload = dict
        payload["connectionState"] = connectionState
        payload["eventLog"] = Array(logs.suffix(50))
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8) {
            WebSocketState.shared.update(payload)
            wsServer?.broadcast(json: json)
        }
    }
}

extension DirectQLabOrchestrator: QLabDataProviderDelegate {
    func provider(_ provider: QLabDataProvider, didUpdate snap: CueSnapshot) {
        snapshot = snap
        pushToDashboard()
    }

    func provider(_ provider: QLabDataProvider, didChangeConnection state: String) {
        connectionState = state
        pushToDashboard()
    }

    func provider(_ provider: QLabDataProvider, didLog message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(ts)] \(message)")
        if logs.count > 50 { logs.removeFirst(logs.count - 50) }
        pushToDashboard()
    }
}
