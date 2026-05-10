import Foundation
import Network

final class QLabDiscoveryManager: NSObject, ObservableObject {
    var onUpdate: (([DiscoveredQLabService]) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredQLabService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_qlab._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.removeAll()
        resolved.removeAll()
        notify()
    }

    private func notify() {
        let list = resolved.values.sorted {
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if $0.host != $1.host { return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
            return $0.port < $1.port
        }
        onUpdate?(list)
    }
}

extension QLabDiscoveryManager: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 3)
        if !moreComing {
            notify()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
        let keyPrefix = "\(service.name)|"
        resolved = resolved.filter { !$0.key.hasPrefix(keyPrefix) }
        if !moreComing {
            notify()
        }
    }
}

extension QLabDiscoveryManager: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? sender.name
        let port = UInt16(sender.port)
        let service = DiscoveredQLabService(name: sender.name, host: host, port: port)
        resolved["\(service.name)|\(service.host)|\(service.port)"] = service
        notify()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        notify()
    }
}
