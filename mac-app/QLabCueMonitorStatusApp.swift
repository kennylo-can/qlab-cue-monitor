import AppKit
import Foundation
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let appName = "QLab Cue Monitor"
    private let port = 8080
    private let serverExecutableName = "server.js"
    private let bundledNodeName = "node"

    private var statusItem: NSStatusItem!
    private var serverProcess: Process?
    private var logHandle: FileHandle?
    private var nodeBinaryPath: String?
    private var menu: NSMenu = NSMenu()

    private lazy var statusItemMenuTitle = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
    private lazy var toggleItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "")
    private lazy var openItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
    private lazy var copyItem = NSMenuItem(title: "Copy Dashboard URL", action: #selector(copyDashboardURL), keyEquivalent: "")
    private lazy var quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")

    private var bundleResourceRoot: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    private var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    private var logURL: URL {
        supportRoot.appendingPathComponent("server.log")
    }

    private var serverJSURL: URL {
        bundleResourceRoot.appendingPathComponent(serverExecutableName)
    }

    private var bundledNodeURL: URL {
        bundleResourceRoot.appendingPathComponent(bundledNodeName)
    }

    private var dashboardURL: URL {
        URL(string: "http://127.0.0.1:\(port)/index.html")!
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        nodeBinaryPath = findNodeBinary()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.startServerIfNeeded(openDashboardAfterStart: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "QLab"
        statusItem.button?.appearsDisabled = false
        statusItem.menu = menu

        menu.delegate = self
        menu.addItem(statusItemMenuTitle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(toggleItem)
        menu.addItem(openItem)
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        toggleItem.target = self
        openItem.target = self
        copyItem.target = self
        quitItem.target = self

        updateMenuState()
    }

    private func updateMenuState() {
        let running = serverProcess?.isRunning == true
        statusItem.button?.title = running ? "QLab ●" : "QLab ◌"
        statusItemMenuTitle.title = running ? "Status: Running" : "Status: Stopped"
        toggleItem.title = running ? "Stop Server" : "Start Server"
        openItem.isEnabled = true
        copyItem.isEnabled = true
    }

    private func findNodeBinary() -> String? {
        if FileManager.default.isExecutableFile(atPath: bundledNodeURL.path) {
            return bundledNodeURL.path
        }

        let candidates = [
            ProcessInfo.processInfo.environment["NODE_BIN"],
            "/Applications/Codex.app/Contents/Resources/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func prepareSupportRoot() throws {
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
    }

    private func configureProcess(_ process: Process) throws {
        try prepareSupportRoot()

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let environment = ProcessInfo.processInfo.environment.merging([
            "QLAB_CUE_MONITOR_STATIC_ROOT": bundleResourceRoot.path,
            "QLAB_CUE_MONITOR_DATA_DIR": supportRoot.path,
            "PORT": String(port)
        ]) { _, new in new }

        guard let nodeBinaryPath else {
            throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "Node binary not found"])
        }

        process.executableURL = URL(fileURLWithPath: nodeBinaryPath)
        process.arguments = [serverJSURL.path]
        process.currentDirectoryURL = bundleResourceRoot
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        self.logHandle = logHandle
    }

    @objc private func toggleServer() {
        if serverProcess?.isRunning == true {
            stopServer()
        } else {
            startServerIfNeeded(openDashboardAfterStart: false)
        }
    }

    private func startServerIfNeeded(openDashboardAfterStart: Bool) {
        guard serverProcess?.isRunning != true else {
            updateMenuState()
            if openDashboardAfterStart {
                openDashboard()
            }
            return
        }

        let process = Process()
        do {
            try configureProcess(process)
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.serverProcess = nil
                    self?.closeLogHandle()
                    self?.updateMenuState()
                }
            }
            try process.run()
            serverProcess = process
            updateMenuState()
            if openDashboardAfterStart {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.openDashboard()
                }
            }
        } catch {
            closeLogHandle()
            serverProcess = nil
            updateMenuState()
            showError(message: error.localizedDescription)
        }
    }

    private func stopServer(completion: (() -> Void)? = nil) {
        guard let process = serverProcess else {
            closeLogHandle()
            updateMenuState()
            completion?()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.forceStopProcessIfNeeded(process)

            DispatchQueue.main.async {
                self?.serverProcess = nil
                self?.closeLogHandle()
                self?.updateMenuState()
                completion?()
            }
        }
    }

    private func closeLogHandle() {
        try? logHandle?.close()
        logHandle = nil
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(dashboardURL)
    }

    @objc private func copyDashboardURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dashboardURL.absoluteString, forType: .string)
    }

    @objc private func quitApp() {
        shutdownServerThenQuit()
    }

    private func shutdownServerThenQuit() {
        stopServer { [weak self] in
            DispatchQueue.main.async {
                self?.closeLogHandle()
                NSApp.terminate(nil)
            }
        }
    }

    private func forceStopProcessIfNeeded(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()

        let deadline = Date().addingTimeInterval(1.25)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard process.isRunning else { return }

        process.interrupt()
        Thread.sleep(forTimeInterval: 0.2)

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "QLab Cue Monitor"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@main
final class Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
