import Foundation

/// The live choice menu at the bottom of a session screen (Claude's trust, permission and
/// AskUserQuestion menus, codex approvals and selection lists, the omp Ask box), and the keys that
/// pick one option. Pure Foundation: CI builds it for macOS and runs `selfTest()` over real captures.
enum MenuLogic {
    struct Option: Equatable {
        /// "N." when the menu is numbered (Claude, codex); nil for unnumbered rows (trust, omp, Submit).
        let number: Int?
        let label: String
        /// The row the cursor is on (❯, ›, > or the omp chevron).
        let highlighted: Bool
        /// A multi-select row ("[ ]", "[✔]", "☐", "☒"): picking it toggles with Space.
        var checkbox = false
        var checked = false
        /// Index of the option's line in the lines given to `menu`.
        var row = 0
    }

    struct Menu: Equatable {
        var options: [Option]
        /// A question tab header ("←  ☐ A  ☒ B  ✔ Submit  →") is on screen: Left / Right switch tabs.
        var tabs = false
    }

    /// Lines looked at: the last 40 non-empty ones.
    static let window = 40
    /// The server accepts a repeat of 1...20 for one key.
    static let maxRepeat = 20

    /// Row markers: ❯ (Claude, omp), › (codex), > and U+F054 (the omp Ask chevron).
    private static let markers: Set<Character> = ["❯", "›", ">", "\u{F054}"]
    /// Leading glyphs dropped from a label: (glyph, checkbox, checked).
    private static let glyphs: [(String, Bool, Bool)] = [
        ("[ ]", true, false), ("[✔]", true, true), ("[x]", true, true), ("☐", true, false), ("☒", true, true),
        ("\u{F10C}", false, false), ("\u{F192}", false, false), ("\u{25CB}", false, false), ("\u{25CF}", false, false),
    ]

    /// Box drawing and block elements (U+2500...U+259F), "|" and spaces are border chrome.
    private static func isEdge(_ c: Character) -> Bool {
        if c == "|" || c.isWhitespace { return true }
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        return (0x2500...0x259F).contains(s.value)
    }

    /// One screen line, cut into what the menu rules need. Columns are Character offsets in the line.
    private struct Row {
        var blank = true
        /// Border chrome only (a rule, a box edge row).
        var rule = false
        /// The first non-space character of the raw line (the omp box edges "│" and "╰").
        var lead: Character?
        /// Starts with a marker followed by a space, at `markerColumn`.
        var marked = false
        var markerColumn = 0
        /// Where the row's content starts: after the edge, the marker and spaces.
        var column = 0
        var number: Int?
        /// Where the label starts: after "N. " and a checkbox or radio glyph.
        var labelColumn = 0
        var label = ""
        var checkbox = false
        var checked = false
        /// The line without its edges (for the footer and the tab header).
        var text = ""
    }

    private static func parse(_ raw: String) -> Row {
        let chars = Array(raw)
        var r = Row()
        r.lead = chars.first { !$0.isWhitespace }
        r.blank = r.lead == nil
        var start = 0, end = chars.count
        while start < end, isEdge(chars[start]) { start += 1 }
        while end > start, isEdge(chars[end - 1]) { end -= 1 }
        guard start < end else { r.rule = !r.blank; return r }
        r.text = String(chars[start..<end])
        var i = start
        if markers.contains(chars[i]), i + 1 < end, chars[i + 1].isWhitespace {
            r.marked = true
            r.markerColumn = i
            i += 1
            while i < end, chars[i].isWhitespace { i += 1 }
        }
        r.column = i
        var j = i, n = 0, digits = 0
        while j < end, digits < 3, chars[j].isASCII, let d = chars[j].wholeNumberValue {
            n = n * 10 + d
            digits += 1
            j += 1
        }
        if digits > 0, j + 1 < end, chars[j] == ".", chars[j + 1].isWhitespace {
            r.number = n
            i = j + 1
            while i < end, chars[i].isWhitespace { i += 1 }
        }
        for (glyph, box, on) in glyphs {
            let g = Array(glyph)
            guard i + g.count <= end, Array(chars[i..<(i + g.count)]) == g,
                  i + g.count == end || chars[i + g.count].isWhitespace else { continue }
            r.checkbox = box
            r.checked = on
            i += g.count
            while i < end, chars[i].isWhitespace { i += 1 }
            break
        }
        r.labelColumn = i
        // Codex pads the label to a column, then a description: keep the part before two spaces.
        let rest = String(chars[i..<end])
        r.label = (rest.components(separatedBy: "  ").first ?? rest).trimmingCharacters(in: .whitespaces)
        return r
    }

    /// Leading phrases of the Claude and codex key hint footers. Only the start of the footer is
    /// matched, over its rows joined with one space: a narrow pane wraps the footer at word
    /// boundaries (even "Press enter to confirm" below 24 columns), and a status line that merely
    /// contains the words (a codex thread title, an omp project name) never starts with them.
    private static let footers = ["Enter to confirm", "Enter to select", "Esc to cancel", "Press enter to confirm", "enter select"]

    /// The omp Ask box footer row: "│ 󰌑 select · n note · ↑/↓ move · 󱊷 cancel · Alt+H hide │".
    private static func isOmpFooter(_ r: Row) -> Bool {
        r.lead == "│" && r.text.contains("select ·") && r.text.contains("↑/↓ move") && r.text.contains("cancel")
    }

    /// Claude's AskUserQuestion tab header: "←  ☐ A  ☒ B  ✔ Submit  →".
    private static func isTabHeader(_ text: String) -> Bool {
        text.hasPrefix("←") && text.hasSuffix("→") && text.contains { "☐☒✔".contains($0) }
    }

    /// The live menu now on screen, or nil. Anchored on the menu's footer, in the last 40 non-empty
    /// lines:
    /// - Anchor: the first row of the bottom block (the non-blank rows that end at the last non-blank
    ///   row), when the block has at most 6 rows and its rows, joined with one space, start with a
    ///   Claude / codex footer (`footers`; 6 = the longest footer wrapped at the 20-column floor,
    ///   plus one). Every raw capture has a blank line above its footer. An input box (a draft, its
    ///   rule and status line) is one block whose first row is never a footer, even when a later
    ///   draft line starts with a footer phrase.
    ///   Or the omp Ask footer row directly above the box's "╰". Without one, Claude's question tab
    ///   header above a run that reaches the last 4 non-empty lines (the Submit tab).
    /// - The highlight is the lowest marker row (❯ › > or the omp chevron, then a space) of the
    ///   block directly above the anchor whose run is valid. The run's item column (the "N." digit,
    ///   the omp circle, or an unnumbered label) is the marker column + 2; a marker elsewhere is text.
    /// - Option rows start at the item column; numbers are optional but, when present, run 1...n.
    ///   A deeper line is a description, except, in a numbered checkbox menu, a line between the item
    ///   and label columns: Claude's "Submit" row. Rule-only lines are skipped; a blank line or a
    ///   shallower line ends the run, and nothing but blank and rule lines may sit below it.
    /// - Exactly one highlight and at least 2 options.
    static func menu(_ lines: [String]) -> Menu? {
        var lo = lines.count, seen = 0
        while lo > 0, seen < window {
            lo -= 1
            if lines[lo].contains(where: { !$0.isWhitespace }) { seen += 1 }
        }
        let rows = lines[lo...].map(parse)
        let filled = rows.indices.filter { !rows[$0].blank }
        guard !filled.isEmpty else { return nil }
        var anchor: Int?
        var bottom = filled.count - 1
        while bottom > 0, filled[bottom - 1] == filled[bottom] - 1 { bottom -= 1 }
        let footer = filled[bottom...].map { rows[$0].text }.joined(separator: " ")
        if filled.count - bottom <= 6, footers.contains(where: { footer.hasPrefix($0) }) { anchor = filled[bottom] }
        if anchor == nil, let b = filled.suffix(4).last(where: { rows[$0].lead == "╰" }),
           let f = filled.last(where: { $0 < b }), isOmpFooter(rows[f]) {
            anchor = f
        }
        let end = anchor ?? rows.count
        // The block directly above the anchor: up to the first blank line above its content.
        var top = end
        for k in stride(from: end - 1, through: 0, by: -1) {
            if !rows[k].blank { top = k } else if top < end { break }
        }
        for m in stride(from: end - 1, through: top, by: -1) where rows[m].marked {
            guard let found = run(rows, highlight: m, top: top, end: end, offset: lo) else { continue }
            if anchor != nil { return found.menu }
            return found.menu.tabs && found.last >= filled[max(0, filled.count - 4)] ? found.menu : nil
        }
        return nil
    }

