import Foundation
import Combine

struct DiscoveredServer: Identifiable {
    let id: String
    let name: String
    let url: URL
}

final class ServerDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !searching else { return }
        error = nil
        searching = true
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }

    func stop() {
        searching = false
        browser.stop()
        for service in services.values { service.delegate = nil; service.stop() }
        services.removeAll()
        servers.removeAll()
    }

    private func key(_ service: NetService) -> String { "\(service.name)|\(service.type)|\(service.domain)" }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard searching, service.name.hasPrefix("Shoebox ("), service.name.hasSuffix(")") else { return }
        let id = key(service)
        guard services[id] == nil else { return }
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        let id = key(service)
        guard searching, services[id] === service,
              let url = ServerAddress.bonjourURL(host: service.hostName, port: service.port) else { return }
        servers.removeAll { $0.id == id }
        servers.append(DiscoveredServer(id: id, name: service.name, url: url))
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = key(service)
        if let removed = services.removeValue(forKey: id) { removed.delegate = nil; removed.stop() }
        servers.removeAll { $0.id == id }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        stop()
        error = "Discovery is unavailable. Allow Shoebox in Settings → Privacy & Security → Local Network, then refresh, or enter the address manually."
    }
}
