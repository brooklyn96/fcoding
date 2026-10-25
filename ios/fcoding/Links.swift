import Foundation
import SwiftUI

/// Tappable http/https links in the screen text. `find` is pure: text + terminal width in, links
/// out. `apply` puts them on the styled text without changing what is displayed.
enum Links {
    struct Link: Equatable {
        /// The full URL, joined across hard-wrapped lines.
        var url: URL
        /// The visible pieces, one per screen line, as unicode-scalar offsets into the text.
        var pieces: [Range<Int>]
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// RFC 3986 unreserved and reserved characters, plus "%".
    static func isURLChar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return "-._~:/?#[]@!$&'()*+,;=%".unicodeScalars.contains(c)
        }
    }

    /// Links in `text` (screen lines separated by "\n"). With `joinWraps` (omp sessions only: omp
    /// hard-wraps long URLs at the margin and indents the rest), a URL may continue on the next
    /// line; see `continuation` for the exact rule. Other sessions never join.
    static func find(in text: String, cols: Int, joinWraps: Bool) -> [Link] {
        guard let detector = detector, text.contains("http") else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.unicodeScalars.count + 1
        }
        // Per line: how many leading scalars already belong to a link from the line above.
        var consumed: [Int: Int] = [:]
        var out: [Link] = []
        for (i, line) in lines.enumerated() where line.contains("http") {
            let ns = line as NSString
            for match in detector.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(match.range, in: line) else { continue }
                let matched = String(line[r])
                let lower = matched.lowercased()
                guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
                let lo = line.unicodeScalars.distance(from: line.unicodeScalars.startIndex, to: r.lowerBound)
                let hi = lo + matched.unicodeScalars.count
                if let head = consumed[i], lo < head { continue }
                var full = matched
                var pieces = [(starts[i] + lo)..<(starts[i] + hi)]
                var cur = i
                var begin = lo
                var end = hi
                while joinWraps, cur + 1 < lines.count,
                      let cont = continuation(of: lines[cur], urlStart: begin, urlEnd: end, url: full,
                                              next: lines[cur + 1], cols: cols) {
                    full += cont.text
                    pieces.append((starts[cur + 1] + cont.range.lowerBound)..<(starts[cur + 1] + cont.range.upperBound))
                    consumed[cur + 1] = cont.range.upperBound
                    cur += 1
                    begin = cont.range.lowerBound
                    end = cont.range.upperBound
                }
                guard let url = URL(string: full), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                out.append(Link(url: url, pieces: pieces))
            }
        }
        return out
    }

    /// The part of `next` that continues `url` (on `line` at scalar offsets `urlStart..<urlEnd`), or
    /// nil. Joins only when all of these hold:
    /// - the URL is the whole visible text of `line`: only an indent of at least 1 space before it,
    ///   nothing after it (so `Link: https://…` and `remote:   https://…` never join);
    /// - `line` is exactly `cols` or `cols - 1` cells wide (a wider line was already joined by
    ///   `capture-pane -J` and is never joined again);
    /// - `next` has exactly the same indent;
    /// - the first word of `next`, after dropping trailing `.,;:!?` and an unbalanced `)` or `]` (as
    ///   NSDataDetector does on the first line), looks like the rest of a URL: it has one of
    ///   `/ ? # = & % _ -`, or a "." with more after it.
    /// Accepted miss: a wrap right before a plain word (`…/box/p` then `ending, …`) does not join,
    /// so only the first part of that link opens.
    static func continuation(of line: String, urlStart: Int, urlEnd: Int, url: String, next: String,
                             cols: Int) -> (text: String, range: Range<Int>)? {
        guard cols > 0 else { return nil }
        let scalars = Array(line.unicodeScalars)
        var end = scalars.count
        while end > 0, scalars[end - 1] == " " { end -= 1 }
        guard urlEnd == end, urlStart >= 1, urlStart < end,
              scalars[0..<urlStart].allSatisfy({ $0 == " " }) else { return nil }
        // Width in cells: one per character (the screen is monospaced).
        let width = String(String.UnicodeScalarView(scalars[0..<end])).count
        guard width == cols || width == cols - 1 else { return nil }

        let n = Array(next.unicodeScalars)
        var start = 0
        while start < n.count, n[start] == " " { start += 1 }
        guard start == urlStart else { return nil }
        var stop = start
        while stop < n.count, isURLChar(n[stop]) { stop += 1 }
        // The next character after the token must end it (a space or the end of the line).
        guard stop > start, stop == n.count || n[stop] == " " else { return nil }

        var tok = Array(n[start..<stop])
        func count(_ c: Unicode.Scalar) -> Int {
            url.unicodeScalars.filter { $0 == c }.count + tok.filter { $0 == c }.count
        }
        while let last = tok.last {
            if ".,;:!?".unicodeScalars.contains(last)
                || (last == ")" && count(")") > count("("))
                || (last == "]" && count("]") > count("[")) {
                tok.removeLast()
            } else { break }
        }
        guard !tok.isEmpty else { return nil }
        let token = String(String.UnicodeScalarView(tok))
        if token.lowercased().hasPrefix("http") { return nil } // a new URL, not the rest of this one
        let urlish = token.unicodeScalars.contains { "/?#=&%_-".unicodeScalars.contains($0) }
            || token.dropLast().contains(".")
        guard urlish else { return nil }
        return (token, start..<(start + tok.count))
    }

    /// Adds a `.link` and an underline to every piece; the text itself is unchanged. SwiftUI
    /// `Text` draws `.link` runs in the view's tint colour whatever `.foregroundColor` they carry,
    /// so a link shows in the tint, underlined, not in its ANSI colour.
    static func apply(_ links: [Link], to s: inout AttributedString) {
        #if DEBUG
        _ = checked
        #endif
        let total = s.unicodeScalars.count
        let pieces = links.flatMap { l in l.pieces.map { (range: $0, url: l.url) } }
            .filter { $0.range.upperBound <= total && !$0.range.isEmpty }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        // One pass: a single index walks forward through the sorted pieces.
        var idx = s.unicodeScalars.startIndex
        var pos = 0
        for p in pieces where p.range.lowerBound >= pos {
            let lo = s.unicodeScalars.index(idx, offsetBy: p.range.lowerBound - pos)
            let hi = s.unicodeScalars.index(lo, offsetBy: p.range.count)
            var c = AttributeContainer()
            c[AttributeScopes.FoundationAttributes.LinkAttribute.self] = p.url
            c[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            s[lo..<hi].mergeAttributes(c)
            idx = hi
            pos = p.range.upperBound
        }
    }

    #if DEBUG
    /// Runs `selfTest` once, on the first `apply` of a Debug build.
    private static let checked: Void = {
        let failures = selfTest()
        assert(failures.isEmpty, "Links self-test: " + failures.joined(separator: "; "))
    }()
    #endif

    /// Fixed cases through `find`; returns one line per failure (empty = all pass). Compiled in
    /// every configuration so the Release CI build type-checks it; it runs only in Debug.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ text: String, cols: Int, omp: Bool = true, _ urls: [String],
                   pieces: [Int]? = nil) {
            let got = find(in: text, cols: cols, joinWraps: omp)
            if got.map(\.url.absoluteString) != urls {
                failures.append("\(name): urls \(got.map(\.url.absoluteString))")
            } else if let pieces = pieces, got.first?.pieces.map(\.count) != pieces {
                failures.append("\(name): pieces \(got.first?.pieces.map(\.count) ?? [])")
            }
        }
        let pr = "https://github.com/brooklyn96/BD-Team-Project/pull/new/box/p"
        let prFull = "https://github.com/brooklyn96/BD-Team-Project/pull/new/box/pending-fixes"
        // Real omp wraps: they join.
        check("omp 46", "  https://github.com/b96/fcodes/pull/new/box/p\n  ending-fixes", cols: 46,
              ["https://github.com/b96/fcodes/pull/new/box/pending-fixes"], pieces: [44, 12])
        check("omp 65 comma", "    \(pr)\n    ending-fixes, hoặc đăng nhập gh …", cols: 65, [prFull], pieces: [60, 12])
        check("omp paren", "    \(pr)\n    ending-fixes).", cols: 65, [prFull], pieces: [60, 12])
        // Not omp: the same lines never join.
        check("not omp", "    \(pr)\n    ending-fixes, hoặc đăng nhập gh …", cols: 65, omp: false, [pr])
        // Text before the URL on its line: never joins.
        check("readme", "  Docs: https://github.com/brooklyn96/fcoding/blob/main/README\n  for the setup steps.", cols: 63,
              ["https://github.com/brooklyn96/fcoding/blob/main/README"], pieces: [54])
        check("remote 64", "remote: https://github.com/brooklyn96/BD-Team-Project/pull/new/b\nremote:", cols: 65,
              ["https://github.com/brooklyn96/BD-Team-Project/pull/new/b"], pieces: [56])
        check("Link: 65", "Link: https://github.com/brooklyn96/BD-Team-Project/pull/new/bx/p\n  done", cols: 65,
              ["https://github.com/brooklyn96/BD-Team-Project/pull/new/bx/p"])
        check("table", "│ https://example.com/a/b │\n│ more/x │", cols: 27, ["https://example.com/a/b"], pieces: [23])
        // capture-pane -J already joined a tmux soft wrap: the line is wider than cols.
        check("-J", "remote:      \(prFull)\nremote:", cols: 65, [prFull], pieces: [72])
        // A different indent below (a prompt, an ls listing): never joins.
        check("prompt", "    \(pr)\nquoc@coder:/data/workspace/deal-sync$ ls", cols: 65, [pr], pieces: [60])
        check("ls 65", "https://github.com/brooklyn96/BD-Team-Project/pull/new/box/pendin\nREADME.md  install.sh  server.mjs",
              cols: 65, ["https://github.com/brooklyn96/BD-Team-Project/pull/new/box/pendin"], pieces: [65])
        // A plain word below: never joins.
        check("done.", "  https://github.com/brooklyn96/fcoding/pull/12\n  done.", cols: 47,
              ["https://github.com/brooklyn96/fcoding/pull/12"], pieces: [45])
        // Punctuation on the first line, and two URLs on one line.
        check("paren", "See (https://example.com/x).", cols: 80, ["https://example.com/x"])
        check("two", "a https://a.example/x and https://b.example/y", cols: 80,
              ["https://a.example/x", "https://b.example/y"])
        return failures
    }
}