    /// The run around the highlighted row `m`, inside rows top..<end; nil when it is not a menu.
    private static func run(_ rows: [Row], highlight m: Int, top: Int, end: Int, offset: Int) -> (menu: Menu, last: Int)? {
        let item = rows[m].markerColumn + 2
        func lit(_ r: Row) -> Bool { r.marked && r.markerColumn == item - 2 }
        var first = m, up = m - 1
        // Rows top...m hold no blank line: the block above the anchor is one non-blank run.
        while up >= top, rows[first].number != 1 {
            let r = rows[up]
            if !r.rule {
                if r.column < item { break }
                if lit(r) { return nil }
                first = up
            }
            up -= 1
        }
        // Below m only the rest of that run, then blank lines up to the anchor.
        var last = m
        for k in (m + 1)..<end {
            let r = rows[k]
            if r.blank || r.rule { continue }
            if r.column < item || lit(r) { return nil }
            last = k
        }
        var options: [Option] = []
        var numbered: Bool?
        var labelColumn = Int.max
        var boxes = false
        for k in first...last {
            let r = rows[k]
            if r.blank || r.rule { continue }
            let isRow: Bool
            if r.column == item {
                if numbered == nil { numbered = r.number != nil } else if numbered != (r.number != nil) { return nil }
                isRow = true
            } else {
                isRow = !options.isEmpty && numbered == true && boxes && r.column < labelColumn
            }
            guard isRow else {
                if k == m { return nil } // the marker sits on a description
                continue
            }
            options.append(Option(number: r.number, label: r.label, highlighted: k == m,
                                  checkbox: r.checkbox, checked: r.checked, row: offset + k))
            labelColumn = r.labelColumn
            boxes = r.checkbox
        }
        let numbers = options.compactMap(\.number)
        guard options.count >= 2, options.contains(where: { $0.highlighted }),
              numbers.enumerated().allSatisfy({ $0.element == $0.offset + 1 }) else { return nil }
        return (Menu(options: options, tabs: rows[..<first].contains { isTabHeader($0.text) }), last)
    }

    /// Claude's "Type something" row: the owner types the answer, so a pick only moves there.
    /// omp's "Other (type your own)" is not one: typed text is dropped there, and Enter opens its
    /// "Custom answer" editor, so that row gets the moves and Enter like any other.
    static func isFreeText(_ o: Option) -> Bool {
        o.label.lowercased().hasPrefix("type something")
    }

    /// The published screen is what the box shows: the same text line by line, trailing spaces and
    /// trailing blank lines ignored (a redraw leaves stale padding); or no menu on either
    /// side (the box is working, nothing to tap).
    static func sameScreen(_ shown: [String], _ shownMenu: Menu?, _ probe: [String], _ probeMenu: Menu?) -> Bool {
        if shownMenu == nil && probeMenu == nil { return true }
        func plain(_ lines: [String]) -> [Substring] {
            var out = lines.map { line -> Substring in
                var s = Substring(line)
                while let c = s.last, c.isWhitespace { s.removeLast() }
                return s
            }
            while out.last?.isEmpty == true { out.removeLast() }
            return out
        }
        return plain(shown) == plain(probe)
    }

    /// The menu's options, [] when there is no live menu.
    static func options(_ lines: [String]) -> [Option] { menu(lines)?.options ?? [] }

    /// The keys that move the highlight to `target` and act on it: Up or Down by the row distance
    /// (left out when already there), then Enter, or Space for a checkbox row (it toggles; it never
    /// submits). A free-text row (Claude's "Type something") gets the moves only. [] for invalid
    /// input (not exactly one highlight, the target not in the list, or more than 20 rows away: the
    /// server's repeat limit, and a capped move would act on the wrong row) or nothing to send.
    static func keys(toChoose target: Option, in opts: [Option]) -> [(key: String, `repeat`: Int)] {
        let lit = opts.indices.filter { opts[$0].highlighted }
        guard lit.count == 1, let t = opts.firstIndex(of: target) else { return [] }
        let d = t - lit[0]
        guard abs(d) <= maxRepeat else { return [] }
        var out: [(key: String, `repeat`: Int)] = []
        if d < 0 { out.append((key: "Up", repeat: -d)) }
        if d > 0 { out.append((key: "Down", repeat: d)) }
        if !isFreeText(target) { out.append((key: target.checkbox ? "Space" : "Enter", repeat: 1)) }
        return out
    }

    /// The number shown for an option: its own, or its position in a wholly unnumbered menu.
    static func shownNumber(_ o: Option, in opts: [Option]) -> Int? {
        if let n = o.number { return n }
        guard !opts.contains(where: { $0.number != nil }), let i = opts.firstIndex(of: o) else { return nil }
        return i + 1
    }

    /// VoiceOver label: "Chọn <n>: <label>", or "Chọn: <label>" for an unnumbered row in a numbered menu.
    static func spoken(_ o: Option, in opts: [Option]) -> String {
        shownNumber(o, in: opts).map { "Chọn \($0): \(o.label)" } ?? "Chọn: \(o.label)"
    }

    // MARK: - Self-test

    static func selfTest() -> [String] {
        var failures: [String] = []
        func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got != want { failures.append("\(name): got \(got), want \(want)") }
        }
        func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }
        func summary(_ text: String) -> String {
            guard let m = menu(lines(text)) else { return "none" }
            return m.options.map { o in
                (o.highlighted ? ">" : "") + (o.number.map { "\($0). " } ?? "")
                    + (o.checkbox ? (o.checked ? "[x] " : "[ ] ") : "") + o.label
            }.joined(separator: " | ") + (m.tabs ? " <>" : "")
        }
        func keyText(_ k: [(key: String, `repeat`: Int)]) -> String {
            k.map { "\($0.key)x\($0.repeat)" }.joined(separator: ",")
        }
        /// Keys for the option at `index` of the menu in `text`.
        func pick(_ text: String, _ index: Int) -> String {
            let o = options(lines(text))
            guard o.indices.contains(index) else { return "no option \(index)" }
            return keyText(keys(toChoose: o[index], in: o))
        }
        func spokenAt(_ text: String, _ index: Int) -> String {
            let o = options(lines(text))
            return o.indices.contains(index) ? spoken(o[index], in: o) : "no option \(index)"
        }

        // Real captures (tmux 100x40, scratch/facts-menu-captures.md), verbatim.
        let trust = #"""

────────────────────────────────────────────────────────────────────────────────────────────────────
 Accessing workspace:

 /tmp/zz-cap/claude

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a
 well-known open source project, or work from your team). If not, take a moment to review what's in
 this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
"""#
        let trustAfterEnter = #"""

────────────────────────────────────────────────────────────────────────────────────────────────────
 Accessing workspace:

 /tmp/zz-cap/claude

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a
 well-known open source project, or work from your team). If not, take a moment to review what's in
 this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

   No, exit
 ❯ Yes, I trust this folder

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude

  Get to finished work sooner with Opus 5.5. Switch anytime with /model.





























                                                                                ◐ medium · /effort
────────────────────────────────────────────────────────────────────────────────────────────────────
❯ Try "fix lint errors"
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
"""#
        let askSingle = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude

  Get to finished work sooner with Opus 5.5. Switch anytime with /model.

❯ Use your AskUserQuestion tool to ask me two questions at once: first a single-choice question     
  with 3 options that each have a short description; second a multi-select question with 3 options. 

● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Ưu tiên  ☐ Thông báo  ✔ Submit  →

Bạn muốn mình ưu tiên điều gì khi làm việc?

❯ 1. Tốc độ
     Làm nhanh, chấp nhận kiểm tra ít hơn.
  2. Chính xác
     Kiểm tra kỹ từng bước, chậm hơn một chút.
  3. Cân bằng
     Vừa đủ nhanh, vừa đủ kỹ.
  4. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""#
        // grep -v capture, blank line restored before the footer (raw layout: tab2Raw, askSingle).
        let multiTab2 = #"""
 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude
  Get to finished work sooner with Opus 5.5. Switch anytime with /model.
❯ Use your AskUserQuestion tool to ask me two questions at once: first a single-choice question     
  with 3 options that each have a short description; second a multi-select question with 3 options. 
● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Ưu tiên  ☐ Thông báo  ✔ Submit  →
Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?
❯ 1. [ ] Tiến độ
         Báo mỗi khi xong một bước.       
  2. [ ] Cảnh báo
         Báo khi gặp lỗi hoặc rủi ro.         
  3. [ ] Tóm tắt cuối
         Một bản tóm tắt khi xong việc.
  4. [ ] Type something
     Submit                                                                                         
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
                                                         
"""#
        // grep -v capture, blank line restored before the footer (raw layout: tab2Raw, askSingle).
        let multiDown = #"""
←  ☐ Ưu tiên  ☐ Thông báo  ✔ Submit  →
Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?
  1. [ ] Tiến độ
         Báo mỗi khi xong một bước.       
❯ 2. [ ] Cảnh báo
         Báo khi gặp lỗi hoặc rủi ro.         
  3. [ ] Tóm tắt cuối
         Một bản tóm tắt khi xong việc.
  4. [ ] Type something
     Submit                                                                                         
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
                                                         
"""#
        // grep -v capture, blank line restored before the footer (raw layout: tab2Raw, askSingle).
        let multiSpace = #"""
←  ☐ Ưu tiên  ☒ Thông báo  ✔ Submit  →
Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?
  1. [ ] Tiến độ
         Báo mỗi khi xong một bước.       
❯ 2. [✔] Cảnh báo
         Báo khi gặp lỗi hoặc rủi ro.         
  3. [ ] Tóm tắt cuối
         Một bản tóm tắt khi xong việc.
  4. [ ] Type something
     Submit                                                                                         
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
                                                         
"""#
        let submitTab = #"""
● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Ưu tiên  ☒ Thông báo  ✔ Submit  →
Review your answers
                
⚠ You have not answered all questions     
 ● Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?
   → Cảnh báo        
                                       
Ready to submit your answers?
                                                                                                    
❯ 1. Submit answers                                                                                 
  2. Cancel
