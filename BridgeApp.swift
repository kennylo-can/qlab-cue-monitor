import AppKit
import Foundation

final class BridgeController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var serverProcess: Process?
    private let serverURL = URL(string: "http://127.0.0.1:8088/")!
    private let serverLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QLabDashboardBridge/server.log")
    private let serverPID = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QLabDashboardBridge/server.pid")
    private let openFlag = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QLabDashboardBridge/browser-opened.flag")
    private var monitorTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        startServerIfNeeded()
        openBrowserOnce()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.ensureServerRunning()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "QLab Bridge"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(serverURL)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func nodeBinary() -> String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/node",
            ProcessInfo.processInfo.environment["NODE_BIN"],
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func startServerIfNeeded() {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        guard let node = nodeBinary() else {
            NSLog("QLabDashboardBridge: node not found")
            return
        }
        let resources = Bundle.main.resourceURL!
        let serverPath = resources.appendingPathComponent("server.js").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [serverPath]
        process.standardOutput = try? FileHandle(forWritingTo: serverLog)
        process.standardError = try? FileHandle(forWritingTo: serverLog)
        try? FileManager.default.createDirectory(at: serverLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: serverLog.path) {
            FileManager.default.createFile(atPath: serverLog.path, contents: nil)
        }
        do {
            try process.run()
            serverProcess = process
            try? "\(process.processIdentifier)".write(to: serverPID, atomically: true, encoding: .utf8)
            NSLog("QLabDashboardBridge: server started")
        } catch {
            NSLog("QLabDashboardBridge: failed to start server: \(error.localizedDescription)")
        }
    }

    private func ensureServerRunning() {
        if let process = serverProcess, process.isRunning {
            return
        }
        serverProcess = nil
        try? FileManager.default.removeItem(at: serverPID)
        startServerIfNeeded()
    }

    private func openBrowserOnce() {
        if FileManager.default.fileExists(atPath: openFlag.path) { return }
        NSWorkspace.shared.open(serverURL)
        try? FileManager.default.createDirectory(at: openFlag.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: openFlag.path, contents: Data())
    }

    private func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        try? FileManager.default.removeItem(at: serverPID)
    }
}

let app = NSApplication.shared
let delegate = BridgeController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
