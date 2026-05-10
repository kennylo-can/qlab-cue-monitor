import Foundation

// MARK: - Unified Orchestrator: QLab OSC Client + WebSocket Dashboard Bridge

final class DirectQLabOrchestrator {
    let host: String
    let port: UInt16
    let useTCP: Bool
    let passcode: String
    let workspace: String
    let webPort: UInt16

    private let oscClient: QLabOSCClient
    private let wsServer: DashboardWebSocketServer

    private var cueState: CueSnapshot = CueSnapshot()
    private var logBuffer: [String] = []

    init(host: String, port: UInt16, useTCP: Bool, passcode: String, workspace: String, webPort: UInt16) {
        self.host = host
        self.port = port
        self.useTCP = useTCP
        self.passcode = passcode
        self.workspace = workspace
        self.webPort = webPort

        oscClient = QLabOSCClient(host: host, port: port, useTCP: useTCP)
        wsServer = DashboardWebSocketServer(port: webPort)
    }

    func start() {
        wsServer.start()

        oscClient.delegate = self
        oscClient.connect(passcode: passcode.isEmpty ? nil : passcode, workspace: workspace.isEmpty ? nil : workspace)

        // After connection, send auth + subscribe
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let ws = self.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            let addr = ws.isEmpty ? "/workspace/connect" : "/workspace/\(ws)/connect"
            let pass = self.passcode
            self.oscClient.sendOSC(address: addr, args: [pass])

            // Subscribe to real-time updates
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                self.oscClient.enableAlwaysReply()
                self.oscClient.subscribeUpdates()
                self.oscClient.subscribeShowControl()
                self.oscClient.enableKeepAlive()

                // Periodically poll active + playhead cue info
                self.startPeriodicPolling()
            }
        }
    }

    func stop() {
        oscClient.disableKeepAlive()
        oscClient.unsubscribeShowControl()
        oscClient.unsubscribeUpdates()
        oscClient.disconnect()
        wsServer.stop()
    }

    func go() { oscClient.go(workspace: workspace.isEmpty ? nil : workspace) }
    func pause() { oscClient.pause(workspace: workspace.isEmpty ? nil : workspace) }
    func stop() { oscClient.stop(workspace: workspace.isEmpty ? nil : workspace) }
    func resume() { oscClient.resume(workspace: workspace.isEmpty ? nil : workspace) }
    func panic() { oscClient.panic(workspace: workspace.isEmpty ? nil : workspace) }

    private func startPeriodicPolling() {
        func poll() {
            oscClient.queryActiveCue(property: "name")
            oscClient.queryActiveCue(property: "number")
            oscClient.queryActiveCue(property: "type")
            oscClient.queryCue("playhead/name")
            oscClient.queryCue("playhead/number")
            oscClient.queryCue("playhead/type")
        }
        poll()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { poll() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { poll() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { poll() }
        // After initial burst, rely on /updates subscription push
    }

    private func pushState() {
        var dict: [String: Any] = [
            "currentCueName": cueState.currentCueName,
            "currentCueNumber": cueState.currentCueNumber,
            "currentCueType": cueState.currentCueType,
            "nextCueName": cueState.nextCueName,
            "nextCueNumber": cueState.nextCueNumber,
            "nextCueType": cueState.nextCueType,
            "timecode": cueState.timecode,
            "countdown": cueState.countdown,
            "elapsed": cueState.elapsed,
            "progress": cueState.progress,
            "connectionState": cueState.connectionState,
            "workspaceName": workspace.isEmpty ? "QLab" : workspace,
            "eventLog": logBuffer
        ]
        if logBuffer.count > 20 {
            logBuffer = Array(logBuffer.prefix(20))
            dict["eventLog"] = logBuffer
        }
        WebSocketState.shared.update(dict)
    }

    private func appendLog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logBuffer.insert("[\(ts)] \(msg)", at: 0)
        if logBuffer.count > 50 { logBuffer.removeLast(logBuffer.count - 50) }
        pushState()
    }
}

extension DirectQLabOrchestrator: QLabOSCClientDelegate {
    func oscClient(_ client: QLabOSCClient, didConnect workspace: String) {
        cueState.connectionState = "CONNECTED"
        appendLog("Connected to QLab at \(host):\(port)")
        pushState()
    }

