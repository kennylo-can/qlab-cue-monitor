import Foundation

// MARK: - QLab Data Provider (OSC subscription-driven)

protocol QLabDataProviderDelegate: AnyObject {
    func provider(_ provider: QLabDataProvider, didUpdate snapshot: CueSnapshot)
    func provider(_ provider: QLabDataProvider, didChangeConnection state: String)
    func provider(_ provider: QLabDataProvider, didLog message: String)
}

final class QLabDataProvider {
    weak var delegate: QLabDataProviderDelegate?

    private let client: QLabOSCClient
    private let workspace: String
    private let passcode: String

    private var snapshot = CueSnapshot()
    private var pollTimer: DispatchSourceTimer?
    private let stateQueue = DispatchQueue(label: "com.codex.qlabdata.state")

    // Lifecycle sequencing
    private enum Phase { case idle, connecting, authenticating, subscribed, polling, dead }
    private var phase = Phase.idle

    // Track auth to avoid reauth loops
    private var authAttempts = 0
    private let maxAuthAttempts = 3

    init(host: String, port: UInt16, useTCP: Bool, passcode: String, workspace: String) {
        self.passcode = passcode
        self.workspace = workspace
        client = QLabOSCClient(host: host, port: port, useTCP: useTCP)
        client.delegate = self
    }

    func start() {
        guard phase == .idle else { return }
        phase = .connecting
        authAttempts = 0
        client.connect(passcode: passcode.isEmpty ? nil : passcode,
                       workspace: workspace.isEmpty ? nil : workspace)
    }

    func stop() {
        stopPolling()
        client.disableKeepAlive()
        client.unsubscribeShowControl()
        client.unsubscribeUpdates()
        client.disconnect()
        phase = .dead
    }

    // Public actions
    func go()    { ws("/go") }
    func pause()  { ws("/pause") }
    func stop()   { ws("/stop") }
    func resume() { ws("/resume") }
    func panic()  { ws("/panic") }
    func jump(cueNumber: String) { ws("/playhead/\(cueNumber)") }

    // MARK: - Lifecycle helpers

    private func auth() {
        guard phase == .connecting else { return }
        phase = .authenticating
        authAttempts += 1
        log("Authenticating to QLab workspace...")
        serialize() {
            self.client.sendOSC(address: "\(self.wsPrefix)/connect", args: [self.passcode])
        }
    }

    private func onAuthSuccess() {
        log("Workspace connected. Subscribing to real-time updates...")
        serialize(delay: 0.2) {
            self.client.enableAlwaysReply()
        }
        serialize(delay: 0.4) {
            self.client.subscribeUpdates()
        }
        serialize(delay: 0.6) {
            self.client.subscribeShowControl()
        }
        serialize(delay: 0.8) {
            self.client.enableKeepAlive()
        }
        serialize(delay: 1.2) {
            self.phase = .subscribed
            self.initialDump()
        }
    }

    private func initialDump() {
        log("Fetching initial cue data...")
        let props = ["name", "number", "type"]
        for prop in props {
            wsQuery("/cue/active/\(prop)")
        }
        wsQuery("/currentCueList")

        serialize(delay: 0.3) {
            for prop in props {
                self.wsQuery("/cue/playhead/\(prop)")
            }
        }

        serialize(delay: 0.6) {
            self.phase = .polling
            self.startPeriodicPolling()
            self.log("QLab connected and polling. Dashboard live.")
            self.notify(connection: "CONNECTED")
        }
    }

    private func startPeriodicPolling() {
        stopPolling()
        pollTimer = DispatchSource.makeTimerSource(queue: .global())
        pollTimer?.schedule(deadline: .now() + 1.0, repeating: 1.0)
        pollTimer?.setEventHandler { [weak self] in
            self?.pollTick()
        }
        pollTimer?.resume()
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func pollTick() {
        guard phase == .polling else { return }
        // Only poll volatile data: elapsed time, progress
        wsQuery("/cue/active/actionElapsed")
        wsQuery("/cue/active/percentActionElapsed")
    }

    // MARK: - OSC sending helpers

    private func serialize(delay: TimeInterval = 0, _ block: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: block)
    }

    private var wsPrefix: String {
        let w = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? "/workspace" : "/workspace/\(w)"
    }

    private func ws(_ address: String) {
        client.sendOSC(address: "\(wsPrefix)\(address)", args: [])
    }

    private func wsQuery(_ address: String) {
        client.sendOSC(address: "\(wsPrefix)\(address)", args: [])
    }

    // MARK: - State helpers

    private func updateSnapshot(_ block: (inout CueSnapshot) -> Void) {
        stateQueue.sync { block(&snapshot) }
        let copy = stateQueue.sync { snapshot }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.provider(self!, didUpdate: copy)
        }
    }

    private func log(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.provider(self!, didLog: msg)
        }
    }

    private func notify(connection state: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.provider(self!, didChangeConnection: state)
        }
    }

    // MARK: - Reply data probe (re-query active+playhead)

    private func refetchActiveCue() {
        wsQuery("/cue/active/name")
        wsQuery("/cue/active/number")
        wsQuery("/cue/active/type")
    }

    private func refetchPlayhead() {
        wsQuery("/cue/playhead/name")
        wsQuery("/cue/playhead/number")
        wsQuery("/cue/playhead/type")
    }
}

// MARK: - QLabOSCClientDelegate

extension QLabDataProvider: QLabOSCClientDelegate {
    func oscClient(_ client: QLabOSCClient, didConnect workspace: String) {
        log("TCP connected to QLab.")
        serialize(delay: 0.3) { self.auth() }
    }

