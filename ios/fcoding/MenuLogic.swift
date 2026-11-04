import Foundation

/// The numbered choice menu at the bottom of a session screen (Claude's trust and permission
/// prompts, codex and omp menus), and the keys that pick one option. Pure Foundation: CI builds it
/// for macOS and runs `selfTest()`.
enum MenuLogic {
    struct Option: Equatable {
        let number: Int
        let label: String
        /// The line starts with ❯, > or ›: the option the cursor is on.
        let highlighted: Bool
    }

    /// Lines looked at: the last 12 non-empty ones (as the server's tailLines, wider).
    static let window = 12
    /// The server accepts a repeat of 1...20 for one key.
    static let maxRepeat = 20

    private static let markers: Set<Character> = ["❯", ">", "›"]

    /// Box drawing and block elements (U+2500...U+259F) and "|" are border chrome.
    private static func isEdge(_ c: Character) -> Bool {
        if c == "|" || c.isWhitespace { return true }
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x2500...0x259F).contains(s.value)
    }

    /// One parsed screen line: the option it holds (if any), its text after the border, and the
    /// column where its content starts (after the border, spaces and the highlight marker).
    private struct Line {
        var option: Option?
        var text: String
        var column: Int
    }

    private static func parse(_ raw: String) -> Line {
        let chars = Array(raw.replacingOccurrences(of: "\t", with: " "))
        var start = 0, end = chars.count
        while start < end, isEdge(chars[start]) { start += 1 }
        while end > start, isEdge(chars[end - 1]) { end -= 1 }
        let text = String(chars[start..<end])
        var i = start
        let highlighted = i < end && markers.contains(chars[i])
        if highlighted { i += 1 }
        while i < end, chars[i].isWhitespace { i += 1 }
        let column = i
        var number = 0, digits = 0
        while i < end, let d = chars[i].wholeNumberValue, chars[i].isASCII, digits < 3 {
            number = number * 10 + d
            digits += 1
            i += 1
        }
        guard digits > 0, i < end, chars[i] == ".", i + 1 < end, chars[i + 1].isWhitespace else {
            return Line(option: nil, text: text, column: column)
        }
        let label = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return Line(option: nil, text: text, column: column) }
        return Line(option: Option(number: number, label: label, highlighted: highlighted), text: text, column: column)
    }

    /// The menu now on screen: the last run of numbered lines in the last 12 non-empty lines.
    /// Wrapped label lines inside the run (indented past the option's number) are skipped; any
    /// other line ends the run, and a "1." starts a new one. Returned only when the run has at
    /// least 2 options numbered 1, 2, 3… in order and exactly ONE of them is highlighted (❯, > or
    /// ›), so a plain numbered list in an answer is never a menu; otherwise [].
    static func options(_ lines: [String]) -> [Option] {
        let tail = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(window).map(parse)
        var last: [Option] = []
        var run: [Option] = []
        var column = 0
        for line in tail {
            if let o = line.option {
                if o.number == 1 || run.isEmpty {
                    if !run.isEmpty { last = run }
                    run = [o]
                } else {
                    run.append(o)
                }
                column = line.column
            } else if !run.isEmpty, !line.text.isEmpty, line.column > column {
                continue // a wrapped label line
            } else if !run.isEmpty {
                last = run
                run = []
            }
        }
        if !run.isEmpty { last = run }
        guard last.count >= 2, last.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }),
              last.filter(\.highlighted).count == 1 else { return [] }
        return last
    }

    /// The keys that move the highlight to `target` and confirm it: Up or Down (repeat capped at
    /// 20, left out when already there), then Enter. [] only for invalid input (not exactly one
    /// option highlighted, or the target not in the list); never for a menu `options` returned.
    static func keys(toChoose target: Option, in opts: [Option]) -> [(key: String, `repeat`: Int)] {
        let lit = opts.indices.filter { opts[$0].highlighted }
        guard lit.count == 1, let t = opts.firstIndex(where: { $0.number == target.number }) else { return [] }
        let h = lit[0]
        var out: [(key: String, `repeat`: Int)] = []
        if t < h { out.append((key: "Up", `repeat`: min(maxRepeat, h - t))) }
        if t > h { out.append((key: "Down", `repeat`: min(maxRepeat, t - h))) }
        out.append((key: "Enter", `repeat`: 1))
        return out
    }

    // MARK: - Self-test

    static func selfTest() -> [String] {
        var failures: [String] = []
        func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got != want { failures.append("\(name): got \(got), want \(want)") }
        }
        func opts(_ text: String) -> [Option] { options(text.components(separatedBy: "\n")) }
        func summary(_ o: [Option]) -> String {
            o.map { "\($0.highlighted ? ">" : "")\($0.number) \($0.label)" }.joined(separator: " | ")
        }
        func keyText(_ k: [(key: String, `repeat`: Int)]) -> String {
            k.map { "\($0.key)x\($0.repeat)" }.joined(separator: ",")
        }
        func pick(_ text: String, _ n: Int) -> String {
            let o = opts(text)
            guard let t = o.first(where: { $0.number == n }) else { return "no option \(n)" }
            return keyText(keys(toChoose: t, in: o))
        }

        // Claude's trust prompt, highlight on 1 and on 2, picking each.
        let trust1 = """
         Do you trust the files in this folder?

         /data/workspace/fcoding

         Claude Code may read, write, or execute files contained in this directory.

         ❯ 1. Yes, proceed
           2. No, exit

         Enter to confirm · Esc to exit
        """
        eq("trust options", summary(opts(trust1)), ">1 Yes, proceed | 2 No, exit")
        eq("trust 1 pick 1", pick(trust1, 1), "Enterx1")
        eq("trust 1 pick 2", pick(trust1, 2), "Downx1,Enterx1")
        let trust2 = trust1.replacingOccurrences(of: "❯ 1. Yes", with: "  1. Yes").replacingOccurrences(of: "  2. No", with: "❯ 2. No")
        eq("trust 2 options", summary(opts(trust2)), "1 Yes, proceed | >2 No, exit")
        eq("trust 2 pick 1", pick(trust2, 1), "Upx1,Enterx1")
        eq("trust 2 pick 2", pick(trust2, 2), "Enterx1")

        // A permission prompt with 3 options, highlight on 1.
        let perm = """
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again for ls commands
          3. No, and tell Claude what to do differently (esc)
        """
        eq("perm options", opts(perm).count, 3)
        eq("perm pick 3", pick(perm, 3), "Downx2,Enterx1")
        eq("perm pick 2", pick(perm, 2), "Downx1,Enterx1")

        // Inside a box border.
        let boxed = """
        ╭───────────────────────────────╮
        │ Bash command                  │
        │                               │
        │   ls -la                      │
        │                               │
        │ Do you want to proceed?       │
        │ ❯ 1. Yes                      │
        │   2. No, and tell Claude what │
        ╰───────────────────────────────╯
        """
        eq("boxed options", summary(opts(boxed)), ">1 Yes | 2 No, and tell Claude what")
        eq("boxed pick 2", pick(boxed, 2), "Downx1,Enterx1")

        // Wrapped label lines inside the run are skipped.
        let wrapped = """
        Do you want to make this edit?
        ❯ 1. Yes
          2. Yes, and don't ask again for this command in
             /data/workspace/fcoding/ios
          3. No
        """
        eq("wrapped options", summary(opts(wrapped)), ">1 Yes | 2 Yes, and don't ask again for this command in | 3 No")
        eq("wrapped pick 3", pick(wrapped, 3), "Downx2,Enterx1")

        // No menu, a single option, a numbering gap.
        eq("no menu", opts("$ ls\nREADME.md\nserver.mjs\n$ ").count, 0)
        eq("empty screen", options([]).count, 0)
        eq("single option", opts("Continue?\n❯ 1. Yes\n").count, 0)
        eq("gap", opts("Pick\n❯ 1. Yes\n  3. No\n").count, 0)
        eq("starts at 2", opts("Pick\n❯ 2. Yes\n  3. No\n").count, 0)
        eq("no space after dot", opts("1.5 MB\n2.0 MB\n").count, 0)

        // No highlight or two highlights: not a menu.
        eq("no highlight", opts("Choose a model:\n1. Opus\n2. Sonnet\n").count, 0)
        eq("two highlights", opts("Allow this command?\n› 1. Yes\n> 2. Yes, and always allow\n").count, 0)
        // Claude's answer with a plain numbered list, then the "> " input prompt: not a menu.
        let answer = "● Next steps:\n  1. Add the parser\n  2. Wire the bar\n  3. Update the docs\n\n> \n"
        eq("answer list", opts(answer).count, 0)
        // The highlighted option itself: Enter only.
        eq("already highlighted", pick(perm, 1), "Enterx1")
        // keys() on invalid input (two highlights, built by hand) is [].
        let twoLit = [Option(number: 1, label: "a", highlighted: true), Option(number: 2, label: "b", highlighted: true)]
        eq("keys two highlights", keyText(keys(toChoose: twoLit[1], in: twoLit)), "")

        // An older menu higher up, a newer one below: the newer wins.
        let twice = """
        ❯ 1. Old yes
          2. Old no
        You chose: Old yes
        Running…
        Do you want to proceed?
          1. New yes
          2. New maybe
        ❯ 3. New no
        """
        eq("newer menu", summary(opts(twice)), "1 New yes | 2 New maybe | >3 New no")
        eq("newer pick 1", pick(twice, 1), "Upx2,Enterx1")
        // Back to back, a "1." starts the newer run.
        eq("back to back", summary(opts("❯ 1. A\n  2. B\n❯ 1. C\n  2. D\n")), ">1 C | 2 D")
        // Only the last 12 non-empty lines count.
        let old = "❯ 1. Yes\n  2. No\n" + (1...12).map { "line \($0)" }.joined(separator: "\n")
        eq("out of window", opts(old).count, 0)

        // Up/Down counts and the 20 cap.
        let long = (1...25).map { Option(number: $0, label: "o\($0)", highlighted: $0 == 1) }
        eq("down 4", keyText(keys(toChoose: long[4], in: long)), "Downx4,Enterx1")
        eq("down cap", keyText(keys(toChoose: long[24], in: long)), "Downx20,Enterx1")
        let lastLit = (1...25).map { Option(number: $0, label: "o\($0)", highlighted: $0 == 25) }
        eq("up cap", keyText(keys(toChoose: lastLit[0], in: lastLit)), "Upx20,Enterx1")
        eq("up 3", keyText(keys(toChoose: lastLit[21], in: lastLit)), "Upx3,Enterx1")
        eq("target missing", keyText(keys(toChoose: Option(number: 9, label: "x", highlighted: false), in: Array(long.prefix(3)))), "")

        return failures
    }
}
