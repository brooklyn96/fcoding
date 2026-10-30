import Foundation

/// The pure parts of the live screen feed, run off the main actor and self-tested in CI: the SSE
/// line splitter and the `event: patch` apply of GET /api/stream with `delta=1` (CONTRACT.md).
enum ScreenFeed {
    /// SGR colours (an older server ignores it) and, with `delta`, patches (an older server sends
    /// full screens only).
    static func streamQuery(delta: Bool) -> [URLQueryItem] {
        [URLQueryItem(name: "ansi", value: "1")] + (delta ? [URLQueryItem(name: "delta", value: "1")] : [])
    }

    /// A patch that does not apply to the screen held here: the stream is dropped (a new stream
    /// starts with a full screen), so a patch never lands on the wrong base.
    struct Mismatch: Error {}

    /// Patches in a row that did not apply. Only the first reconnects at once; a repeat is a normal
    /// stream failure (backoff, polling). After `limit` in a row this screen stops asking for
    /// patches (full screens only, for as long as it is open). Reset only by a patch that applies:
    /// every reconnect starts with a full screen, so a screen proves nothing about patches.
    struct Mismatches {
        static let limit = 3
        private(set) var count = 0
        private(set) var delta = true

        /// Records one; true = reconnect at once.
        mutating func record() -> Bool {
            count += 1
            if count >= Mismatches.limit { delta = false }
            return count == 1
        }

        mutating func applied() { count = 0 }
    }

    /// SSE lines: split on LF (0x0A) only, dropping a trailing CR. Foundation's `bytes.lines` also
    /// ends a line at U+0085 / U+2028 / U+2029, which JSON leaves unescaped and would cut a data line.
    struct Lines {
        private var buffer: [UInt8] = []

        /// One byte in; the finished line out at its LF. A runaway line (no LF within 4 MiB) throws:
        /// the stream is dropped and the screen falls back to polling.
        mutating func push(_ byte: UInt8) throws -> String? {
            guard byte == 0x0A else {
                buffer.append(byte)
                if buffer.count > 4 * 1024 * 1024 { throw URLError(.dataLengthExceedsMaximum) }
                return nil
            }
            if buffer.last == 0x0D { buffer.removeLast() }
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    /// The value of an SSE field line, without the one optional space after the colon.
    static func field(_ line: String, _ prefix: String) -> String {
        var value = line.dropFirst(prefix.count)
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }

    /// `event: patch` data: the new line count and every line (`[index, text]`) that changed.
    struct Patch: Decodable {
        struct Line: Decodable {
            let index: Int
            let text: String

            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                index = try c.decode(Int.self)
                text = try c.decode(String.self)
            }
        }

        let base: String
        let hash: String
        let cols: Int?
        let len: Int
        let lines: [Line]
    }

    /// The last screen as lines (split on "\n" as the server splits it) and its hash.
    struct State {
        private(set) var lines: [String] = []
        private(set) var hash: String?

        mutating func set(_ text: String, hash: String?) {
            lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            self.hash = hash
        }

        /// The new full text (equal to the full screen the server would have sent), or nil when `p`
        /// does not apply here: another base, or a line index outside the new length. Nil leaves
        /// the state unchanged.
        mutating func apply(_ p: Patch) -> String? {
            guard p.base == hash, (0...100_000).contains(p.len),
                  p.lines.allSatisfy({ (0..<p.len).contains($0.index) }) else { return nil }
            var next = Array(lines.prefix(p.len))
            if next.count < p.len { next += Array(repeating: "", count: p.len - next.count) }
            for line in p.lines { next[line.index] = line.text }
            lines = next
            hash = p.hash
            return next.joined(separator: "\n")
        }
    }

    /// Where the user was reading a session (kept per server + session). No screen text: the top
    /// visible line is a hash of it and its two neighbours, plus its distance from the last line.
    struct Position: Codable, Equatable {
        var bottom: Bool
        var hash: Int64 = 0
        var fromEnd = 0
        /// Rows from the top line down to the hashed line (the first one whose window is not blank).
        var below = 0
        var time: Double = 0
        /// UTF-16 offset of the top visible row's first character inside the top line (a long line
        /// wraps into several rows); 0 unless the hashed line is the top line itself.
        var col = 0
    }

