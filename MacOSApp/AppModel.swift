import Foundation
import AppKit
import Combine
import Network

struct ControlConnection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var enabled: Bool = true
}

struct DiscoveredQLabService: Identifiable, Hashable {
    var id: String { "\(name)|\(host)|\(port)" }
    var name: String
    var host: String
    var port: UInt16
}

struct ControlAction: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var oscAddress: String
    var message: String
}

struct ControlPage: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var buttons: [ControlAction]
}

final class OSCSender {
    func send(address: String, message: String, host: String, port: UInt16, useTCP: Bool) {
        guard let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: useTCP ? .tcp : .udp
        ) as NWConnection? else { return }

        let packet = OSCEncoder.encode(address: address, message: message)
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: .global())
        if useTCP {
            var framed = Data()
            var size = UInt32(packet.count).bigEndian
            withUnsafeBytes(of: &size) { framed.append(contentsOf: $0) }
            framed.append(packet)
            connection.send(content: framed, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.send(content: packet, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func sendWorkspaceConnect(host: String, port: UInt16, workspace: String, passcode: String, useTCP: Bool) {
        let workspaceID = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = workspaceID.isEmpty ? "/workspace/connect" : "/workspace/\(workspaceID)/connect"
        let packet = OSCEncoder.encode(address: address, message: passcode)
        guard let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: useTCP ? .tcp : .udp
        ) as NWConnection? else { return }
        connection.start(queue: .global())
        if useTCP {
            var framed = Data()
            var size = UInt32(packet.count).bigEndian
            withUnsafeBytes(of: &size) { framed.append(contentsOf: $0) }
            framed.append(packet)
            connection.send(content: framed, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.send(content: packet, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func sendTestSequence(profile: QLabProfile, completion: @escaping (Bool, String) -> Void) {
        let useTCP = true
        sendWorkspaceConnect(host: profile.host, port: profile.port, workspace: profile.workspace, passcode: profile.passcode, useTCP: useTCP)
        send(address: "/version", message: "", host: profile.host, port: profile.port, useTCP: useTCP)
        completion(true, "Sent connect and version probe to \(profile.host):\(profile.port)")
    }
}

enum OSCEncoder {
    static func encode(address: String, message: String) -> Data {
        var data = Data()
        data.append(oscString(address))
        data.append(oscString(",s"))
        data.append(oscString(message))
        return data
    }

    private static func oscString(_ string: String) -> Data {
        var data = Data(string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
}

final class AppModel: ObservableObject {
    @Published var config = AppConfig.load()
    @Published var serviceStatus = "Stopped"
    @Published var serverURL: URL?
    @Published var lastError: String?
    @Published var isRunning = false
    @Published var selectedPageIndex = 0
    @Published var selectedConnectionIndex = 0
    @Published var connections: [ControlConnection] = [
        .init(name: "QLab Main", host: "127.0.0.1", port: 53000),
    ]
    @Published var pages: [ControlPage] = [
        .init(
            name: "QLab",
            buttons: [
                .init(title: "Go", oscAddress: "/cue/go", message: "go"),
                .init(title: "Pause", oscAddress: "/cue/pause", message: "pause"),
                .init(title: "Stop", oscAddress: "/cue/stop", message: "stop"),
                .init(title: "Reset", oscAddress: "/cue/reset", message: "reset"),
            ]
        )
    ]
    @Published var logs: [String] = []
    @Published var latestRemoteState: DashboardState = .init()
    @Published var connectionProbeStatus: String = "Idle"
    @Published var discoveredQLabServices: [DiscoveredQLabService] = []

    private let sender = OSCSender()
    private var service: LocalService?
    private var saveWorkItem: DispatchWorkItem?
    private let discovery = QLabDiscoveryManager()

    init() {
        if config.profiles.isEmpty {
            config.profiles = [.init(name: "Default QLab", host: "127.0.0.1", port: 53000, passcode: "5566")]
        }
        if config.oscListenPort == 53010 {
            config.oscListenPort = 53000
        }
        if !config.profiles.contains(where: { $0.id == config.selectedProfileID }) {
            config.selectedProfileID = config.profiles[0].id
        }
        discovery.onUpdate = { [weak self] services in
            DispatchQueue.main.async {
                self?.discoveredQLabServices = services
            }
        }
        discovery.start()
    }

    var selectedProfileIndex: Int {
        get {
            config.profiles.firstIndex { $0.id == config.selectedProfileID } ?? 0
        }
        set {
            guard config.profiles.indices.contains(newValue) else { return }
            config.selectedProfileID = config.profiles[newValue].id
        }
    }

    var selectedProfile: QLabProfile {
        get { config.profiles[selectedProfileIndex] }
        set {
            if config.profiles.indices.contains(selectedProfileIndex) {
                config.profiles[selectedProfileIndex] = newValue
            }
        }
    }

    func start() {
        guard service == nil else { return }
        do {
            let service = try LocalService(config: config)
            self.service = service
            self.serverURL = service.serverURL
            self.serviceStatus = "Running"
            self.isRunning = true
            DashboardState.shared.setWorkspaceName(selectedProfile.workspace.isEmpty ? "Default Workspace" : selectedProfile.workspace)
            DashboardState.shared.setCueListName("Default Cue List")
            DashboardState.shared.setConnectionState("WAITING FOR QLAB")
            self.connectionProbeStatus = "Waiting for QLab"
            self.latestRemoteState = DashboardState.shared
            service.onStateUpdate = { [weak self] state in
                DispatchQueue.main.async {
                    self?.latestRemoteState = state
                    self?.connectionProbeStatus = "OSC Received"
                }
            }
            service.start()
            log("Service started on web \(config.webPort), TCP feedback \(config.oscListenPort), QLab \(selectedProfile.host):\(selectedProfile.port)")
        } catch {
            lastError = error.localizedDescription
            serviceStatus = "Failed"
            log("Start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        service?.stop()
        service = nil
        isRunning = false
        serviceStatus = "Stopped"
        DashboardState.shared.setConnectionState("STOPPED")
        connectionProbeStatus = "Stopped"
        latestRemoteState = DashboardState.shared
        log("Service stopped")
    }

    func restart() {
        stop()
        start()
    }

    func saveConfig() {
        config.save()
        if isRunning {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.start()
            }
        }
    }

    func scheduleSaveConfig() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveConfig()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    func quitApp() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    func selectedConnection() -> ControlConnection? {
        guard connections.indices.contains(selectedConnectionIndex) else { return nil }
        return connections[selectedConnectionIndex]
    }

    func trigger(_ action: ControlAction) {
        guard let connection = selectedConnection(), connection.enabled else {
            log("No enabled connection selected")
            return
        }
        sender.sendWorkspaceConnect(
            host: selectedProfile.host,
            port: selectedProfile.port,
            workspace: selectedProfile.workspace,
            passcode: selectedProfile.passcode,
            useTCP: config.useTCP
        )
        sender.send(address: action.oscAddress, message: action.message, host: connection.host, port: connection.port, useTCP: config.useTCP)
        log("Sent \(action.oscAddress) to \(connection.name)")
    }

    func testSelectedProfile() {
        connectionProbeStatus = "Testing..."
        let profile = selectedProfile
        sender.sendTestSequence(profile: profile) { [weak self] ok, message in
            DispatchQueue.main.async {
                self?.connectionProbeStatus = ok ? "OK" : "Failed"
                self?.log(message)
            }
        }
    }

    func addProfile() {
        let profile = QLabProfile(name: "New QLab", host: "127.0.0.1", port: 53000, passcode: "")
        config.profiles.append(profile)
        config.selectedProfileID = profile.id
    }

    func removeProfile(at offsets: IndexSet) {
        config.profiles.remove(atOffsets: offsets)
        if config.profiles.isEmpty {
            let profile = QLabProfile(name: "Default QLab", host: "127.0.0.1", port: 53000, passcode: "5566")
            config.profiles = [profile]
        }
        config.selectedProfileID = config.profiles[0].id
    }

    func useDiscoveredService(_ service: DiscoveredQLabService) {
        guard config.profiles.indices.contains(selectedProfileIndex) else { return }
        var profile = selectedProfile
        profile.name = service.name
        profile.host = service.host
        profile.port = service.port
        profile.useDiscoveredEndpoint = true
        selectedProfile = profile
        scheduleSaveConfig()
        log("Applied Bonjour service \(service.name) -> \(service.host):\(service.port)")
    }

    func addConnection() {
        connections.append(.init(name: "New Device", host: "127.0.0.1", port: 53000))
        selectedConnectionIndex = connections.count - 1
    }

    func removeConnection(at offsets: IndexSet) {
        connections.remove(atOffsets: offsets)
        selectedConnectionIndex = min(selectedConnectionIndex, max(0, connections.count - 1))
    }

    func addPage() {
        pages.append(.init(name: "New Page", buttons: []))
        selectedPageIndex = pages.count - 1
    }

    func removePage(at offsets: IndexSet) {
        pages.remove(atOffsets: offsets)
        selectedPageIndex = min(selectedPageIndex, max(0, pages.count - 1))
    }

    func log(_ message: String) {
        logs.insert("[\(Self.timestamp())] \(message)", at: 0)
        if logs.count > 100 { logs.removeLast(logs.count - 100) }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
