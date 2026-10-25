import Foundation

/// `fcode://pair?server=<https origin>` from a QR or share link (contract DECISION r2). It
/// carries ONLY the server: the 6-digit code is always typed by the user, so another app that
/// claims the `fcode` scheme learns nothing but the public address.
///
/// Origins are parsed and built as plain strings (no URLComponents host/scheme setters, no
/// IDN): what is shown is byte for byte what is connected to.
struct PairLink: Equatable {
    /// Canonical origin, `https://host[:port]`.
    let server: String

    /// The link must be `fcode://pair` and `server` exactly an https origin (see `strict`).
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "fcode", url.host?.lowercased() == "pair",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "server" })?.value,
              let origin = PairLink.strict(raw)
        else { return nil }
        server = origin
    }

    /// FCode server origin rule v1 (test/origin-vectors.json "rule", shared with server.mjs):
    /// raw input printable ASCII 0x21-0x7E, then lowercased; `https://` + host + optional
    /// `:port` + optional single `/`. Host: bracketed IPv6 (inet_pton, no `%`, kept as typed),
    /// IPv4 (4 decimal octets 0-255, no leading zeros, NO trailing dot), or a name (one
    /// trailing dot dropped; >= 2 LDH labels of 1-63, no edge `-`, no `xn--`, <= 253, last
    /// label not numeric). Port: 1-5 digits, no leading zero, 1-65535; 443 left out.
    /// No extra reject step: the Foundation URL round trip is NOT checked here. The self-test
    /// asserts it on every accepted vector, and a disagreement is a bug to report.
    static func strict(_ input: String) -> String? {
        // Printable ASCII on the RAW input first (per scalar: a lone CR or LF is caught, and
        // lowercasing cannot fold e.g. KELVIN SIGN into "k").
        guard !input.isEmpty, input.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        let s = input.lowercased()
        guard s.hasPrefix("https://") else { return nil }
        var rest = Substring(s.dropFirst("https://".count))
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        let banned = Set("/?#@%\\".unicodeScalars)
        guard !rest.isEmpty, !rest.unicodeScalars.contains(where: { banned.contains($0) }) else { return nil }

        var host: Substring
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[...close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
            var addr = in6_addr()
            guard inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &addr) == 1 else { return nil }
        } else {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            if parts.count == 2 { portText = parts[1] }
            // IPv4 as typed (a trailing dot is refused); only a name may drop one trailing dot.
            if !isIPv4(host) {
                if host.hasSuffix(".") { host = host.dropLast() }
                guard isName(host) else { return nil }
            }
        }

        var port: Int?
        if let text = portText {
            guard isDigits(text), text.count <= 5, !text.hasPrefix("0"),
                  let n = Int(text), (1...65535).contains(n) else { return nil }
            port = n == 443 ? nil : n
        }
        return "https://" + host + (port.map { ":\($0)" } ?? "")
    }

    private static func isDigits<S: StringProtocol>(_ s: S) -> Bool {
        !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Exactly 4 decimal octets 0–255, no leading zeros ("0" yes, "010" no): read the same by
    /// everyone (inet_aton and WHATWG would read "010" as octal).
    private static func isIPv4(_ host: Substring) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            isDigits(p) && p.count <= 3 && (p.count == 1 || !p.hasPrefix("0")) && Int(p)! <= 255
        }
    }

    /// A last label that WHATWG / inet_aton would read as a number: `[0-9]+` or `0x[0-9a-f]*`.
    static func isNumericLabel<S: StringProtocol>(_ label: S) -> Bool {
        isDigits(label)
            || (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
    }

    private static func isName(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count >= 2,
              // A numeric last label makes it an IP address, which must pass isIPv4 instead.
              !isNumericLabel(labels.last ?? "") else { return false }
        return labels.allSatisfy { l in
            (1...63).contains(l.count) && !l.hasPrefix("-") && !l.hasSuffix("-") && !l.hasPrefix("xn--")
                && l.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// Lenient, for what the user typed or what an older build stored: a missing scheme means
    /// https, and a path, query or fragment is cut off; the rest must pass `strict`.
    static func origin(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("https://") && !s.contains("://") { s = "https://" + s }
        if s.lowercased().hasPrefix("https://") {
            let start = s.index(s.startIndex, offsetBy: "https://".count)
            if let cut = s[start...].firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<cut]) }
        }
        return strict(s).flatMap(URL.init(string:))
    }

    /// "host" or "host:port", exactly as connected to.
    static func label(_ server: String) -> String {
        server.hasPrefix("https://") ? String(server.dropFirst("https://".count)) : server
    }

    /// Migration: a server address an older build stored ("" = none) that this build can still
    /// talk to. false = the app asks to pair again and sends that server nothing.
    static func isSupportedStored(_ stored: String) -> Bool { stored.isEmpty || origin(stored) != nil }

    /// ONLY for a raw stored address this build rejects (the card): the host part with
    /// printable ASCII as is and every other scalar as `\u{XXXX}`; past 100 scalars it is cut
    /// and ends in "…". Canonical addresses are shown with `label` instead, never cut.
    static func escapedAuthority(_ stored: String) -> String {
        var s = Substring(stored)
        if let r = s.range(of: "://") { s = s[r.upperBound...] }
        if let cut = s.firstIndex(where: { "/?#".contains($0) }) { s = s[..<cut] }
        let shown = s.unicodeScalars.prefix(100).map { u in
            (0x21..<0x7F).contains(u.value) ? String(u) : String(format: "\\u{%04X}", u.value)
        }.joined()
        return s.unicodeScalars.count > 100 ? shown + "…" : shown
    }

    /// The shared table (test/origin-vectors.json, `vectors`: [input, canonical or null]) through
    /// `strict`; one line per failure. Run by the CI self-test step with the file's path.
    static func checkVectors(_ json: Data) -> [String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let vectors = obj["vectors"] as? [[Any]], !vectors.isEmpty else { return ["vectors file unreadable"] }
        var failures: [String] = []
        for v in vectors {
            // Expected must be a string or JSON null; anything else is a broken vector.
            guard v.count == 2, let input = v[0] as? String, v[1] is String || v[1] is NSNull
            else { failures.append("bad vector \(v)"); continue }
            let want = v[1] as? String
            let got = strict(input)
            if got != want { failures.append("\(input.debugDescription): want \(want ?? "null"), got \(got ?? "null")") }
            // Assertion only (never a reject in strict): Foundation must print it unchanged.
            if let got = got, URL(string: got)?.absoluteString != got {
                failures.append("\(input.debugDescription): URL round trip disagrees (\(URL(string: got)?.absoluteString ?? "nil"))")
            }
        }
        return failures
    }

    /// Fixed cases; one line per failure (empty = all pass). Run by the CI self-test step.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func link(_ name: String, _ server: String, _ want: String?) {
            let enc = server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? server
            let got = URL(string: "fcode://pair?server=\(enc)").flatMap(PairLink.init)?.server
            if got != want { failures.append("link \(name): got \(got ?? "nil")") }
        }
        func strict(_ name: String, _ input: String, _ want: String?) {
            let got = PairLink.strict(input)
            if got != want { failures.append("strict \(name): got \(got ?? "nil")") }
            // Round trip: an accepted origin is exactly what URL prints.
            if let got = got, URL(string: got)?.absoluteString != got { failures.append("round trip \(name)") }
        }
        // Accepted.
        strict("plain", "https://box.example.com", "https://box.example.com")
        strict("slash", "https://box.example.com/", "https://box.example.com")
        strict("trailing dot", "https://box.example.com.", "https://box.example.com")
        strict("port", "https://box.example.com:8443", "https://box.example.com:8443")
        strict("port 443", "https://box.example.com:443/", "https://box.example.com")
        strict("port 65535", "https://box.example.com:65535", "https://box.example.com:65535")
        strict("uppercase", "HTTPS://Box.Example.COM", "https://box.example.com")
        strict("ipv4", "https://192.168.1.10:8443", "https://192.168.1.10:8443")
        strict("ipv6 port", "https://[2001:db8::1]:8443", "https://[2001:db8::1]:8443")
        strict("ipv6", "https://[::1]", "https://[::1]")
        strict("ipv4 zero octet", "https://10.0.0.1", "https://10.0.0.1")
        strict("digit inside name", "https://box1.example2.com", "https://box1.example2.com")
        strict("hex-looking non-last", "https://0x7f.example.com", "https://0x7f.example.com")
        // Rejected.
        for (name, bad) in [
            ("xn--", "https://xn--80ak6aa92e.com"), ("xn-- inner", "https://a.xn--a.com"),
            ("non-ascii", "https://bücher.de"), ("h..", "https://h.."), ("a..b", "https://a..b.com"),
            ("-a.b", "https://-a.b"), ("a-.b", "https://a-.b"), ("no dot", "https://localhost"),
            ("port 0", "https://box.example.com:0"), ("port 65536", "https://box.example.com:65536"),
            ("port 08x", "https://box.example.com:08x"), ("port empty", "https://box.example.com:"),
            ("userinfo", "https://u:p@box.example.com"), ("query", "https://box.example.com?q"),
            ("query slash", "https://box.example.com/?all=1"), ("fragment", "https://box.example.com#f"),
            ("path", "https://box.example.com/path"), ("percent", "https://box%2eexample.com"),
            ("http", "http://box.example.com"), ("no scheme", "box.example.com"),
            ("bad ipv4", "https://1.2.3.999"), ("bad ipv6", "https://[2001:db8::g]"),
            ("ipv6 zone", "https://[fe80::1%25en0]"), ("ipv6 tail", "https://[::1]x"),
            ("long label", "https://" + String(repeating: "a", count: 64) + ".com"),
            ("ipv4 leading zeros", "https://192.168.001.010"), ("ipv4 hex last", "https://1.2.3.0x4"),
            ("ipv4 all hex", "https://0x7f.0x0.0x0.0x1"), ("ipv4 3 parts", "https://1.2.3"),
            ("kelvin sign", "https://\u{212A}.example.com"), ("lone cr", "https://box.example.com\r"),
            ("lone lf", "https://box\n.example.com"), ("tab", "https://box.example.com\t"),
            ("underscore", "https://a_b.example.com"),
        ] {
            strict(name, bad, nil)
        }
        // Links: only the server counts; uppercase-only differences are the same server.
        link("valid", "https://box.example.com", "https://box.example.com")
        link("upper", "https://BOX.example.com", "https://box.example.com")
        link("ipv6", "https://[2001:db8::1]:8443", "https://[2001:db8::1]:8443")
        link("xn--", "https://xn--a.com", nil)
        link("path", "https://box.example.com/x", nil)
        if URL(string: "fcode://pair?code=123456").flatMap(PairLink.init) != nil { failures.append("link without server") }
        if URL(string: "fcode://other?server=https%3A%2F%2Fbox.example.com").flatMap(PairLink.init) != nil {
            failures.append("link other host")
        }
        // Lenient entry: scheme added, path/query cut, still strict on the host.
        if PairLink.origin("box.example.com/x?all=1#z")?.absoluteString != "https://box.example.com" {
            failures.append("origin cuts path")
        }
        if PairLink.origin("http://box.example.com") != nil { failures.append("origin rejects http") }
        if PairLink.origin("https://xn--a.com") != nil { failures.append("origin rejects xn--") }
        if PairLink.label("https://[::1]:8443") != "[::1]:8443" { failures.append("label") }
        // Migration classification of what older builds stored.
        for (stored, ok) in [("", true), ("https://box.example.com", true), ("https://box.example.com/", true),
                             ("https://xn--bcher-kva.de", false), ("https://fcodebox", false),
                             ("https://a_b.example.com", false), ("https://192.168.001.010", false)]
        where PairLink.isSupportedStored(stored) != ok {
            failures.append("stored \(stored): want \(ok)")
        }
        if PairLink.escapedAuthority("https://bücher.de/x") != "b\\u{00FC}cher.de" {
            failures.append("escaped: \(PairLink.escapedAuthority("https://bücher.de/x"))")
        }
        let long = String(repeating: "a", count: 120)
        if PairLink.escapedAuthority("https://" + long) != String(repeating: "a", count: 100) + "…" {
            failures.append("escaped cut marker")
        }
        failures += CardFlow.selfTest().map { "CardFlow " + $0 }
        return failures
    }
}

