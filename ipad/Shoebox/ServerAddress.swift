import Foundation

enum ServerAddress {
    static func bonjourURL(host: String?, port: Int) -> URL? {
        guard var host, !host.isEmpty, (1...65535).contains(port) else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        // Bonjour host names are local DNS names, never URLs or credentials.
        guard host.lowercased().hasSuffix(".local"),
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-.".unicodeScalars.contains($0) }) else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = port
        parts.path = "/"
        return parts.url
    }

    static func parse(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              var parts = URLComponents(string: text.contains("://") ? text : "http://\(text)"),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !host.contains(" "),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        if parts.port == nil { parts.port = parts.scheme == "https" ? 443 : 7171 }
        parts.path = "/"
        return parts.url
    }

    static func sameOrigin(_ url: URL?, as server: URL) -> Bool {
        guard let url else { return false }
        func port(_ value: URL) -> Int { value.port ?? (value.scheme == "https" ? 443 : 80) }
        return url.scheme == server.scheme && url.host?.lowercased() == server.host?.lowercased()
            && port(url) == port(server)
    }
}
