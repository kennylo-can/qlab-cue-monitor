import Foundation

struct AppConfig: Codable {
    var webPort: UInt16 = 8088
    var host: String = "0.0.0.0"
    var launchAtLogin: Bool = false
    var openBrowserOnStart: Bool = false
    var oscListenPort: UInt16 = 53000
    var useTCP: Bool = true
    var profiles: [QLabProfile] = [
        .init(name: "Default QLab", host: "127.0.0.1", port: 53000, passcode: "5566")
    ]
    var selectedProfileID: UUID = UUID()

    static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("QLabOSCWatch").appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return value
    }

    func save() {
        let url = Self.configURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

struct QLabProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var passcode: String
    var workspace: String = ""
    var useDiscoveredEndpoint: Bool = false

    var workspaceMode: WorkspaceMode {
        get { workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .custom }
        set {
            if newValue == .none { workspace = "" }
        }
    }

    var displaysAsBonjour: Bool {
        useDiscoveredEndpoint && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum WorkspaceMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case custom

    var id: String { rawValue }
}