"""#
        let tab2Raw = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude

  Get to finished work sooner with Opus 5.5. Switch anytime with /model.

❯ Use your AskUserQuestion tool to ask me two questions at once: first a single-choice question     
  with 3 options that each have a short description; second a multi-select question with 3 options. 

● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Ưu tiên  ☒ Thông báo  ✔ Submit  →                                                              

Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?

❯ 1. [ ] Tiến độ
         Báo mỗi khi xong một bước.       
  2. [✔] Cảnh báo
         Báo khi gặp lỗi hoặc rủi ro.                             
  3. [ ] Tóm tắt cuối
         Một bản tóm tắt khi xong việc.
  4. [ ] Type something      
     Submit                                                                                         
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this
"""#
        let typeSomething = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude

  Get to finished work sooner with Opus 5.5. Switch anytime with /model.

❯ Use your AskUserQuestion tool to ask me two questions at once: first a single-choice question     
  with 3 options that each have a short description; second a multi-select question with 3 options. 

● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Ưu tiên  ☒ Thông báo  ✔ Submit  →                                                              

Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?

  1. [ ] Tiến độ
         Báo mỗi khi xong một bước.       
  2. [✔] Cảnh báo
         Báo khi gặp lỗi hoặc rủi ro.                             
❯ 3. [ ] Tóm tắt cuối
         Một bản tóm tắt khi xong việc.
  4. [ ] Type something      
     Submit                                                                                         
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this
"""#
        let submitRow = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude

  Get to finished work sooner with Opus 5.5. Switch anytime with /model.

❯ Use your AskUserQuestion tool to ask me two questions at once: first a single-choice question     
  with 3 options that each have a short description; second a multi-select question with 3 options. 

● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Ưu tiên  ☒ Thông báo  ✔ Submit  →                                                              

Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc?

  1. [ ] Tiến độ
         Báo mỗi khi xong một bước.       
  2. [✔] Cảnh báo
         Báo khi gặp lỗi hoặc rủi ro.                             
  3. [ ] Tóm tắt cuối
         Một bản tóm tắt khi xong việc.
❯ 4. [ ] Type something      
     Submit                                                                                         
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this
"""#
        let idleAfterEsc = #"""
✻ Baked for 5s · done 10:39 AM            
                 
                                                                  
                     
                                       
                                                                                                    
                    
                                                                                ◐ medium · /effort
────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)                   
"""#
        let autoRan = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap/claude

  Get to finished work sooner with Opus 5.5. Switch anytime with /model.

❯ Use your AskUserQuestion tool to ask me two questions at once: first a single-choice question     
  with 3 options that each have a short description; second a multi-select question with 3 options. 

● Mình sẽ hỏi bạn hai câu cùng lúc như bạn yêu cầu.

● User declined to answer questions                                                                 
  ⎿  · Bạn muốn mình ưu tiên điều gì khi làm việc? (Tốc độ / Chính xác / Cân bằng)
     · Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc? (Tiến độ / Cảnh báo / Tóm tắt
     cuối)
                
✻ Baked for 5s · done 10:39 AM            
                 
❯ run: echo hi > x.txt                                                                              
                     
● Mình sẽ chạy lệnh ghi "hi" vào file x.txt.

  Ran 1 shell command                                                                               

● Mình đã chạy lệnh xong và không có lỗi. File /tmp/zz-cap/claude/x.txt đã có nội dung hi.

✻ Churned for 3s · done 10:39 AM






                                       
                                                                                                  
────────────────────────────────────────────────────────────────────────────────────────────────────
❯                     
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
"""#
        let btabCycle = #"""
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts                     
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ accept edits on (shift+tab to cycle)                
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ plan mode on (shift+tab to cycle)                    
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
"""#
        let bash = #"""

● User declined to answer questions                                     
  ⎿  · Bạn muốn mình ưu tiên điều gì khi làm việc? (Tốc độ / Chính xác / Cân bằng)
     · Bạn muốn nhận những loại thông báo nào trong lúc mình làm việc? (Tiến độ / Cảnh báo / Tóm tắt
     cuối)                                                                                          
                                                                        
✻ Baked for 5s · done 10:39 AM                                                                      

❯ run: echo hi > x.txt                                                                              

● Mình sẽ chạy lệnh ghi "hi" vào file x.txt.                                                        
                                   
  Ran 1 shell command 

● Mình đã chạy lệnh xong và không có lỗi. File /tmp/zz-cap/claude/x.txt đã có nội dung hi.          

✻ Churned for 3s · done 10:39 AM

❯ run: echo hi > x.txt                                                                              
                      
● Mình chạy lại lệnh này. File cũ sẽ bị ghi đè, nhưng nội dung vẫn là "hi" như trước nên không mất
  gì.                                                                                     
                      
● Ghi lại chữ "hi" vào file x.txt                                                                   
  ⎿  $ echo hi > x.txt

────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command                                                                                     
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below                  
 Ghi lại chữ "hi" vào file x.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 echo hi > x.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?                                                                        
 ❯ 1. Yes                              
   2. Yes, and always allow access to /tmp/zz-cap/claude from this project                        
   3. Yes, and switch to auto mode · auto mode handles these prompts for you                        
   4. No              

 Esc to cancel · Tab to amend
"""#
        let draftSayAB = #"""
  Ran 1 shell command 
  ⎿  Interrupted · What should Claude do instead?
✻ Worked for 5s · done 10:40 AM                                                                 
                                                                             ctrl+g to edit in Vim
────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 1. say A                                                                                          
  2. say B            
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on                                       
"""#
        let replySayAB = #"""
                                                                                                    
  Ran 1 shell command                                                                               
● Mình đã chạy lệnh xong và không có lỗi. File /tmp/zz-cap/claude/x.txt đã có nội dung hi.
✻ Churned for 3s · done 10:39 AM
❯ run: echo hi > x.txt                                                                              
● Mình chạy lại lệnh này. File cũ sẽ bị ghi đè, nhưng nội dung vẫn là "hi" như trước nên không mất
  gì.
                      
  Ran 1 shell command                                                                             
  ⎿  Interrupted · What should Claude do instead?
✻ Worked for 5s · done 10:40 AM                                                                     
❯ 1. say A                                                                                          
  2. say B                                                                                          
● A
                                                                                                    
  B
✻ Cooked for 0s · done 10:41 AM                                                                   
                                                                                                    
────────────────────────────────────────────────────────────────────────────────────────────────────
❯                     
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts
"""#
        let transcriptRaw = #"""

● Mình chạy lại lệnh này. File cũ sẽ bị ghi đè, nhưng nội dung vẫn là "hi" như trước nên không mất
  gì.
                      
  Ran 1 shell command                                                                             
  ⎿  Interrupted · What should Claude do instead?

✻ Worked for 5s · done 10:40 AM                                                                     

❯ 1. say A                                                                                          
  2. say B                                                                                          

● A
                                                                                                    
  B

✻ Cooked for 0s · done 10:41 AM                                                                   
                                                                                                    
────────────────────────────────────────────────────────────────────────────────────────────────────
❯                     
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts                     
"""#
        let draftFoo = #"""

● A

  B                                                                                                 
   
✻ Cooked for 0s · done 10:41 AM
                                                                             ctrl+g to edit in Vim
────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 1. foo                                                                                            
  2. bar              
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on                                       
"""#
        let afterCU = #"""
   
✻ Cooked for 0s · done 10:41 AM
                                                                      Ctrl+Y to paste deleted text
────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 1. foo                                                                                            
                      
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on                                       
                                                                      Ctrl+Y to paste deleted text  
────────────────────────────────────────────────────────────────────────────────────────────────────
❯                     
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts
"""#
        let codexStart = #"""
 
  >_ OpenAI Codex (v0.166.0)
     /tmp/zz-cap/codex
 
  To get started, describe a task or try one of these commands:
 
  /init - create an AGENTS.md file with instructions for Codex
  /status - show current session configuration
  /permissions - choose what Codex is allowed to do
  /model - choose what model and reasoning effort to use
  /review - review any changes and find issues
                                                   
                                                            
                                                              
                                                               
                                                                
                                                                
                                                                 
                                                                  
                                                                  
                                                                   
                                                                  
                                                                  
                                                                 
                                                               
                                                            
                                                           
                                                         
 
 
 
 
 
 
 
 
› Ask Codex to do anything
 
  GPT-6.1-Sol default · /tmp/zz-cap/codex
  ? for shortcuts                                                          ⚠ 1 warning · f2 to view
"""#
        let codexSandbox = #"""
 
  >_ OpenAI Codex (v0.166.0)
     /tmp/zz-cap/codex
 
  To get started, describe a task or try one of these commands:
 
  /init - create an AGENTS.md file with instructions for Codex
  /status - show current session configuration
  /permissions - choose what Codex is allowed to do
  /model - choose what model and reasoning effort to use
  /review - review any changes and find issues
                                                   
                                                            
› run: touch x                                                
                                                               
                                                                
• I’ll run touch x in the workspace.                            
                                                                 
• touch x failed because the sandbox could not initialize: bwrap: loopback: Failed RTM_NEWADDR:
  Operation not permitted.                                        
                                                                   
  Worked for 5s • 10:43                                                                             
                                                                  
                                                                 
                                                               
                                                            
                                                           
                                                         
 
 
 
 
 
                                 
 
              
› Ask Codex to do anything
 
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
  ? for shortcuts                                                          ⚠ 1 warning · f2 to view
"""#
        let codexReject = #"""
 
  >_ OpenAI Codex (v0.166.0)
     /tmp/zz-cap/codex
 
  To get started, describe a task or try one of these commands:
 
  /init - create an AGENTS.md file with instructions for Codex
  /status - show current session configuration
  /permissions - choose what Codex is allowed to do
  /model - choose what model and reasoning effort to use
  /review - review any changes and find issues
                                                   
                                                            