    func oscClient(_ client: QLabOSCClient, didDisconnect reason: String) {
        log("Disconnected: \(reason)")
        notify(connection: "DISCONNECTED")
    }

    func oscClient(_ client: QLabOSCClient,
                   didReceiveReply status: String,
                   address: String,
                   data: Any?) {

        if status == "badpass" {
            notify(connection: "BAD PASSCODE")
            log("Authentication failed: bad passcode")
            return
        }

        if address.contains("/connect") {
            if status == "ok" {
                if let dataStr = data as? String, dataStr == "ok" {
                    onAuthSuccess()
                } else {
                    onAuthSuccess()
                }
            } else if status == "badpass" {
                notify(connection: "BAD PASSCODE")
            }
            return
        }

        guard status == "ok" else {
            log("Reply error [\(status)] for \(address)")
            return
        }

        applyReplyData(address: address, data: data)
    }

    private func applyReplyData(address: String, data: Any?) {
        if address.contains("/active/name") || address.hasSuffix("/active/name") {
            updateSnapshot { snap in
                snap.currentCueName = self.dataAsString(data)
            }
        } else if address.contains("/active/number") || address.hasSuffix("/active/number") {
            updateSnapshot { snap in
                snap.currentCueNumber = self.dataAsString(data)
            }
        } else if address.contains("/active/type") || address.hasSuffix("/active/type") {
            updateSnapshot { snap in
                snap.currentCueType = self.dataAsString(data)
            }
        } else if address.contains("/active/actionElapsed") {
            updateSnapshot { snap in
                snap.elapsedSeconds = self.dataAsDouble(data)
                snap.elapsed = self.formatTime(snap.elapsedSeconds)
            }
        } else if address.contains("/active/percentActionElapsed") {
            updateSnapshot { snap in
                snap.progress = self.dataAsDouble(data)
            }
        } else if address.contains("/playhead/name") || address.hasSuffix("/playhead/name") {
            updateSnapshot { snap in
                snap.nextCueName = self.dataAsString(data)
            }
        } else if address.contains("/playhead/number") || address.hasSuffix("/playhead/number") {
            updateSnapshot { snap in
                snap.nextCueNumber = self.dataAsString(data)
            }
        } else if address.contains("/playhead/type") || address.hasSuffix("/playhead/type") {
            updateSnapshot { snap in
                snap.nextCueType = self.dataAsString(data)
            }
        } else if address.contains("/currentCueList") {
            updateSnapshot { snap in
                snap.cueListNumber = self.dataAsString(data)
            }
        } else {
            log("Unmapped reply \(address): \(data ?? "nil")")
        }
    }

    func oscClient(_ client: QLabOSCClient,
                   didReceiveUpdate address: String,
                   args: [Any]) {

        // QLab /updates push: tells us WHAT changed, we re-query
        if address.contains("/cue_id/") {
            // A specific cue changed — could be active, refetch
            refetchActiveCue()
            refetchPlayhead()
        } else if address.contains("/playbackPosition") {
            // Playhead moved — refetch playhead
            refetchPlayhead()
        } else if address.hasPrefix("/update/workspace/") && !address.contains("/cue_id/") && !address.contains("/playbackPosition") {
            // Workspace-level update — refetch everything
            refetchActiveCue()
            refetchPlayhead()
            wsQuery("/currentCueList")
        }
    }

    func oscClient(_ client: QLabOSCClient,
                   didReceiveEvent event: String,
                   number: String?,
                   name: String?,
                   uniqueID: String?,
                   type: String?) {

        switch event {
        case "go":
            log("GO ⟶ \(name ?? number ?? "?")")
            // Refetch active cue since GO changed it
            serialize(delay: 0.3) { self.refetchActiveCue() }
            serialize(delay: 0.5) { self.refetchPlayhead() }
        case "stop":
            log("STOP")
        case "pauseAll":
            log("PAUSE ALL")
        case "resumeAll":
            log("RESUME ALL")
        case let e where e.hasPrefix("cue/start") || e == "cue/start":
            if let n = name { log("Cue started: \(n)") }
            serialize(delay: 0.3) { self.refetchActiveCue() }
        case let e where e.hasPrefix("cue/stop") || e == "cue/stop":
            if let n = name { log("Cue stopped: \(n)") }
        default:
            log("Event \(event): \(name ?? number ?? "")")
        }
    }

    func oscClient(_ client: QLabOSCClient, didReceiveTimecode timecode: String) {
        updateSnapshot { snap in
            snap.timecode = timecode
        }
    }

    // MARK: - Data conversion

    private func dataAsString(_ data: Any?) -> String {
        if let s = data as? String { return s }
        if let d = data as? Double { return d.rounded() == d ? String(Int(d)) : String(format: "%.2f", d) }
        if let i = data as? Int { return String(i) }
        return ""
    }

    private func dataAsDouble(_ data: Any?) -> Double {
        if let d = data as? Double { return d }
        if let i = data as? Int { return Double(i) }
        if let s = data as? String { return Double(s) ?? 0 }
        return 0
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Cue Snapshot

struct CueSnapshot: Equatable {
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
    var elapsedSeconds: Double = 0
    var cueListNumber = ""

    func asDictionary(workspace: String) -> [String: Any] {
        [
            "currentCueName": currentCueName,
            "currentCueNumber": currentCueNumber,
            "currentCueType": currentCueType,
            "nextCueName": nextCueName,
            "nextCueNumber": nextCueNumber,
            "nextCueType": nextCueType,
            "timecode": timecode,
            "countdown": countdown,
            "elapsed": elapsed,
            "progress": progress,
            "elapsedSeconds": elapsedSeconds,
            "cueListNumber": cueListNumber,
            "workspaceName": workspace,
        ]
    }
}
