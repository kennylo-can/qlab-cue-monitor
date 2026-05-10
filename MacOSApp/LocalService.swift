import Foundation
import Network
import AppKit

final class LocalService {
    let config: AppConfig
    let serverURL: URL
    var onStateUpdate: ((DashboardState) -> Void)?

    private var httpServer: HTTPServer?
    private var oscReceiver: OSCReceiver?

    init(config: AppConfig) throws {
        self.config = config
        guard let url = URL(string: "http://127.0.0.1:\(config.webPort)") else {
            throw NSError(domain: "LocalService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        self.serverURL = url
    }

    func start() {
        httpServer = HTTPServer(config: config)
        httpServer?.start()
        oscReceiver = OSCReceiver(port: config.oscListenPort, useTCP: config.useTCP, onPacket: { [weak self] data in
            DashboardState.shared.applyOSC(data)
            self?.onStateUpdate?(DashboardState.shared)
        })
        oscReceiver?.start()
        if config.openBrowserOnStart {
            NSWorkspace.shared.open(serverURL)
        }
    }

    func stop() {
        httpServer?.stop()
        oscReceiver?.stop()
        httpServer = nil
        oscReceiver = nil
    }
}