› run: touch x                                                
                                                               
                                                                
• I’ll run touch x in the workspace.                            
                                                                 
• touch x failed because the sandbox could not initialize: bwrap: loopback: Failed RTM_NEWADDR:
  Operation not permitted.                                        
                                                                   
  Worked for 5s • 10:43                                                                             
                                                                  
                                                                 
› The sandbox failed. Retry touch x requesting escalated permissions outside the sandbox so I can
  approve it.                                               
                                                           
                                                         
• I can’t request escalated execution because this session’s approval policy automatically rejects
  sandbox approval requests. touch x remains unexecuted; you can run it directly in your terminal.
 
  Worked for 4s • 10:44                                                                             
 
                                 
 
                                                                                                 
› Ask Codex to do anything
 
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
  ? for shortcuts                                                          ⚠ 1 warning · f2 to view
"""#
        let codexPermissions = #"""
                                                                                               
› The sandbox failed. Retry touch x requesting escalated permissions outside the sandbox so I can
  approve it.                                                      
                                                                                                    
                                                                  
• I can’t request escalated execution because this session’s approval policy automatically rejects
  sandbox approval requests. touch x remains unexecuted; you can run it directly in your terminal.
                                                            
  Worked for 4s • 10:44                                                                             
                                                         
                                                                                                  
  Update Model Permissions                                                                        
 
                                                                                                    
› 1. Ask for approval  Read and edit workspace files and run commands, with approval required for   
                       internet access or edits outside the workspace                               
  2. Approve for me    Only ask for actions detected as potentially unsafe                          
  3. Full Access       Use with caution: Codex can edit files outside this workspace and access the
                       internet without approval
  4. Read Only         Read workspace files, with approval required for edits or internet access
                                                         
  enter select · esc back                                                                           
"""#
        let codexModel = #"""
  approve it.                                                                                  
                                                                                                 
                                                                   
• I can’t request escalated execution because this session’s approval policy automatically rejects  
  sandbox approval requests. touch x remains unexecuted; you can run it directly in your terminal.
                                                                                                  
  Worked for 4s • 10:44                                                                             
                                                            
                                                                                                    
  Select Model and Effort                                
                                                                                                  
                                                                                                  
› 1. GPT-6.1-Sol (current)  Latest workhorse model for coding and everyday work.                    
  2. GPT-6-Astra            Frontier intelligence for the most demanding work.                      
  3. GPT-6.1 Terra          GPT-6.1 Terra Codex model.                                              
  4. GPT-6-Sol              Previous generation workhorse model.                                    
  5. GPT-6-Luna             Fast and affordable model for easier tasks.                             
  6. GPT-5.6-Sol            Older generation workhorse model.                                      
  7. GPT-5.6-Terra          Older balanced model for straightforward work.
  8. GPT-5.6-Luna           Older fast and efficient model.                                     
                                                         
  enter select · esc back
"""#
        let codexIdle = #"""
  >_ OpenAI Codex (v0.166.0)
     /tmp/zz-cap/codex
  To get started, describe a task or try one of these commands:
  /init - create an AGENTS.md file with instructions for Codex
  /status - show current session configuration
  /permissions - choose what Codex is allowed to do
  /model - choose what model and reasoning effort to use
  /review - review any changes and find issues
› Ask Codex to do anything
  GPT-6.1-Sol default · /tmp/zz-cap/codex
  ? for shortcuts                                                          ⚠ 1 warning · f2 to view
"""#
        let codexApproval = #"""
 
  >_ OpenAI Codex (v0.166.0)
     /tmp/zz-cap/codex
 
  To get started, describe a task or try one of these commands:
 
  /init - create an AGENTS.md file with instructions for Codex
  /status - show current session configuration
  /permissions - choose what Codex is allowed to do
  /model - choose what model and reasoning effort to use
  /review - review any changes and find issues
                                                   
                                                            
› run: touch x                                                
                                                               
                                                                
• I’ll run touch x in the workspace.                            
                                                                 
• Running touch x                                                 
                                                                  
                                                                   
                                                                  
                                                                  
                                                                 
                                                               
                                                            
  Would you like to run the following command?             
                                                         
  Environment: local
 
  Reason: May I run touch x outside the sandbox? The sandbox failed to start.
 
  $ touch x
                                 
 
› 1. Yes, proceed (y)                                                                               
  2. Yes, and don't ask again for commands that start with `touch x` (p)
  3. No, and tell Codex what to do differently (esc)
                                                         
  Press enter to confirm or esc to cancel
"""#
        let codexApprovalDown = #"""
  Reason: May I run touch x outside the sandbox? The sandbox failed to start.
 
  $ touch x
                                 
 
  1. Yes, proceed (y)                                                                               
› 2. Yes, and don't ask again for commands that start with `touch x` (p)                            
  3. No, and tell Codex what to do differently (esc)
                                                         
  Press enter to confirm or esc to cancel                                                           
"""#
        let codexAfterEsc = #"""
  /permissions - choose what Codex is allowed to do
  /model - choose what model and reasoning effort to use
  /review - review any changes and find issues
› run: touch x                                                
• I’ll run touch x in the workspace.                            
✗ You canceled the request to run touch x                         
• Exited (status 1) touch x                                        
  └ (no output)                                                   
■ Conversation interrupted - use /feedback if something went wrong
› Ask Codex to do anything                                                                          
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
  ? for shortcuts                                                          ⚠ 1 warning · f2 to view
"""#
        let codexDraftSay = #"""
 
                                 
                                                          
 
› 1. say A                                                                                          
  2. say B                                                                                          
                                                    
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
                                                                           ⚠ 1 warning · f2 to view 
"""#
        let codexTranscriptSay = #"""
                                                               
                                                                
• I’ll run touch x in the workspace.                            
                                                                 
✗ You canceled the request to run touch x                         
                                                                  
• Exited (status 1) touch x                                        
  └ (no output)                                                   
                                                                  
■ Conversation interrupted - use /feedback if something went wrong
                                                               
                                                            
› 1. say A                                                 
  2. say B                                               
                    
   
• A                                                                          
  B
                                 
  Worked for 1s • 10:47                                                                             
 
                                                                                                    
› Ask Codex to do anything                                                                          
                                                    
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
  ? for shortcuts                                                          ⚠ 1 warning · f2 to view
"""#
        let codexDraftFoo = #"""
   
  Worked for 1s • 10:47                                                                             
                                                                                                    
 
› 1. foo                                                                                            
  2. bar                                                                                            
                                                    
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
                                                                           ⚠ 1 warning · f2 to view 
"""#
        let codexAfterCU = #"""
  Worked for 1s • 10:47                                                                             
                                                                                                    
 
› 1. foo                                                                                            
                                                                                                    
                                                    
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
                                                                           ⚠ 1 warning · f2 to view 
"""#
        let codexAfterEsc2 = #"""
  Worked for 1s • 10:47                                                                             
                                                                                                    
 
› 1. foo                                                                                            
                                                                                                    
                                                    
  GPT-6.1-Sol default · /tmp/zz-cap/codex · Create x file
                                                                           ⚠ 1 warning · f2 to view
"""#
        let ompAsk = #"""

                                  ████████████    
                                     ██  ██       ▄▀▀▄ █▀▄▀▄ █▀▀▄
                                     ██  ██       ▀▄▄▀ █ █ █ █▄▄▀
                                     ▒▒  ██                  █
                                         ██       v18.16.0

              Tip: Type `#` anywhere in your prompt for quick actions — copy the line
                             or the whole prompt, undo, jump the cursor

                                                                                                    
 Use your ask tool to ask me one question with 3 options.                                           
                                                                                                    

 Mình sẽ hỏi bạn một câu với 3 lựa chọn.          

 2026-11-04 10:48:40   13K   402   22K   1.4s   63.3/s                                         

  󱊷 Hỏi một câu 3 lựa chọn                                                               67.6 tok/s

╭─ Ask ────────────────────────────────────────────────────────────────────────────────────────────╮
│ Bạn muốn mình làm gì tiếp theo?                                                                  │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│   Xem trạng thái repo (Recommended)                                                            │
│       Kiểm tra nhánh hiện tại, so với origin/main và các thay đổi chưa commit.                   │
│    Bắt đầu task mới                                                                             │
│       Bạn mô tả task, mình lập kế hoạch và chạy pipeline.                                        │
│    Dọn dẹp thư mục tạm                                                                          │
│       Rà soát và xoá file tạm, log, bản nháp không còn cần.                                      │
│    Other (type your own)                                                                        │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 󰌑 select · n note · ↑/↓ move · 󱊷 cancel · Alt+H hide                                             │
╰──────────────────────────────────────────────────────────────────────────────────────────────────╯
 󰪣 Opus 5.5 ·  zz-cap/omp
"""#
        let ompAfterEsc = #"""
                                     ▒▒  ██                  █
                                         ██       v18.16.0
              Tip: Type `#` anywhere in your prompt for quick actions — copy the line
                             or the whole prompt, undo, jump the cursor
 Use your ask tool to ask me one question with 3 options.                                           
 Mình sẽ hỏi bạn một câu với 3 lựa chọn.          
 2026-11-04 10:48:40   13K   402   22K   1.4s   63.3/s                                         
  F5 to retry                                                                                       
─ 󰋗 ASK: Ask one question with opti… ·  7d 1% (6d 23h) ·  4 ·  402 ·  22K ·  3.5%/1M 󰁨 · 󰙺 0.…─
❯                        
────────────────────────────────────────────────────────────────────────────────────────────────────
 󰪣 Opus 5.5 ·  zz-cap/omp