    /// Line i-1, i and i+1 are all blank (missing ones count as blank): every such window hashes alike.
    static func blank(_ lines: [String], _ i: Int) -> Bool {
        ((i - 1)...(i + 1)).allSatisfy { !lines.indices.contains($0) || lines[$0].allSatisfy(\.isWhitespace) }
    }

    /// FNV-1a over line i-1, i and i+1 (missing ones are empty); stable across launches.
    static func lineHash(_ lines: [String], _ i: Int) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for j in (i - 1)...(i + 1) {
            for b in (lines.indices.contains(j) ? lines[j] : "").utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ 0x0A) &* 0x100000001b3
        }
        return Int64(bitPattern: h)
    }

    /// The anchor for top line `top`: the first line at or below it whose window is not all blank, so
    /// a blank stretch never matches another one. Nothing but blank lines below: the bottom.
    static func anchor(_ lines: [String], top: Int, col: Int = 0, time: Double) -> Position {
        guard let at = lines.indices.first(where: { $0 >= top && !blank(lines, $0) }) else {
            return Position(bottom: true, time: time)
        }
        return Position(bottom: false, hash: lineHash(lines, at), fromEnd: lines.count - at, below: at - top,
                        time: time, col: at == top ? col : 0)
    }

    /// Where the terminal view should be, as a pure state machine (the view only measures and
    /// writes). One target: follow the bottom, keep a saved line at the top, or stay where the user
    /// put it. Only a new screen landing in a layout pass, a user move or a jump changes it.
    struct Reading: Equatable {
        enum Target: Equatable {
            case bottom
            /// A saved line: `line` nil until a layout pass has resolved it on a displayed screen.
            case anchor(Position, line: Int?)
            case free
        }
        /// What the top edge should show now.
        enum Goal: Equatable { case bottom, line(Int, col: Int), none }

        private(set) var target: Target
        /// The displayed screen not yet resolved by a layout pass (nil lines = the loading line).
        private var shown: [String]?
        private var fresh = false

        /// No record or a bottom record: the bottom. An anchor record: that line, once resolved.
        init(record: Position?) {
            if let p = record, !p.bottom { target = .anchor(p, line: nil) } else { target = .bottom }
        }

        var pinned: Bool { target == .bottom }

        /// A new screen was installed in the view. Resolved only by the layout pass that applies it
        /// (`layout`), so two screens before the first usable layout resolve the newest one.
        mutating func screen(_ lines: [String]?) {
            shown = lines
            fresh = true
        }

        /// The layout pass that applies the displayed screen: resolve it, then the goal.
        /// Unresolved anchor: found → that line; not found → the bottom (nothing shown to lose).
        /// Landed anchor: found → follow it; not found → free (keep the live offset), never the bottom.
        /// Each resolve stores the found line's distance from the end. While following, output only
        /// appends, so a copy at least that far from the end wins over a newer copy below it.
        mutating func layout() -> Goal {
            if fresh, case .anchor(var p, let line) = target, let lines = shown {
                let hits = lines.indices.filter { ScreenFeed.lineHash(lines, $0) == p.hash }
                let fromEnd = p.fromEnd
                func nearest(_ c: [Int]) -> Int? {
                    c.min { abs(lines.count - $0 - fromEnd) < abs(lines.count - $1 - fromEnd) }
                }
                let ahead = line == nil ? [] : hits.filter { lines.count - $0 >= fromEnd }
                if let at = nearest(ahead) ?? nearest(hits) {
                    p.fromEnd = lines.count - at
                    target = .anchor(p, line: max(0, at - p.below))
                } else {
                    target = line == nil ? .bottom : .free
                }
            }
            fresh = false
            return goal
        }

        var goal: Goal {
            switch target {
            case .bottom: return .bottom
            case .anchor(let p, let line?): return .line(line, col: p.col)
            default: return .none
            }
        }

        /// A drag starts.
        mutating func moveBegan() { target = .free }
        /// A user move finished (drag, fling, assistive page).
        mutating func moved(atBottom: Bool) { target = atBottom ? .bottom : .free }
        /// Send, the arrow: back to the bottom, following.
        mutating func jump() { target = .bottom }

        /// The record to save. A pending anchor (not landed yet) is kept as it is, whatever the view
        /// shows. A landed anchor is kept across geometry changes, except when the applied viewport
        /// is at the bottom (`atBottom`): then the bottom, so a reopen shows the newest lines.
        func position(firstVisible: Int, col: Int, lines: [String], atBottom: Bool, time: Double) -> Position {
            switch target {
            case .anchor(var p, let line) where line == nil || !atBottom:
                p.time = time
                return p
            case .free where !atBottom:
                return ScreenFeed.anchor(lines, top: firstVisible, col: col, time: time)
            default:
                return Position(bottom: true, time: time)
            }
        }
    }

    /// The line to put back at the top of the view, or nil = go to the bottom (the user was at the
    /// bottom, or the line is gone). Equal matches: the one nearest the stored distance from the end.
    static func topLine(_ p: Position, in lines: [String]) -> Int? {
        guard !p.bottom else { return nil }
        return lines.indices.filter { lineHash(lines, $0) == p.hash }
            .min { abs(lines.count - $0 - p.fromEnd) < abs(lines.count - $1 - p.fromEnd) }
            .map { max(0, $0 - p.below) }
    }

    /// `all` with `p` stored at `key`, keeping only the `keep` most recent positions.
    static func storing(_ p: Position, at key: String, in all: [String: Position], keep: Int = 100) -> [String: Position] {
        var all = all
        all[key] = p
        for old in all.sorted(by: { $0.value.time > $1.value.time }).dropFirst(keep) { all[old.key] = nil }
        return all
    }

    /// One page from `offset` toward the bottom (`down`) or the top: the new offset clamped to
    /// [min, max] and its "page p of n" numbers, n reached exactly at max. Nil when the content fits
    /// (max <= min), page <= 0, or the view cannot move that way.
    static func page(offset: Double, by page: Double, min: Double, max: Double, down: Bool) -> (offset: Double, number: Int, count: Int)? {
        guard page > 0, max > min else { return nil }
        let y = Swift.min(max, Swift.max(min, offset + (down ? page : -page)))
        guard y != offset else { return nil }
        let count = Int(((max - min) / page).rounded(.up)) + 1
        let number = y >= max ? count : Int(((y - min) / page).rounded(.down)) + 1
        return (y, number, count)
    }

    /// The scroll offset that shows the last line at the bottom of a `view` tall scroll view, or the
    /// top when the content fits (UIScrollView offsets start at -insetTop).
    static func bottomOffset(content: Double, view: Double, insetTop: Double, insetBottom: Double) -> Double {
        Swift.max(-insetTop, content + insetBottom - view)
    }

    /// Fixed cases for the splitter and the patch apply; one line per failure (empty = all pass).
    static func selfTest() -> [String] {
        var failures: [String] = []

        func split(_ text: String) -> [String] {
            var s = Lines()
            var out: [String] = []
            for b in text.utf8 { if let line = try? s.push(b) { out.append(line) } }
            return out
        }
        let sse = split("event: screen\r\ndata: {\"a\":1}\n\nevent: patch\ndata: {\"b\":2}\npartial")
        if sse != ["event: screen", "data: {\"a\":1}", "", "event: patch", "data: {\"b\":2}"] {
            failures.append("split: \(sse)")
        }
        // U+0085, U+2028 and U+2029 inside a JSON string never end a line.
        let seps = split("data: a\u{85}b\u{2028}c\u{2029}d\n")
        if seps != ["data: a\u{85}b\u{2028}c\u{2029}d"] { failures.append("separators: \(seps)") }
        var big = Lines()
        var threw = false
        for _ in 0...(4 * 1024 * 1024) {
            do { _ = try big.push(0x41) } catch { threw = true; break }
        }
        if !threw { failures.append("runaway line did not throw") }

        func patch(_ name: String, _ st: inout State, _ json: String, _ want: String?) {
            guard let p = try? JSONDecoder().decode(Patch.self, from: Data(json.utf8)) else {
                failures.append("\(name): decode")
                return
            }
            let got = st.apply(p)
            if got != want { failures.append("\(name): \(got.debugDescription)") }
        }
        var st = State()
        st.set("a\nb\nc", hash: "h1")
        patch("change", &st, #"{"base":"h1","hash":"h2","rows":3,"cols":80,"cursor":{"x":0,"y":1},"len":3,"lines":[[1,"B"]]}"#, "a\nB\nc")
        patch("grow", &st, #"{"base":"h2","hash":"h3","len":5,"lines":[[4,"\u001b[1me\u001b[0m"]]}"#, "a\nB\nc\n\n\u{1B}[1me\u{1B}[0m")
        patch("shrink", &st, #"{"base":"h3","hash":"h4","len":2,"lines":[]}"#, "a\nB")
        patch("other base", &st, #"{"base":"h1","hash":"h5","len":2,"lines":[[0,"x"]]}"#, nil)
        patch("index past len", &st, #"{"base":"h4","hash":"h5","len":2,"lines":[[2,"x"]]}"#, nil)
        patch("unchanged after refusals", &st, #"{"base":"h4","hash":"h5","len":2,"lines":[[0,"x"]]}"#, "x\nB")
        var cr = State()
        cr.set("x\r\ny\n", hash: "c1")
        patch("CR and trailing LF", &cr, #"{"base":"c1","hash":"c2","len":3,"lines":[[1,"z"]]}"#, "x\r\nz\n")
        var empty = State()
        empty.set("", hash: "e1")
        patch("empty screen", &empty, #"{"base":"e1","hash":"e2","len":1,"lines":[]}"#, "")
        var none = State()
        patch("no base yet", &none, #"{"base":"","hash":"n1","len":1,"lines":[]}"#, nil)

        // Mismatches: at once, then backoff, then full screens only (kept after a later success).
        var m = Mismatches()
        let firstRun = [m.record(), m.record()]
        let deltaAfterTwo = m.delta
        m.applied()
        let afterApply = m.record()
        m.applied()
        let row = [m.record(), m.record(), m.record()]
        let deltaAfterThree = m.delta
        m.applied()
        if firstRun != [true, false] || !deltaAfterTwo || !afterApply || row != [true, false, false]
            || deltaAfterThree || m.delta || m.count != 0 {
            failures.append("mismatches: \(firstRun) \(afterApply) \(row) delta \(m.delta) count \(m.count)")
        }
        if streamQuery(delta: true).map(\.name) != ["ansi", "delta"] || streamQuery(delta: false).map(\.name) != ["ansi"] {
            failures.append("stream query")
        }

        // Reading position: the anchor line is found after new output, a duplicate line is resolved
        // by its distance from the end, a gone line or a bottom position means the bottom.
        let old = ["a", "b", "c", "d", "e"]
        let at = anchor(old, top: 2, time: 1)
        if topLine(at, in: ["x"] + old + ["f"]) != 3 { failures.append("anchor found: \(String(describing: topLine(at, in: ["x"] + old + ["f"])))") }
        let rep = ["p", "q", "r", "p", "q", "r", "s"]
        let near = topLine(anchor(rep, top: 4, time: 1), in: rep + ["t"])
        let far = topLine(anchor(rep, top: 1, time: 1), in: rep + ["t"])
        if near != 4 || far != 1 { failures.append("anchor duplicate: \(String(describing: near)) \(String(describing: far))") }
        if topLine(at, in: ["z", "b", "c", "y"]) != nil { failures.append("anchor missing") }
        if topLine(Position(bottom: true), in: old) != nil { failures.append("anchor at bottom") }
        // A blank top line anchors on the first non-blank window below it (2 rows down here), so an
        // unrelated blank stretch never matches; only blank lines below = the bottom.
        let gap = ["x", "", "", "", "", "y", "z"]
        let gapAt = anchor(gap, top: 2, time: 1)
        let gapTop = topLine(gapAt, in: ["", "", "w"] + gap)
        let blankElsewhere = topLine(gapAt, in: ["", "", "", "", "q"])
        if gapAt.below != 2 || gapTop != 5 || blankElsewhere != nil || !anchor(["a", "", "", ""], top: 2, time: 1).bottom {
            failures.append("anchor blank: \(gapAt.below) \(String(describing: gapTop)) \(String(describing: blankElsewhere))")
        }
        var store: [String: Position] = [:]
        for i in 0...100 { store = storing(anchor(old, top: 0, time: Double(i)), at: "s|\(i)", in: store) }
        if store.count != 100 || store["s|0"] != nil || store["s|100"] == nil { failures.append("store prune: \(store.count)") }
        if let json = try? JSONEncoder().encode(at), String(decoding: json, as: UTF8.self).contains("\"c\"") {
            failures.append("position stores screen text")
        }

        // Assistive page scroll: offsets and "page p of n" (min 0, max 120, page 100 unless stated),
        // with the final partial page numbered n.
        func pg(_ offset: Double, _ down: Bool, max: Double = 120, by: Double = 100) -> String {
            page(offset: offset, by: by, min: 0, max: max, down: down).map { "\($0.offset) \($0.number) \($0.count)" } ?? "nil"
        }
        let pages = [pg(0, true), pg(100, true), pg(120, true), pg(120, false), pg(20, false), pg(0, false),
                     pg(100, true, max: 200), pg(0, true, max: 0), pg(0, true, by: 0)]
        let wantPages = ["100.0 2 3", "120.0 3 3", "nil", "20.0 1 3", "0.0 1 3", "nil", "200.0 3 3", "nil", "nil"]
        if pages != wantPages { failures.append("page: \(pages)") }
        // Bottom jump: a tall screen ends at the view's bottom edge (also under a bottom inset); a
        // short one stays at the top.
        let bottoms = [bottomOffset(content: 4800, view: 700, insetTop: 0, insetBottom: 0),
                       bottomOffset(content: 4800, view: 700, insetTop: 10, insetBottom: 34),
                       bottomOffset(content: 300, view: 700, insetTop: 10, insetBottom: 0)]
        if bottoms != [4100, 4134, -10] { failures.append("bottom offset: \(bottoms)") }

        // Reading: no record or a bottom record follows the bottom.
        for rec in [nil, Position(bottom: true)] {
            let r = Reading(record: rec)
            if r.goal != .bottom || !r.pinned { failures.append("reading record \(String(describing: rec)): \(r.target)") }
        }
        func with(_ p: Position, time: Double, fromEnd: Int? = nil) -> Position { var p = p; p.time = time; p.fromEnd = fromEnd ?? p.fromEnd; return p }
        // A saved line waits for a screen; the loading line resolves nothing.
        var r = Reading(record: at)
        if r.goal != .none { failures.append("reading pending goal: \(r.goal)") }
        r.screen(nil)
        if r.layout() != .none || r.target != .anchor(at, line: nil) { failures.append("reading loading: \(r.target)") }
        if r.position(firstVisible: 0, col: 0, lines: old, atBottom: false, time: 9) != with(at, time: 9) {
            failures.append("reading pending save")
        }
        // Found in the screen a layout pass applies; reading the goal again changes nothing.
        r.screen(["x"] + old + ["f"])
        let found = r.layout()
        let again = r.goal
        if found != .line(3, col: 0) || again != found || r.goal != found { failures.append("reading found: \(found) \(r.goal)") }
        if r.position(firstVisible: 3, col: 0, lines: ["x"] + old + ["f"], atBottom: false, time: 4) != with(at, time: 4, fromEnd: 4) {
            failures.append("reading landed save")
        }
        // Follow: new lines above move the line down.
        r.screen(["x", "y"] + old + ["f"])
        if r.layout() != .line(4, col: 0) { failures.append("reading follow: \(r.target)") }
        // A changed neighbour after landing: free (keep the live offset), never the bottom.
        let changed = ["x", "y", "a", "b", "c", "D", "e", "f"]
        r.screen(changed)
        if r.layout() != .none || r.target != .free { failures.append("reading neighbour changed: \(r.target)") }
        if r.position(firstVisible: 5, col: 2, lines: changed, atBottom: false, time: 2) != anchor(changed, top: 5, col: 2, time: 2) {
            failures.append("reading free save")
        }
        // Gone before landing: the bottom.
        var gone = Reading(record: at)
        gone.screen(["z", "b", "c", "y"])
        if gone.layout() != .bottom || !gone.pinned { failures.append("reading gone: \(gone.target)") }
        // Astra 1: two screens before the first usable layout. Resolving is not landing: the newest
        // displayed screen is resolved by the pass that applies it, never top / free, and the saved
        // record is kept until then.
        var two = Reading(record: at)
        two.screen(["x"] + old + ["f"])
        two.screen(["x", "y"] + old + ["f"])
        if two.position(firstVisible: 0, col: 0, lines: ["x", "y"] + old + ["f"], atBottom: true, time: 3) != with(at, time: 3) {
            failures.append("reading two screens: pending record overwritten")
        }
        if two.layout() != .line(4, col: 0) { failures.append("reading two screens: \(two.target)") }
        var twoChanged = Reading(record: at)
        twoChanged.screen(["x"] + old + ["f"])
        twoChanged.screen(changed)
        if twoChanged.layout() != .bottom || twoChanged.target == .free { failures.append("reading two screens changed: \(twoChanged.target)") }
        // Astra 2: content 2000, anchor at 1500. Viewport 300: shown at 1500, the anchor is saved.
        // Viewport 700: clamped to the bottom (1300), so the save is the bottom while the runtime
        // target stays the anchor; then new output, and a reopen shows the newest lines.
        let lines = ["x"] + old + ["f"]
        var clamp = Reading(record: at)
        clamp.screen(lines)
        _ = clamp.layout()
        for view in [300.0, 700.0] {
            let bottom = bottomOffset(content: 2000, view: view, insetTop: 0, insetBottom: 0)
            let y = Swift.min(1500, bottom)
            let saved = clamp.position(firstVisible: 3, col: 0, lines: lines, atBottom: y >= bottom - 24, time: 6)
            if view == 300, saved != with(at, time: 6, fromEnd: 4) { failures.append("reading clamp 300: \(saved)") }
            if view == 700 {
                if !saved.bottom || clamp.goal != .line(3, col: 0) { failures.append("reading clamp 700: \(saved) \(clamp.target)") }
                var reopen = Reading(record: saved)
                reopen.screen(lines + ["new"])
                if reopen.layout() != .bottom { failures.append("reading clamp reopen: \(reopen.target)") }
            }
        }
        // User moves and jumps.
        var mv = Reading(record: at)
        mv.screen(["x"] + old + ["f"])
        _ = mv.layout()
        mv.moved(atBottom: false)
        if mv.target != .free { failures.append("reading moved from anchor: \(mv.target)") }
        mv = Reading(record: at)
        mv.screen(["x"] + old + ["f"])
        _ = mv.layout()
        mv.moveBegan()
        let began = (mv.target, mv.goal)
        mv.moved(atBottom: false)
        let stayed = mv.target
        mv.moved(atBottom: true)
        let back = mv.target
        mv.moveBegan()
        mv.jump()
        if began.0 != .free || began.1 != .none || stayed != .free || back != .bottom || mv.target != .bottom {
            failures.append("reading moves: \(began) \(stayed) \(back) \(mv.target)")
        }
        // A free view at the bottom saves the bottom.
        mv.moved(atBottom: false)
        if !mv.position(firstVisible: 1, col: 0, lines: old, atBottom: true, time: 1).bottom { failures.append("reading free at bottom") }
        // col: kept for the top line itself, 0 when the hashed line is below a blank top line.
        let colAt = anchor(old, top: 2, col: 7, time: 1)
        if colAt.col != 7 || anchor(gap, top: 2, col: 5, time: 1).col != 0 {
            failures.append("anchor col: \(colAt.col) \(anchor(gap, top: 2, col: 5, time: 1).col)")
        }
        if let json = try? JSONEncoder().encode(colAt), (try? JSONDecoder().decode(Position.self, from: json)) != colAt {
            failures.append("position col round trip")
        }
        // Following keeps the true line when output appends a copy of its window below it, and the
        // save carries the refreshed distance from the end.
        let s0 = ["a", "p", "q", "r", "b", "c", "d"]
        let s1 = s0 + ["e", "f", "g", "h"]
        let s2 = s1 + ["p", "q", "r", "i", "j"]
        var dup = Reading(record: anchor(s0, top: 2, time: 1))
        var dupGoals: [Reading.Goal] = []
        for s in [s0, s1, s2] {
            dup.screen(s)
            dupGoals.append(dup.layout())
        }
        if dupGoals != [.line(2, col: 0), .line(2, col: 0), .line(2, col: 0)] { failures.append("reading duplicate follow: \(dupGoals)") }
        let dupSaved = dup.position(firstVisible: 2, col: 0, lines: s2, atBottom: false, time: 2)
        if dupSaved.fromEnd != 14 || topLine(dupSaved, in: s2) != 2 { failures.append("reading duplicate save: \(dupSaved.fromEnd)") }
        var colRead = Reading(record: colAt)
        colRead.screen(old)
        if colRead.layout() != .line(2, col: 7) { failures.append("reading col: \(colRead.goal)") }
        return failures
    }
}