    func oscClient(_ client: QLabOSCClient, didDisconnect reason: String) {
        cueState.connectionState = "DISCONNECTED"
        appendLog("Disconnected: \(reason)")
        pushState()
    }

    func oscClient(_ client: QLabOSCClient, didReceiveReply status: String, address: String, data: Any?) {
        appendLog("Reply [\(status)] \(address)")

        if status == "badpass" {
            cueState.connectionState = "BAD PASSCODE"
            pushState()
            return
        }

        guard status == "ok", let dataStr = data as? String else { return }

        // Parse reply data to update cue state
        if address.contains("/active/name") || address.contains("/cue/active/name") {
            cueState.currentCueName = dataStr
        } else if address.contains("/active/number") || address.contains("/cue/active/number") {
            cueState.currentCueNumber = dataStr
        } else if address.contains("/active/type") || address.contains("/cue/active/type") {
            cueState.currentCueType = dataStr
        } else if address.contains("/playhead/name") {
            cueState.nextCueName = dataStr
        } else if address.contains("/playhead/number") {
            cueState.nextCueNumber = dataStr
        } else if address.contains("/playhead/type") {
            cueState.nextCueType = dataStr
        } else if address.contains("/connect") {
            if dataStr == "ok" {
                cueState.connectionState = "CONNECTED"
                appendLog("Workspace connected successfully")
            } else if dataStr == "badpass" {
                cueState.connectionState = "BAD PASSCODE"
            }
        }

        pushState()
    }

    func oscClient(_ client: QLabOSCClient, didReceiveUpdate address: String, args: [Any]) {
        let value = args.compactMap({ $0 as? String }).first
            ?? args.compactMap({ $0 as? Int }).first.map(String.init)
            ?? args.compactMap({ $0 as? Float }).first.map(String.init)
            ?? ""

        // Handle various update paths
        if address.contains("/active/number") || address.hasSuffix("/number") {
            cueState.currentCueNumber = value
        } else if address.contains("/active/name") || address.hasSuffix("/name") {
            cueState.currentCueName = value
        } else if address.contains("/active/type") || address.hasSuffix("/type") {
            cueState.currentCueType = value
        } else if address.contains("/next/number") {
            cueState.nextCueNumber = value
        } else if address.contains("/next/name") {
            cueState.nextCueName = value
        } else if address.contains("/next/type") {
            cueState.nextCueType = value
        } else if address.localizedCaseInsensitiveContains("timecode") {
            cueState.timecode = value
        } else if address.localizedCaseInsensitiveContains("countdown") || address.localizedCaseInsensitiveContains("remaining") {
            cueState.countdown = value
        } else if address.localizedCaseInsensitiveContains("elapsed") {
            cueState.elapsed = value
        } else if address.localizedCaseInsensitiveContains("prewait") {
            // handled within cue
        } else if address.localizedCaseInsensitiveContains("progress") {
            if let p = args.compactMap({ $0 as? Double }).first ?? args.compactMap({ $0 as? Float }).first.map(Double.init) {
                cueState.progress = p
            }
        }

        pushState()
    }

    func oscClient(_ client: QLabOSCClient, didReceiveEvent event: String, number: String?, name: String?, uniqueID: String?, type: String?) {
        switch event {
        case "go":
            appendLog("GO: \(name ?? number ?? "?")")
        case "stop":
            appendLog("STOP")
        case "pauseAll":
            appendLog("PAUSE ALL")
        case "resumeAll":
            appendLog("RESUME ALL")
        default:
            appendLog("Event \(event): \(name ?? number ?? "")")
        }
    }

    func oscClient(_ client: QLabOSCClient, didReceiveTimecode timecode: String) {
        cueState.timecode = timecode
        pushState()
    }
}

// MARK: - Cue Snapshot

struct CueSnapshot {
    var currentCueName = ""
    var currentCueNumber = ""
    var currentCueType = ""
    var nextCueName = ""
    var nextCueNumber = ""
    var nextCueType = ""
    var timecode = "--:--:--:--"
    var countdown = "--:--"
    var elapsed = "--:--"
    var progress: Double = 0
    var connectionState = "WAITING FOR QLAB"
}