"""#
        let omp3b = #"""
 Mình sẽ hỏi bạn một câu với 3 lựa chọn.          

 2026-11-04 10:48:40   13K   402   22K   1.4s   63.3/s                                         

                                                                                                    
 run: touch x                                                                                       
                                                                                                    

 2026-11-04 10:49:52   701   75   35K   1.4s   37.9/s                                          

 Mình đã chạy lệnh và tạo được file x trong /tmp/zz-cap/omp.                                        

 2026-11-04 10:49:54   88   41   36K   2.0s   20.0/s                                           

                                                                                         50.0 tok/s

─ 󰋗 ASK: Ask one question with opt… ·  7d 1% (6d 23h) ·  10 ·  518 ·  93K ·  3.6%/1M 󰁨 · 󰙺 0.…─
❯                        
────────────────────────────────────────────────────────────────────────────────────────────────────
 󰪣 Opus 5.5 ·  zz-cap/omp 






x
"""#
        let ompDraftSEnter = #"""
                                                                                         50.0 tok/s

─ 󰋗 ASK: Ask one question with opt… ·  7d 1% (6d 23h) ·  10 ·  518 ·  93K ·  3.6%/1M 󰁨 · 󰙺 0.…─
❯ 1. fooS-Enter2. bare   
────────────────────────────────────────────────────────────────────────────────────────────────────
 󰪣 Opus 5.5 ·  zz-cap/omp
"""#
        let ompDraftAltEnter = #"""
                                                                                         50.0 tok/s

─ 󰋗 ASK: Ask one question with opt… ·  7d 1% (6d 23h) ·  10 ·  518 ·  93K ·  3.6%/1M 󰁨 · 󰙺 0.…─
❯ 1. foo                 
  2. bare                                                                                           
────────────────────────────────────────────────────────────────────────────────────────────────────
 󰪣 Opus 5.5 ·  zz-cap/omp
"""#
        let ompIdle = #"""
❯                        
────────────────────────────────────────────────────────────────────────────────────────────────────
 󰪣 Opus 5.5 ·  zz-cap/omp 
"""#
        let ompTranscript = #"""
 2026-11-04 10:48:40   13K   402   22K   1.4s   63.3/s                                         

                                                                                                    
 run: touch x                                                                                       
                                                                                                    

 2026-11-04 10:49:52   701   75   35K   1.4s   37.9/s                                          

 Mình đã chạy lệnh và tạo được file x trong /tmp/zz-cap/omp.                                        

 2026-11-04 10:49:54   88   41   36K   2.0s   20.0/s                                           

                                                                                                    
 1. say A                                                                                           
 2. say B                                                                                           
                                                                                                    

 1. A                    
 2. B                    

 2026-11-04 10:51:46   56   9   36K   1.1s   6.2/s                                             

                                                                                         43.2 tok/s

─ 󰋗 ASK: Ask one question with op… ·  7d 1% (6d 23h) ·  14 ·  527 ·  129K ·  3.6%/1M 󰁨 · 󰙺 0.…─
❯                        
────────────────────────────────────────────────────────────────────────────────────────────────────
 󰪣 Opus 5.5 ·  zz-cap/omp
"""#
        let ompSlash = #"""
  model         Model: anthropic/claude-opus-5-5                                                 █
   modelpreset   Presets: none saved                                                              █
  󰓡 switch        Model: anthropic/claude-opus-5-5                                                 █
   prewalk       Arm, restart, or cancel a one-shot model handoff                                 █
   advisor       Advisor: off                                                                     █
   agents        Open the agents hub (per-agent model, prewalk, and advisor)                      █
   plan          Plan: off                                                                        │
   plan-review   Plan review: plan mode inactive                                                  │
  󰥛 vibe          Vibe: off                                                                        │
   loop          Loop: off                                                                        │
"""#
        let ompModels = #"""
╭─ Models ───────────────────┬─────────────────────────────────────────────────────────────────────╮
│    Roles            14/25 │  All available models                                               │
│   All models          64 │  Kind:  all   chat  tiny  image  tts  stt  search  judge … │
│ ────────────────────────── │   >                                                                │
│    anthropic           19 │                                                                     │
│    local               14 │   anthropic/claude-opus-5-5                         1m      $4/20█ │
│    openai-codex         9 │   anthropic/claude-haiku-5-5                      100k   $0.1/0.5█ │
│    web                 22 │   anthropic/claude-sonnet-5-5                       1m      $2/10█ │
│ ────────────────────────── │   openai-codex/gpt-image-2                         10k      $5/30█ │
│    abliteration           │   web/parallel                                                free█ │
│    aiand                  │   local/kokoro                                                free█ │
│    aimlapi                │   local/parakeet-tdt-0.6b-v3                                  free█ │
│    alibaba-coding-plan    │   anthropic/claude-fable-5-1                        1m     $10/50█ │
│    alibaba-token-plan     │   ──────────────────────────────────────────────────────────────  █ │
│    amazon-bedrock         │   anthropic/claude-mythos-5-1                       1m     $10/50█ │
│    azure                  │   anthropic/claude-fable-5                          1m     $10/50█ │
│    baseten                │   anthropic/claude-mythos-5                         1m     $10/50█ │
│    bedrock-mantle         │   anthropic/claude-opus-5                           1m      $5/25│ │
│    cerebras               │   anthropic/claude-sonnet-5                         1m      $2/10│ │
│    charm-hyper            │   anthropic/claude-opus-4-8                         1m      $5/25│ │
│    cline-pass             │   anthropic/claude-opus-4-7                         1m      $5/25│ │
│    cloudflare-ai-gateway  │   anthropic/claude-opus-4-6                         1m      $5/25│ │
│    cloudflare-workers-ai  │   anthropic/claude-sonnet-4-6                       1m      $3/15│ │
│    commandcode            │   anthropic/claude-opus-4-5-20251101              200k      $5/25│ │
│    coralbricks            │   anthropic/claude-haiku-4-5-20251001             200k       $1/5│ │
│    coreweave              │   anthropic/claude-sonnet-4-5-20250929            200k      $3/15│ │
│    cursor                 │   anthropic/claude-haiku-4-5                      200k       $1/5│ │
│    deepinfra              │   anthropic/claude-opus-4-5                       200k      $5/25│ │
│    deepseek               │   anthropic/claude-sonnet-4-5                     200k      $3/15│ │
│    devin                  │   local/lfm2.5-350m                                           free│ │
│    factory-droid          │   local/lfm2.5-230m                                           free│ │
│    firepass               │   local/falcon-h1-90m                                         free│ │
│    fireworks              │   local/gemma-3-1b                                            free│ │
│    github-copilot         │   local/qwen3-1.7b                                            free│ │
│    gitlab-duo             │                                                                     │
│    gitlab-duo-agent       │   Claude Opus 5.5 · 1m ctx · 128k out · $4/20 per M · reasoning · … │
│    gmi-cloud              │    default 󰪣 ·  plan 󰪣 ·  frontend 󰪡 ·  review 󰪣 ·  worker 󰪣 … │
├────────────────────────────┴─────────────────────────────────────────────────────────────────────┤
│ 󰌑/→ models · ↑/↓ providers · type to search · Alt+←/Alt+→ kind · 󱊷 close                         │
╰──────────────────────────────────────────────────────────────────────────────────────────────────╯
"""#
        let ompSettings = #"""
│   Display            │   Symbol Preset               nerd                                      █ │
│   Images             │   Color-Blind Mode            false                                     █ │
│                      │   Composer                                                              █ │
│                      │   Composer Shape              claude                                    █ │
│                      │   Generation Rate             true                                      █ │
│                      │   Status Line                                                           █ │
│                      │   Status Line Preset          custom                                    █ │
│                      │   Status Line Separator       powerline-thin                            █ │
│                      │   Context-Reactive Line       embedded                                  █ │
│                      │   Session Accent              true                                      █ │
│                      │   Transparent Status Line     false                                     █ │
│                      │   Compact Thinking Level      true                                      │ │
│                      │   Show Hook Status            true                                      │ │
│                      │   Display                                                               │ │
│                      │   Resize Scrollback           rebuild                                   │ │
│                      │   Complete Scrollback         false                                     │ │
│                      │   Native Terminal Progress    false                                     │ │
│                      │   Program Status (OSC 7501)   true                                      │ │
│                      │   Large Headings (Kitty)      false                                     │ │
│                      │   Render Mermaid Diagrams     true                                      │ │
│                      │   Render SVG Figures          true                                      │ │
│                      │   Auto-Graph Tables           auto                                      │ │
│                      │   Agent Reactions             true                                      │ │
│                      │   Codex Reset Fireworks       true                                      │ │
│                                                                                                  │
│   Theme used when the terminal has a dark background                                             │
│                                                                                                  │
│                                                                                                  │
│                                                                                                  │
│ Preview:                                                                                         │
│ ─ 󰋗 ASK: Ask one question with op… ·  7d 1% (6d 23h) ·  18 ·  897 ·  165K ·  3.6%/1M 󰁨 · 󰙺… │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 󰌑/󱁐 to change · 󰌒 to jump sections · ←/→ to switch tabs · Type to search · 󱊷 to close            │
╰──────────────────────────────────────────────────────────────────────────────────────────────────╯
"""#

        // Phone width (tmux 48 columns): facts-menu-captures-narrow.md.
        let narrowAsk = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap2/claude

  Get to finished work sooner with Opus 5.5.
  Switch anytime with /model.

❯ Call the AskUserQuestion tool once with       
  exactly two questions. Question 1 (header     
  Color, single choice, 3 options each with a   
  description sentence of about 12 words):      
  which color do you like. Question 2 (header   
  Extras, multiSelect true, 3 options each with 
  a short description): which extras do you     
  want. Do nothing else.                        

● Mình sẽ hỏi bạn hai câu về màu sắc và các tùy
  chọn thêm.
────────────────────────────────────────────────
←  ☐ Color  ☐ Extras  ✔ Submit  →

Bạn thích màu nào nhất?

❯ 1. Xanh dương
     Màu của bầu trời và biển cả, mang lại cảm 
     giác bình yên, tin cậy.
  2. Xanh lá
     Màu của cây cối và thiên nhiên, gợi cảm 
     giác tươi mới, cân bằng.
  3. Đỏ
     Màu nổi bật và mạnh mẽ, thể hiện năng 
     lượng, nhiệt huyết và đam mê.
  4. Type something.
────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · 
Esc to cancel                                 


                                           
                                             
                                          

                                              



                                              
"""#
        let narrowMulti = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap2/claude

  Get to finished work sooner with Opus 5.5.
  Switch anytime with /model.

