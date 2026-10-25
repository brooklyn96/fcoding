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

    /// Links in `text` (screen lines separated by "\n"). A URL that ends at or within 1 cell of the
    /// right margin (`cols`) continues on the next line when that line, after its leading spaces,
    /// starts with URL characters (omp hard-wraps long URLs and indents the rest).
    static func find(in text: String, cols: Int) -> [Link] {
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
                var end = hi
                while cur + 1 < lines.count,
                      let cont = continuation(of: lines[cur], urlEnd: end, next: lines[cur + 1], cols: cols) {
                    full += cont.text
                    pieces.append((starts[cur + 1] + cont.range.lowerBound)..<(starts[cur + 1] + cont.range.upperBound))
                    consumed[cur + 1] = cont.range.upperBound
                    cur += 1
                    end = cont.range.upperBound
                }
                guard let url = URL(string: full), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                out.append(Link(url: url, pieces: pieces))
            }
        }
        return out
    }

    /// The part of `next` that continues a URL ending at scalar offset `urlEnd` of `line`, or nil.
    /// Joins only when the URL reaches the end of `line`, that end is at or within 1 cell of the
    /// margin, and `next` (after leading spaces) starts with URL characters. After a full stop, a
    /// first word followed by more words is a new sentence, not a continuation.
    static func continuation(of line: String, urlEnd: Int, next: String, cols: Int) -> (text: String, range: Range<Int>)? {
        guard cols > 0 else { return nil }
        let scalars = Array(line.unicodeScalars)
        var end = scalars.count
        while end > 0, scalars[end - 1] == " " { end -= 1 }
        guard urlEnd == end, end > 0 else { return nil }
        // Width in cells: one per character (the screen is monospaced).
        let width = String(String.UnicodeScalarView(scalars[0..<end])).count
        guard width >= cols - 1 else { return nil }

        let n = Array(next.unicodeScalars)
        var start = 0
        while start < n.count, n[start] == " " { start += 1 }
        var stop = start
        while stop < n.count, isURLChar(n[stop]) { stop += 1 }
        guard stop > start else { return nil }
        // The next character after the token must end it (a space or the end of the line).
        guard stop == n.count || n[stop] == " " else { return nil }
        let token = String(String.UnicodeScalarView(n[start..<stop]))
        if token.lowercased().hasPrefix("http") { return nil } // a new URL, not the rest of this one
        if scalars[end - 1] == ".", n[stop...].contains(where: { $0 != " " }) { return nil }
        return (token, start..<stop)
    }

    /// Adds a `.link` and an underline to every piece; the text itself is unchanged.
    static func apply(_ links: [Link], to s: inout AttributedString) {
        let total = s.unicodeScalars.count
        for link in links {
            var c = AttributeContainer()
            c[AttributeScopes.FoundationAttributes.LinkAttribute.self] = link.url
            c[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            for r in link.pieces where r.upperBound <= total && !r.isEmpty {
                let v = s.unicodeScalars
                let lo = v.index(v.startIndex, offsetBy: r.lowerBound)
                let hi = v.index(lo, offsetBy: r.count)
                s[lo..<hi].mergeAttributes(c)
            }
        }
    }
}
