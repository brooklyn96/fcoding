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
    static func origin(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        var o = URLComponents()
        o.scheme = "https"
        o.host = host.lowercased()
        o.port = c.port
        return o.url
    }

    /// "host" or "host:port", for the confirmation texts.
    static func label(_ server: String) -> String {
        guard let c = URLComponents(string: server), let host = c.host else { return server }
        return c.port.map { "\(host):\($0)" } ?? host
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
        check("http", "fcode://pair?server=http%3A%2F%2Fbox.example.com", nil)
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
        if PairLink.label("https://box.example.com:8443") != "box.example.com:8443" { failures.append("label port") }
        return failures
    }
}