❯ Call the AskUserQuestion tool once with       
  exactly two questions. Question 1 (header     
  Color, single choice, 3 options each with a   
  description sentence of about 12 words):      
  which color do you like. Question 2 (header   
  Extras, multiSelect true, 3 options each with 
  a short description): which extras do you     
  want. Do nothing else.                        

● Mình sẽ hỏi bạn hai câu về màu sắc và các tùy
  chọn thêm.
────────────────────────────────────────────────
←  ☐ Color  ☐ Extras  ✔ Submit  →

Bạn muốn thêm những tùy chọn nào?

❯ 1. [ ] Chế độ tối
         Giao diện nền tối, dịu mắt hơn.       
  2. [ ] Hiệu ứng động      
         Thêm chuyển động nhẹ khi thao tác.
  3. [ ] Âm thanh                            
         Phát âm thanh khi bấm nút.
  4. [ ] Type something
     Submit                                
────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · 
Esc to cancel




                                           
                                             
                                          

                                              



                                              
"""#
        let narrowOnType = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap2/claude

  Get to finished work sooner with Opus 5.5.
  Switch anytime with /model.

❯ Call the AskUserQuestion tool once with       
  exactly two questions. Question 1 (header     
  Color, single choice, 3 options each with a   
  description sentence of about 12 words):      
  which color do you like. Question 2 (header   
  Extras, multiSelect true, 3 options each with 
  a short description): which extras do you     
  want. Do nothing else.                        

● Mình sẽ hỏi bạn hai câu về màu sắc và các tùy
  chọn thêm.
────────────────────────────────────────────────
←  ☐ Color  ☐ Extras  ✔ Submit  →

Bạn muốn thêm những tùy chọn nào?

  1. [ ] Chế độ tối
         Giao diện nền tối, dịu mắt hơn.       
  2. [ ] Hiệu ứng động      
         Thêm chuyển động nhẹ khi thao tác.
  3. [ ] Âm thanh                            
         Phát âm thanh khi bấm nút.
❯ 4. [ ] Type something
     Submit                                
────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · 
ctrl+g to edit in Vim · Esc to cancel




                                           
                                             
                                          

                                              



                                              
"""#
        let narrowOnSubmit = #"""

 ▐▛███▛█   Claude Code v2.1.317
▝▜██████▀  Opus 5.5 · Claude Team
 ▝▝   ▝▝   /tmp/zz-cap2/claude

  Get to finished work sooner with Opus 5.5.
  Switch anytime with /model.

❯ Call the AskUserQuestion tool once with       
  exactly two questions. Question 1 (header     
  Color, single choice, 3 options each with a   
  description sentence of about 12 words):      
  which color do you like. Question 2 (header   
  Extras, multiSelect true, 3 options each with 
  a short description): which extras do you     
  want. Do nothing else.                        

● Mình sẽ hỏi bạn hai câu về màu sắc và các tùy
  chọn thêm.
────────────────────────────────────────────────
←  ☐ Color  ☐ Extras  ✔ Submit  →

Bạn muốn thêm những tùy chọn nào?

  1. [ ] Chế độ tối
         Giao diện nền tối, dịu mắt hơn.       
  2. [ ] Hiệu ứng động      
         Thêm chuyển động nhẹ khi thao tác.
  3. [ ] Âm thanh                            
         Phát âm thanh khi bấm nút.
  4. [ ] Type something
❯    Submit                                
────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · 
ctrl+g to edit in Vim · Esc to cancel




                                           
                                             
                                          

                                              



                                              
"""#
        let narrowBash = #"""
  Color, single choice, 3 options each with a   
  description sentence of about 12 words):      
  which color do you like. Question 2 (header   
  Extras, multiSelect true, 3 options each with 
  a short description): which extras do you     
  want. Do nothing else.                        
                             
● Mình sẽ hỏi bạn hai câu về màu sắc và các tùy
  chọn thêm.                                    

● User declined to answer questions             
  ⎿  · Bạn thích màu nào nhất? (Xanh dương /    
     Xanh lá / Đỏ)                              
     · Bạn muốn thêm những tùy chọn nào? (Chế độ
     tối / Hiệu ứng động / Âm thanh)            

✻ Sautéed for 6s · done 11:38 AM

❯ Run this exact Bash command and nothing else: 
  touch /tmp/zz-cap2/claude/a_rather_long_file  
  _name_for_wrapping_test_one.txt               
  /tmp/zz-cap2/claude/another_long_file_name_fo 
  r_wrapping_test_two.txt                       
                                                
● Tạo hai tệp rỗng để thử           
  ⎿  $ touch /tmp/zz-cap2/claude/a_rather_long_f
     ile_name_for_wrapping_test_one.txt 
     /tmp/zz-cap2/claude/another_long_file_name_
     for_wrapping_test_two.txt                  

────────────────────────────────────────────────
 Bash command                                   
 Tip: auto mode handles these prompts for you — 
 choose "switch to auto mode" below
 Tạo hai tệp rỗng để thử  
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 │ touch /tmp/zz-cap2/claude/a_rather_long_file
 │ _name_for_wrapping_test_one.txt
 │ /tmp/zz-cap2/claude/another_long_file_name_f
 │ or_wrapping_test_two.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?                   
 ❯ 1. Yes                                       
   2. Yes, and always allow access to          
      /tmp/zz-cap2/claude from this project   
   3. Yes, and switch to auto mode · auto mode 
      handles these prompts for you             
   4. No                  

 Esc to cancel · Tab to amend                 
"""#
        let narrowCodex = #"""
 
  >_ OpenAI Codex (v0.166.0)
     /tmp/zz-cap2/codex
 
  To get started, describe a task or try one of
these commands:
 
  /init - create an AGENTS.md file with
instructions for Codex
  /status - show current session configuration
  /permissions - choose what Codex is allowed to
do
  /model - choose what model and reasoning
effort to use
  /review - review any changes and find issues
 
 
› run: touch x
                        
                                
• I’ll run touch x in the workspace.
                                  
• Running touch x                 
                                    
                                    
                                    
                                    
                                   
                                
                               
                             
 
 
  Would you like to run the following command?
 
  Environment: local
 
  Reason: The sandbox failed to start. Allow
  running touch x outside the sandbox?
 
  $ touch x
 
 
› 1. Yes, proceed (y)                           
  2. Yes, and don't ask again for commands that
     start with `touch x` (p)
  3. No, and tell Codex what to do differently
     (esc)
                                                
  Press enter to confirm or esc to cancel       
"""#
        let narrowBashDown = #"""
 Do you want to proceed?                   
   1. Yes                                       
 ❯ 2. Yes, and always allow access to          
      /tmp/zz-cap2/claude from this project   
   3. Yes, and switch to auto mode · auto mode 
      handles these prompts for you             
   4. No                  

 Esc to cancel                                
