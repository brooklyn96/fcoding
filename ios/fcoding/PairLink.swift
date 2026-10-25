import Foundation

/// `fcode://pair?server=<https origin>` from a QR or share link (contract DECISION r2). It
/// carries ONLY the server: the 6-digit code is always typed by the user, so another app that
/// claims the `fcode` scheme learns nothing but the public address.
struct PairLink: Equatable {
    /// Canonical origin, `https://host[:port]`.
    let server: String

    /// Strict: the link must be `fcode://pair` and `server` exactly an https origin (an optional
    /// trailing "/" only): no user info, path, query or fragment.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "fcode", url.host?.lowercased() == "pair",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "server" })?.value,
              let c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              let origin = PairLink.origin(raw)
        else { return nil }
        server = origin.absoluteString
    }

    /// `https://host[:port]` from what the user typed or a link held; path, query and fragment
    /// are dropped. nil unless https with a host and no user info. A missing scheme means https.
    /// Canonical, so one box is always one string: lowercase host, one trailing "." dropped,
    /// the default port 443 left out. Works on the ENCODED host (punycode, IPv6 brackets kept),
    /// never the IDNA-decoded `host`. Rejects empty labels and ports outside 1...65535.
    static func origin(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, var host = c.encodedHost?.lowercased() else { return nil }
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }   // IPv6 literal
        if host.hasSuffix(".") { host.removeLast() }
        if !host.hasPrefix("[") {
            guard !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
            else { return nil }
        }
        if let port = c.port, !(1...65535).contains(port) { return nil }
        if c.encodedHost != host { c.encodedHost = host }
        c.scheme = "https"
        c.port = c.port == 443 ? nil : c.port
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    /// "host" or "host:port" exactly as connected to (punycode, never decoded).
    static func host(_ server: String) -> String {
        guard let c = URLComponents(string: server), let host = c.encodedHost?.lowercased() else { return server }
        return c.port.map { "\(host):\($0)" } ?? host
    }

    /// Tag shown after an internationalised (punycode) host, else nil.
    static func idnTag(_ server: String) -> String? {
        host(server).contains("xn--") ? "(tên miền quốc tế)" : nil
    }

    /// `host(_:)` plus the IDN tag, for plain-text messages.
    static func label(_ server: String) -> String {
        [host(server), idnTag(server)].compactMap { $0 }.joined(separator: " ")
    }

    /// Fixed cases; one line per failure (empty = all pass). Run by the CI self-test step.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ link: String, _ want: String?) {
            let got = URL(string: link).flatMap(PairLink.init)?.server
            if got != want { failures.append("\(name): got \(got ?? "nil")") }
        }
        let enc = "https%3A%2F%2Fbox.example.com"
        check("valid", "fcode://pair?server=\(enc)", "https://box.example.com")
        check("valid slash", "fcode://pair?server=https%3A%2F%2FBox.Example.com%2F", "https://box.example.com")
        check("port", "fcode://pair?server=https%3A%2F%2Fbox.example.com%3A8443", "https://box.example.com:8443")
        check("port 443", "fcode://pair?server=\(enc)%3A443", "https://box.example.com")
        check("trailing dot", "fcode://pair?server=https%3A%2F%2Fbox.example.com.", "https://box.example.com")
        check("http","fcode://pair?server=http%3A%2F%2Fbox.example.com", nil)
        check("no scheme", "fcode://pair?server=box.example.com", nil)
        check("userinfo", "fcode://pair?server=https%3A%2F%2Fu%3Ap%40box.example.com", nil)
        check("path", "fcode://pair?server=\(enc)%2Fx", nil)
        check("query", "fcode://pair?server=\(enc)%2F%3Fall%3D1", nil)
        check("query no slash", "fcode://pair?server=\(enc)%3Fall%3D1", nil)
        check("fragment", "fcode://pair?server=\(enc)%23z", nil)
        check("missing server", "fcode://pair?code=123456", nil)
        check("other host", "fcode://other?server=\(enc)", nil)
        check("other scheme", "https://pair?server=\(enc)", nil)
        // A code in the link (older server) is never read: only the server counts.
        check("code ignored", "fcode://pair?server=\(enc)&code=12345", "https://box.example.com")
        if PairLink.origin("box.example.com/x?all=1#z")?.absoluteString != "https://box.example.com" {
            failures.append("origin strips path/query")
        }
        if PairLink.origin("http://box.example.com") != nil { failures.append("origin rejects http") }
        if PairLink.origin("box.example.com:443")?.absoluteString != "https://box.example.com" {
            failures.append("origin drops :443")
        }
        if PairLink.origin("https://Box.Example.com.:443/")?.absoluteString != "https://box.example.com" {
            failures.append("origin dot + 443")
        }
        if PairLink.origin("https://.") != nil { failures.append("origin rejects bare dot") }
        // Punycode stays punycode (homograph check), with the tag.
        let idn = "https://xn--80ak6aa92e.com"
        check("punycode link", "fcode://pair?server=https%3A%2F%2Fxn--80ak6aa92e.com", idn)
        if PairLink.host(idn) != "xn--80ak6aa92e.com" { failures.append("host punycode: \(PairLink.host(idn))") }
        if PairLink.label(idn) != "xn--80ak6aa92e.com (tên miền quốc tế)" { failures.append("label punycode: \(PairLink.label(idn))") }
        if PairLink.label("https://box.example.com") != "box.example.com" { failures.append("label plain") }
        // IPv6 keeps its brackets.
        let v6 = "https://[2001:db8::1]:8443"
        if PairLink.origin(v6)?.absoluteString != v6 { failures.append("origin ipv6: \(PairLink.origin(v6)?.absoluteString ?? "nil")") }
        if PairLink.host(v6) != "[2001:db8::1]:8443" { failures.append("host ipv6: \(PairLink.host(v6))") }
        check("ipv6 link", "fcode://pair?server=https%3A%2F%2F%5B2001%3Adb8%3A%3A1%5D%3A8443", v6)
        // Empty labels and bad ports.
        for bad in ["https://h..", "https://a..b", "https://.a", "https://box.example.com:0", "https://box.example.com:65536"]
        where PairLink.origin(bad) != nil {
            failures.append("origin accepts \(bad)")
        }
        if PairLink.origin("https://box.example.com:65535")?.absoluteString != "https://box.example.com:65535" {
            failures.append("origin port 65535")
        }
        if PairLink.label("https://box.example.com:8443") != "box.example.com:8443" { failures.append("label port") }
        return failures
    }
}
