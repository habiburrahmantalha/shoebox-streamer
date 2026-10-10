import Foundation

assert(ServerAddress.parse(" 192.168.1.10 ")?.absoluteString == "http://192.168.1.10:7171/")
assert(ServerAddress.parse("http://shoebox.local:7173/")?.port == 7173)
assert(ServerAddress.parse("https://mac.local")?.port == 443)
for invalid in ["", "file:///etc/passwd", "javascript:alert(1)", "http://user:pass@mac.local",
                "http://mac.local/videos", "http://mac.local?x=1", "http://mac.local#x",
                "http://mac.local:0", "http://mac.local:65536", "http://bad host"] {
    assert(ServerAddress.parse(invalid) == nil, invalid)
}
let server = ServerAddress.parse("http://mac.local:7171")!
assert(ServerAddress.sameOrigin(URL(string: "http://MAC.local:7171/media/1"), as: server))
assert(!ServerAddress.sameOrigin(URL(string: "https://mac.local:7171/"), as: server))
assert(!ServerAddress.sameOrigin(URL(string: "http://mac.local:7172/"), as: server))
assert(!ServerAddress.sameOrigin(URL(string: "http://other.local:7171/"), as: server))
print("iPad server address checks passed")

assert(ServerAddress.bonjourURL(host: "shoebox.local.", port: 7173)?.absoluteString == "http://shoebox.local:7173/")
for host in [nil, "", "example.com", "user@mac.local", "http://mac.local", "mac.local/path", "bad host.local"] as [String?] {
    assert(ServerAddress.bonjourURL(host: host, port: 7171) == nil)
}
assert(ServerAddress.bonjourURL(host: "mac.local", port: 0) == nil)
assert(ServerAddress.bonjourURL(host: "mac.local", port: 65536) == nil)

// Optional live check: publish a matching service with dns-sd before running.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--discover" {
    let expected = CommandLine.arguments[2]
    let discovery = ServerDiscovery()
    discovery.start()
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline && !discovery.servers.contains(where: { $0.name == expected }) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    assert(discovery.servers.contains(where: { $0.name == expected }), "Bonjour did not discover \(expected): \(discovery.error ?? "timeout")")
    assert(Set(discovery.servers.map(\.id)).count == discovery.servers.count, "Duplicate servers")
    let found = discovery.servers.first { $0.name == expected }!
    let service = NetService(domain: "local.", type: "_http._tcp.", name: expected)
    discovery.netServiceBrowser(NetServiceBrowser(), didRemove: service, moreComing: false)
    assert(!discovery.servers.contains { $0.id == found.id }, "Removed server must disappear")
    discovery.stop()
    assert(discovery.servers.isEmpty && !discovery.searching)
    print("Bonjour discovery, resolution, removal, and stop checks passed")
}