"""#

        // Claude trust prompt: no numbers, default "No, exit"; highlight on row 1 and on row 2.
        eq("trust", summary(trust), ">No, exit | Yes, I trust this folder")
        eq("trust pick 1", pick(trust, 0), "Enterx1")
        eq("trust pick 2", pick(trust, 1), "Downx1,Enterx1")
        let trustRow2 = trust.replacingOccurrences(of: " ❯ No, exit", with: "   No, exit")
            .replacingOccurrences(of: "   Yes, I trust", with: " ❯ Yes, I trust")
        eq("trust row 2", summary(trustRow2), "No, exit | >Yes, I trust this folder")
        eq("trust row 2 pick 1", pick(trustRow2, 0), "Upx1,Enterx1")
        eq("trust row", options(lines(trust)).first?.row, lines(trust).firstIndex { $0.contains("❯ No, exit") })
        eq("trust spoken", spokenAt(trust, 1), "Chọn 2: Yes, I trust this folder")
        eq("trust then main screen", summary(trustAfterEnter), "none")

        // AskUserQuestion: single choice with descriptions, "Chat about this" below a rule, tabs.
        eq("ask single", summary(askSingle), ">1. Tốc độ | 2. Chính xác | 3. Cân bằng | 4. Type something. | 5. Chat about this <>")
        eq("ask single pick 5", pick(askSingle, 4), "Downx4,Enterx1")
        eq("ask single pick Type something", pick(askSingle, 3), "Downx3")
        // A description starting with ">" below or above the highlight is text, not a marker.
        let descBelow = askSingle.replacingOccurrences(of: "     Làm nhanh, chấp nhận kiểm tra ít hơn.",
                                                       with: "     Làm nhanh, chấp nhận kiểm tra ít hơn.\n     > 10 files")
        eq("desc > below", summary(descBelow), summary(askSingle))
        let descAbove = descBelow.replacingOccurrences(of: "❯ 1. Tốc độ", with: "  1. Tốc độ")
            .replacingOccurrences(of: "  2. Chính xác", with: "❯ 2. Chính xác")
        eq("desc > above", summary(descAbove), "1. Tốc độ | >2. Chính xác | 3. Cân bằng | 4. Type something. | 5. Chat about this <>")
        // Multi-select: checkbox rows toggle with Space; "Submit" is a row of its own.
        let multiRest = "3. [ ] Tóm tắt cuối | 4. [ ] Type something | Submit | 5. Chat about this <>"
        eq("multi", summary(multiTab2), ">1. [ ] Tiến độ | 2. [ ] Cảnh báo | " + multiRest)
        eq("multi pick 2", pick(multiTab2, 1), "Downx1,Spacex1")
        eq("multi pick Submit", pick(multiTab2, 4), "Downx4,Enterx1")
        eq("multi pick 5", pick(multiTab2, 5), "Downx5,Enterx1")
        eq("multi pick Type something", pick(multiTab2, 3), "Downx3")
        // The cursor on the Submit row, drawn "❯    Submit" (captured at phone width: narrowOnSubmit).
        let onSubmit = multiTab2.replacingOccurrences(of: "❯ 1. [ ] Tiến độ", with: "  1. [ ] Tiến độ")
            .replacingOccurrences(of: "     Submit", with: "❯    Submit")
        eq("multi on Submit", summary(onSubmit), "1. [ ] Tiến độ | 2. [ ] Cảnh báo | 3. [ ] Tóm tắt cuối | 4. [ ] Type something | >Submit | 5. Chat about this <>")
        eq("multi on Submit pick 1", pick(onSubmit, 0), "Upx4,Spacex1")
        eq("multi Submit spoken", spokenAt(multiTab2, 4), "Chọn: Submit")
        eq("multi down", summary(multiDown), "1. [ ] Tiến độ | >2. [ ] Cảnh báo | " + multiRest)
        eq("multi space", summary(multiSpace), "1. [ ] Tiến độ | >2. [x] Cảnh báo | " + multiRest)
        eq("multi raw", summary(tab2Raw), ">1. [ ] Tiến độ | 2. [x] Cảnh báo | " + multiRest)
        eq("multi row 3", summary(typeSomething), "1. [ ] Tiến độ | 2. [x] Cảnh báo | >" + multiRest)
        eq("multi row 3 pick 1", pick(typeSomething, 0), "Upx2,Spacex1")
        eq("multi row 4", summary(submitRow), "1. [ ] Tiến độ | 2. [x] Cảnh báo | 3. [ ] Tóm tắt cuối | >4. [ ] Type something | Submit | 5. Chat about this <>")
        eq("submit tab", summary(submitTab), ">1. Submit answers | 2. Cancel <>")

        // Bash permission menu.
        eq("bash", summary(bash), ">1. Yes | 2. Yes, and always allow access to /tmp/zz-cap/claude from this project | 3. Yes, and switch to auto mode · auto mode handles these prompts for you | 4. No")
        eq("bash pick 4", pick(bash, 3), "Downx3,Enterx1")
        eq("bash spoken", spokenAt(bash, 3), "Chọn 4: No")

        // Codex: approval (› marker), after Down, /permissions and /model selection lists.
        let approval = ["Yes, proceed (y)", "Yes, and don't ask again for commands that start with `touch x` (p)",
                        "No, and tell Codex what to do differently (esc)"]
        eq("codex approval", summary(codexApproval), ">1. \(approval[0]) | 2. \(approval[1]) | 3. \(approval[2])")
        eq("codex approval pick 3", pick(codexApproval, 2), "Downx2,Enterx1")
        eq("codex approval down", summary(codexApprovalDown), "1. \(approval[0]) | >2. \(approval[1]) | 3. \(approval[2])")
        eq("codex approval down pick 1", pick(codexApprovalDown, 0), "Upx1,Enterx1")
        eq("codex permissions", summary(codexPermissions), ">1. Ask for approval | 2. Approve for me | 3. Full Access | 4. Read Only")
        eq("codex model", summary(codexModel), ">1. GPT-6.1-Sol (current) | 2. GPT-6-Astra | 3. GPT-6.1 Terra | 4. GPT-6-Sol | 5. GPT-6-Luna | 6. GPT-5.6-Sol | 7. GPT-5.6-Terra | 8. GPT-5.6-Luna")

        // omp Ask box: no numbers, U+F054 chevron, U+F10C circles, descriptions 2 columns deeper.
        let ompRows = "Xem trạng thái repo (Recommended) | Bắt đầu task mới | Dọn dẹp thư mục tạm | Other (type your own)"
        eq("omp ask", summary(ompAsk), ">" + ompRows)
        // Typed text is dropped on "Other"; Enter opens omp's "Custom answer" editor (facts-menu-need-r5).
        eq("omp ask pick Other", pick(ompAsk, 3), "Downx3,Enterx1")
        eq("omp ask pick 2", pick(ompAsk, 1), "Downx1,Enterx1")
        // DERIVED from facts-menu-need-r5.md (its plain capture hides the chevron and circles; they
        // are put back as in ompAsk): the default highlight is the "(Recommended)" option, row 4.
        let ompFooter = lines(ompAsk).first { $0.contains("↑/↓ move") } ?? ""
        let ompRec = [
            "╭─ Ask ──────────────────────────────────────────╮",
            "│ Bạn muốn mình làm gì tiếp theo?                │",
            "├────────────────────────────────────────────────┤",
            "│   \u{F10C} A. Rà soát code                          │",
            "│       Đọc và đánh giá code trong thư mục hiện tại. │",
            "│   \u{F10C} B. Sửa lỗi                               │",
            "│       Bạn mô tả lỗi, mình đưa vào quy trình sửa. │",
            "│   \u{F10C} C. Thêm tính năng                        │",
            "│       Lên kế hoạch và làm một tính năng mới.   │",
            "│ \u{F054} \u{F10C} D. Chỉ thử công cụ (Recommended)        │",
            "│       Không làm gì thêm, chỉ kiểm tra công cụ. │",
            "│   \u{F10C} Other (type your own)                    │",
            "├────────────────────────────────────────────────┤",
            ompFooter,
            "╰────────────────────────────────────────────────╯",
        ].joined(separator: "\n")
        eq("omp recommended", summary(ompRec), "A. Rà soát code | B. Sửa lỗi | C. Thêm tính năng | >D. Chỉ thử công cụ (Recommended) | Other (type your own)")
        eq("omp recommended pick 1", pick(ompRec, 0), "Upx3,Enterx1")
        eq("omp recommended pick Other", pick(ompRec, 4), "Downx1,Enterx1")
        eq("omp recommended spoken", spokenAt(ompRec, 0), "Chọn 1: A. Rà soát code")
        eq("omp ask spoken", spokenAt(ompAsk, 3), "Chọn 4: Other (type your own)")
        let ompAskDown = ompAsk.replacingOccurrences(of: "│ \u{F054} \u{F10C} Xem", with: "│   \u{F10C} Xem")
            .replacingOccurrences(of: "│   \u{F10C} Bắt", with: "│ \u{F054} \u{F10C} Bắt")
        eq("omp ask down", summary(ompAskDown), ompRows.replacingOccurrences(of: "| Bắt", with: "| >Bắt"))
        eq("omp ask down pick 1", pick(ompAskDown, 0), "Upx1,Enterx1")

        // Phone width: the footer wraps to 2 lines, labels wrap at the label column (a description).
        let narrowExtras = "1. [ ] Chế độ tối | 2. [ ] Hiệu ứng động | 3. [ ] Âm thanh | "
        eq("narrow ask", summary(narrowAsk), ">1. Xanh dương | 2. Xanh lá | 3. Đỏ | 4. Type something. | 5. Chat about this <>")
        eq("narrow multi", summary(narrowMulti), ">" + narrowExtras + "4. [ ] Type something | Submit | 5. Chat about this <>")
        eq("narrow on Type something", summary(narrowOnType), narrowExtras + ">4. [ ] Type something | Submit | 5. Chat about this <>")
        eq("narrow on Submit", summary(narrowOnSubmit), narrowExtras + "4. [ ] Type something | >Submit | 5. Chat about this <>")
        eq("narrow on Submit pick 1", pick(narrowOnSubmit, 0), "Upx4,Spacex1")
        eq("narrow on Type something pick Submit", pick(narrowOnType, 4), "Downx1,Enterx1")
        let narrowBashRows = ["1. Yes", "2. Yes, and always allow access to", "3. Yes, and switch to auto mode · auto mode", "4. No"]
        eq("narrow bash", summary(narrowBash), ">" + narrowBashRows.joined(separator: " | "))
        eq("narrow bash pick 4", pick(narrowBash, 3), "Downx3,Enterx1")
        eq("narrow bash down", summary(narrowBashDown), narrowBashRows[0] + " | >" + narrowBashRows[1...].joined(separator: " | "))
        eq("narrow codex", summary(narrowCodex), ">1. Yes, proceed (y) | 2. Yes, and don't ask again for commands that | 3. No, and tell Codex what to do differently")
        eq("narrow codex pick 3", pick(narrowCodex, 2), "Downx2,Enterx1")

        // Not a live menu: input prompts, sent prompts in the transcript, numbered drafts, browsers.
        let notMenus: [(String, String)] = [
            ("idleAfterEsc", idleAfterEsc), ("autoRan", autoRan), ("btabCycle", btabCycle),
            ("draftSayAB", draftSayAB), ("replySayAB", replySayAB), ("transcriptRaw", transcriptRaw),
            ("draftFoo", draftFoo), ("afterCU", afterCU), ("codexStart", codexStart), ("codexSandbox", codexSandbox),
            ("codexReject", codexReject), ("codexIdle", codexIdle), ("codexAfterEsc", codexAfterEsc),
            ("codexDraftSay", codexDraftSay), ("codexTranscriptSay", codexTranscriptSay), ("codexDraftFoo", codexDraftFoo),
            ("codexAfterCU", codexAfterCU), ("codexAfterEsc2", codexAfterEsc2), ("ompAfterEsc", ompAfterEsc),
            ("omp3b", omp3b), ("ompDraftSEnter", ompDraftSEnter), ("ompDraftAltEnter", ompDraftAltEnter),
            ("ompIdle", ompIdle), ("ompTranscript", ompTranscript), ("ompSlash", ompSlash), ("ompModels", ompModels),
            ("ompSettings", ompSettings),
        ]
        for (name, text) in notMenus { eq(name, summary(text), "none") }
        // A status line that merely contains footer words: a codex thread title, an omp project.
        eq("codex draft, title Esc to cancel", summary(codexDraftFoo.replacingOccurrences(of: "Create x file", with: "Esc to cancel stale jobs")), "none")
        eq("omp draft, project select-cancel", summary(ompDraftAltEnter.replacingOccurrences(of: "zz-cap/omp", with: "select-cancel")), "none")

        // sameScreen: the whole text, trailing spaces and blank lines ignored; no menu on both sides.
        func same(_ a: String, _ b: String) -> Bool {
            sameScreen(lines(a), menu(lines(a)), lines(b), menu(lines(b)))
        }
        eq("same screen", same(trust, trust), true)
        eq("stale padding", same(trust, lines(trust).map { $0 + "   " }.joined(separator: "\n") + "\n\n"), true)
        eq("both working", same("✻ Thinking… (3s)", "✻ Thinking… (4s)"), true)
        eq("highlight moved", same(trust, trustRow2), false)
        eq("checkbox toggled", same(multiDown, multiSpace), false)
        eq("menu gone", same(bash, idleAfterEsc), false)
        eq("menu came", same(idleAfterEsc, bash), false)
        let nextBash = bash.replacingOccurrences(of: "echo hi > x.txt", with: "echo bye > y.txt")
        eq("next prompt, same choices", same(bash, nextBash), false)
        eq("next prompt keeps the menu", summary(nextBash), summary(bash))
        eq("new output above", same(trust, "older output\n\n" + trust), false)
        let noHeader = lines(askSingle).filter { !$0.hasPrefix("←") }.joined(separator: "\n")
        eq("tab header gone", same(askSingle, noHeader), false)

        // Rules on small inputs.
        eq("empty", summary(""), "none")
        eq("gap", summary("Pick\n❯ 1. Yes\n  3. No\n\nEsc to cancel"), "none")
        eq("two highlights", summary("Allow?\n› 1. Yes\n> 2. Always\n\nEsc to cancel"), "none")
        eq("single option", summary("Pick\n❯ 1. Yes\n\nEsc to cancel"), "none")
        eq("no hint", summary("Pick\n❯ 1. Yes\n  2. No\n\nok"), "none")
        eq("with hint", summary("Pick\n❯ 1. Yes\n  2. No\n\nEsc to cancel"), ">1. Yes | 2. No")
        eq("out of window", summary(ompAsk + "\n" + (1...40).map { "line \($0)" }.joined(separator: "\n")), "none")
        eq("footer wrapped", summary("Pick\n❯ 1. Yes\n  2. No\n\nEnter to select · Tab/Arrow\nkeys to navigate"), ">1. Yes | 2. No")
        eq("footer not in the bottom block", summary("Pick\n❯ 1. Yes\n  2. No\n\nEsc to cancel\n\nok"), "none")
        // A draft line that starts with a footer phrase is still a draft (a pick would submit it).
        let draft3 = draftFoo.replacingOccurrences(of: "  2. bar              ", with: "  2. bar\n  Esc to cancel stale jobs")
        eq("draft, 3rd line Esc to cancel, replaced", draft3 != draftFoo, true)
        eq("draft, 3rd line Esc to cancel", summary(draft3), "none")
        eq("draft, 3rd line Enter to confirm", summary(draftFoo.replacingOccurrences(of: "  2. bar              ", with: "  2. bar\n  Enter to confirm the order")), "none")
        let ompDraft3 = ompDraftAltEnter.replacingOccurrences(of: "  2. bare", with: "  2. bare\n  Esc to cancel x")
        eq("omp draft, 3rd line Esc to cancel, replaced", ompDraft3 != ompDraftAltEnter, true)
        eq("omp draft, 3rd line Esc to cancel", summary(ompDraft3), "none")
        let ompBare = ompDraftAltEnter.replacingOccurrences(of: "❯ 1. foo", with: "❯ foo")
            .replacingOccurrences(of: "  2. bare", with: "  bare\n  Enter to confirm x")
        eq("omp unnumbered draft, Enter to confirm, replaced", ompBare.contains("❯ foo ") && ompBare.contains("  bare\n"), true)
        eq("omp unnumbered draft, Enter to confirm", summary(ompBare), "none")
        eq("narrow wrapped draft", summary(draftFoo.replacingOccurrences(of: "  2. bar              ",
                                                                         with: "  2. the hint at the bottom says\n  Esc to cancel but it does not")), "none")
        eq("footer block of 7 rows", summary("Pick\n❯ 1. Yes\n  2. No\n\nEsc to cancel\na\nb\nc\nd\ne\nf"), "none")
        // DERIVED (provisional until a ~40-column capture): the ctrl+g footer wrapped to 3 rows.
        let footer3 = narrowOnType.replacingOccurrences(of: "Enter to select · Tab/Arrow keys to navigate · \nctrl+g to edit in Vim · Esc to cancel",
                                                        with: "Enter to select · Tab/Arrow keys to\nnavigate · ctrl+g to edit in Vim · Esc to\ncancel")
        eq("footer 3 lines, replaced", footer3 != narrowOnType, true)
        eq("footer 3 lines", summary(footer3), summary(narrowOnType))
        eq("footer 5 lines", summary("Pick\n❯ 1. Yes\n  2. No\n\nEnter to select ·\nTab/Arrow keys to\nnavigate · ctrl+g to\nedit in Vim · Esc to\ncancel"), ">1. Yes | 2. No")
        // DERIVED: codex's footer at 21 columns ("Press enter to confirm" itself wraps).
        let codex21 = narrowCodex.replacingOccurrences(of: "  Press enter to confirm or esc to cancel",
                                                       with: "  Press enter to\n  confirm or esc to\n  cancel")
        eq("codex footer at 21 cols, replaced", codex21 != narrowCodex, true)
        eq("codex footer at 21 cols", summary(codex21), summary(narrowCodex))
        // Pinned rules: the window offset, a marker needs a space, the walk up stops at "1.", no mix.
        let far = (1...50).map { "x\($0)" }.joined(separator: "\n") + "\n\n" + trust
        eq("row beyond window", options(lines(far)).first?.row, lines(far).firstIndex { $0.contains("❯ No, exit") })
        eq("marker needs a space", summary("Pick\n❯ No\n  >_ Yes\n\nEsc to cancel"), ">No | >_ Yes")
        eq("stops at 1.", summary("Pick\n  Note here\n  1. Yes\n❯ 2. No\n\nEsc to cancel"), "1. Yes | >2. No")
        eq("mixed rows", summary("Pick\n❯ 1. Yes\n  maybe\n  2. No\n\nEsc to cancel"), "none")
        eq("footer inside a line", summary("Pick\n❯ 1. Yes\n  2. No\n\nok · Esc to cancel"), "none")
        eq("wrapped label", summary("Run?\n› 1. Yes\n  2. Yes, and don't ask\n   again\n  3. No\n\nPress enter to confirm or esc to cancel"),
           ">1. Yes | 2. Yes, and don't ask | 3. No")
        eq("free text", [askSingle, multiTab2, ompAsk].map { options(lines($0)).filter(isFreeText).count }, [1, 1, 0])

        // Distances: up to 20 rows, never a capped move.
        let long = (0..<25).map { Option(number: $0 + 1, label: "o\($0)", highlighted: $0 == 0, row: $0) }
        eq("down 20", keyText(keys(toChoose: long[20], in: long)), "Downx20,Enterx1")
        eq("down 21", keyText(keys(toChoose: long[21], in: long)), "")
        let lastLit = (0..<25).map { Option(number: $0 + 1, label: "o\($0)", highlighted: $0 == 24, row: $0) }
        eq("up 3", keyText(keys(toChoose: lastLit[21], in: lastLit)), "Upx3,Enterx1")
        eq("up 24", keyText(keys(toChoose: lastLit[0], in: lastLit)), "")
        eq("target missing", keyText(keys(toChoose: Option(number: 9, label: "x", highlighted: false), in: Array(long.prefix(3)))), "")
        let twoLit = [Option(number: 1, label: "a", highlighted: true), Option(number: 2, label: "b", highlighted: true, row: 1)]
        eq("keys two highlights", keyText(keys(toChoose: twoLit[1], in: twoLit)), "")

        return failures
    }
}