/// The unsupported-server card as a pure state machine. Invariant: nothing local is deleted
/// unless a pairing with a new server SUCCEEDS or the user CONFIRMS "Đăng xuất".
enum CardFlow {
    enum State: CaseIterable { case card, pairing, confirmSignOut, left }
    enum Event: CaseIterable { case link, pairAgain, cancel, pairSuccess, pairFail, signOut, signOutConfirm, signOutCancel }

    /// Next state, and whether to run the one cleanup (drafts, read marks, old login, old box notice).
    static func step(_ state: State, _ event: Event) -> (state: State, cleanup: Bool) {
        switch (state, event) {
        case (.left, _): return (.left, false)
        case (_, .pairSuccess): return (.left, true)
        case (_, .link): return (.pairing, false)                      // a link always opens pairing
        case (.card, .pairAgain): return (.pairing, false)
        case (.card, .signOut): return (.confirmSignOut, false)
        case (.pairing, .cancel): return (.card, false)
        case (.confirmSignOut, .signOutConfirm): return (.left, true)
        case (.confirmSignOut, .signOutCancel): return (.card, false)
        default: return (state, false)                               // pairFail and stray events
        }
    }

    static func selfTest() -> [String] {
        var failures: [String] = []
        for s in State.allCases {
            for e in Event.allCases {
                let r = step(s, e)
                let mayClean = s != .left && (e == .pairSuccess || (e == .signOutConfirm && s == .confirmSignOut))
                if r.cleanup != mayClean { failures.append("\(s) + \(e): cleanup \(r.cleanup)") }
                if r.cleanup && r.state != .left { failures.append("\(s) + \(e): cleanup without leaving") }
            }
        }
        // Huỷ on the sign-out alert: back to the card, never a cleanup.
        let cancel = step(.confirmSignOut, .signOutCancel)
        if cancel.cleanup || cancel.state != .card { failures.append("confirmSignOut + signOutCancel: \(cancel)") }
        // The alert's deferred cancel can land in any other state: there it changes nothing.
        for s in State.allCases where s != .confirmSignOut {
            let r = step(s, .signOutCancel)
            if r.cleanup || r.state != s { failures.append("\(s) + signOutCancel: \(r)") }
        }
        // Confirm then the deferred cancel: stays left, one cleanup only.
        let confirmed = step(.confirmSignOut, .signOutConfirm)
        let late = step(confirmed.state, .signOutCancel)
        if !confirmed.cleanup || late.cleanup || late.state != .left { failures.append("confirm then late cancel: \(confirmed), \(late)") }
        let path: [(State, Event, State)] = [
            (.card, .link, .pairing), (.card, .pairAgain, .pairing), (.pairing, .cancel, .card),
            (.pairing, .pairFail, .pairing), (.pairing, .link, .pairing), (.card, .signOut, .confirmSignOut),
            (.confirmSignOut, .signOutCancel, .card), (.confirmSignOut, .link, .pairing),
            (.card, .cancel, .card), (.card, .signOutConfirm, .card),
        ]
        for (s, e, want) in path where step(s, e).state != want {
            failures.append("\(s) + \(e) -> \(step(s, e).state), want \(want)")
        }
        return failures
    }
}
