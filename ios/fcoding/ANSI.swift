import SwiftUI
import UIKit

/// SGR colours in the screen text (api/screen and api/stream with `ansi=1`), as pure functions:
/// `runs` splits the text into styled runs, `attributed` turns them into an AttributedString.
enum ANSI {
    struct Style: Equatable {
        /// 0xRRGGBB; nil = the terminal default.
        var fg: UInt32?
        var bg: UInt32?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
    }

    struct Run: Equatable {
        var text: String
        var style: Style
    }

    /// PostScript name of the bundled SymbolsNerdFontMono-Regular.ttf (name table ID 6).
    static let nerdFontName = "SymbolsNFM"
    /// Color(white: 0.92) on black.
    static let defaultFG: UInt32 = 0xEBEBEB
    static let defaultBG: UInt32 = 0x000000

    // MARK: - Parsing

    /// Splits `text` on SGR escapes (ESC [ … m). Any other escape is dropped. Adjacent runs with the
    /// same style are merged, so the run count stays low.
    static func runs(_ text: String) -> [Run] {
        let s = Array(text.unicodeScalars)
        var out: [Run] = []
        var style = Style()
        var buf = String.UnicodeScalarView()

        func flush() {
            guard !buf.isEmpty else { return }
            if let last = out.last, last.style == style {
                out[out.count - 1].text.unicodeScalars.append(contentsOf: buf)
            } else {
                out.append(Run(text: String(buf), style: style))
            }
            buf = String.UnicodeScalarView()
        }

        var i = 0
        while i < s.count {
            let c = s[i]
            guard c == "\u{1B}" else {
                buf.append(c)
                i += 1
                continue
            }
            guard i + 1 < s.count else { break }
            switch s[i + 1] {
            case "[": // CSI: parameter / intermediate bytes, then a final byte 0x40–0x7E
                var j = i + 2
                while j < s.count, (0x20...0x3F).contains(s[j].value) { j += 1 }
                guard j < s.count else { i = s.count; continue }
                // Not a final byte: abandon the sequence, keep s[j] as text.
                guard (0x40...0x7E).contains(s[j].value) else { i = j; continue }
                // A private-parameter CSI ("ESC[>4;2m", "ESC[?25h") is never SGR.
                let isPrivate = j > i + 2 && "<=>?".unicodeScalars.contains(s[i + 2])
                if s[j] == "m", !isPrivate {
                    var next = style
                    apply(String(String.UnicodeScalarView(s[(i + 2)..<j])), to: &next)
                    if next != style {
                        flush()
                        style = next
                    }
                }
                i = j + 1
            case "]": // OSC: up to BEL or ESC \
                var j = i + 2
                while j < s.count, s[j] != "\u{07}", !(s[j] == "\u{1B}" && j + 1 < s.count && s[j + 1] == "\\") { j += 1 }
                i = j < s.count && s[j] == "\u{1B}" ? j + 2 : j + 1
            default: // two-byte escape
                i += 2
            }
        }
        flush()
        return out
    }

    /// Applies one SGR parameter string ("1;38;5;208") to `style`.
    static func apply(_ params: String, to style: inout Style) {
        let parts = params.split(separator: ";", omittingEmptySubsequences: false)
        func num(_ p: Substring) -> Int { Int(p) ?? 0 }
        var k = 0
        while k < parts.count {
            // A part may carry colon sub-parameters ("38:2::r:g:b", "4:3"); the first is the code.
            let sub = parts[k].split(separator: ":", omittingEmptySubsequences: false).map(num)
            let code = sub[0]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 22: style.bold = false; style.dim = false
            case 3: style.italic = true
            case 23: style.italic = false
            case 4: style.underline = true
            case 24: style.underline = false
            case 7: style.inverse = true
            case 27: style.inverse = false
            case 30...37: style.fg = palette(code - 30)
            case 90...97: style.fg = palette(code - 90 + 8)
            case 39: style.fg = nil
            case 40...47: style.bg = palette(code - 40)
            case 100...107: style.bg = palette(code - 100 + 8)
            case 49: style.bg = nil
            case 38, 48:
                var color: UInt32?
                if sub.count > 1 {
                    if sub[1] == 5, sub.count > 2 { color = palette(sub[2]) }
                    if sub[1] == 2, sub.count >= 5 { color = rgb(sub[sub.count - 3], sub[sub.count - 2], sub[sub.count - 1]) }
                } else {
                    let rest = parts[(k + 1)...].prefix(4).map(num)
                    if rest.first == 5, rest.count >= 2 {
                        color = palette(rest[1])
                        k += 2
                    } else if rest.first == 2, rest.count >= 4 {
                        color = rgb(rest[1], rest[2], rest[3])
                        k += 4
                    }
                }
                if let color = color {
                    if code == 38 { style.fg = color } else { style.bg = color }
                }
            default: break
            }
            k += 1
        }
    }

    // MARK: - Colours

    private static let base16: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]
    private static let cube: [UInt32] = [0, 95, 135, 175, 215, 255]

    /// Standard xterm-256 palette.
    static func palette(_ index: Int) -> UInt32 {
        let n = max(0, min(255, index))
        if n < 16 { return base16[n] }
        if n < 232 {
            let i = n - 16
            return cube[i / 36] << 16 | cube[(i / 6) % 6] << 8 | cube[i % 6]
        }
        let g = UInt32(8 + 10 * (n - 232))
        return g << 16 | g << 8 | g
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        UInt32(max(0, min(255, r))) << 16 | UInt32(max(0, min(255, g))) << 8 | UInt32(max(0, min(255, b)))
    }

    /// Foreground and background after inverse; bg nil = no background drawn.
    static func colors(_ style: Style) -> (fg: UInt32, bg: UInt32?) {
        let fg = style.fg ?? defaultFG
        guard style.inverse else { return (fg, style.bg) }
        return (style.bg ?? defaultBG, fg)
    }

    static func color(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    // MARK: - Fonts

    /// The monospaced system font, with the Nerd Font symbols as a fallback for icon glyphs.
    static func terminalFont(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        var desc = UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular).fontDescriptor
        if italic, let d = desc.withSymbolicTraits(desc.symbolicTraits.union(.traitItalic)) { desc = d }
        desc = desc.addingAttributes([.cascadeList: [UIFontDescriptor(fontAttributes: [.name: nerdFontName])]])
        return UIFont(descriptor: desc, size: size)
    }

    /// Nerd Font icons: the Private Use Area and planes 15–16.
    static func isIcon(_ c: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(c.value) || c.value >= 0xF0000
    }

    /// One terminal cell: the "M" advance of the base font.
    static func cellWidth(size: CGFloat) -> CGFloat {
        ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
    }

    /// Point size for the Nerd icon font so one icon is exactly one cell wide. Every glyph of
    /// SymbolsNerdFontMono advances 2048 units on a 2048 em, i.e. 1.0 em, so advance = point size;
    /// SF Mono advances about 0.6 em. Hence point size = cell width (≈ 0.6 × base size).
    static func iconFontSize(forBase size: CGFloat) -> CGFloat { cellWidth(size: size) }

    struct Fonts {
        let regular: Font
        let bold: Font
        let italic: Font
        let boldItalic: Font
        /// The Nerd font itself (not through the cascade), sized to one cell.
        let icon: Font
        /// Raises the smaller icon so its centre sits on the centre of the text line.
        let iconBaselineOffset: CGFloat

        init(size: CGFloat) {
            let base = ANSI.terminalFont(size: size)
            regular = Font(base as CTFont)
            bold = Font(ANSI.terminalFont(size: size, bold: true) as CTFont)
            italic = Font(ANSI.terminalFont(size: size, italic: true) as CTFont)
            boldItalic = Font(ANSI.terminalFont(size: size, bold: true, italic: true) as CTFont)
            if let nerd = UIFont(name: ANSI.nerdFontName, size: ANSI.iconFontSize(forBase: size)) {
                icon = Font(nerd as CTFont)
                iconBaselineOffset = (base.ascender + base.descender) / 2 - (nerd.ascender + nerd.descender) / 2
                #if DEBUG
                let iconW = ("\u{F017}" as NSString).size(withAttributes: [.font: nerd]).width
                assert(abs(iconW - ANSI.cellWidth(size: size)) < 0.5, "Nerd icon is not one cell wide")
                #endif
            } else {
                icon = regular
                iconBaselineOffset = 0
            }
        }
    }

    // MARK: - AttributedString

    static func attributed(_ runs: [Run], fonts: Fonts) -> AttributedString {
        typealias A = AttributeScopes.SwiftUIAttributes
        var out = AttributedString()
        for run in runs {
            let st = run.style
            let (fg, bg) = colors(st)
            var c = AttributeContainer()
            c[A.ForegroundColorAttribute.self] = color(fg).opacity(st.dim ? 0.6 : 1)
            if let bg = bg { c[A.BackgroundColorAttribute.self] = color(bg) }
            if st.underline { c[A.UnderlineStyleAttribute.self] = .single }
            var text = c
            text[A.FontAttribute.self] = st.bold ? (st.italic ? fonts.boldItalic : fonts.bold)
                                                 : (st.italic ? fonts.italic : fonts.regular)
            var icon = c
            icon[A.FontAttribute.self] = fonts.icon
            icon[A.BaselineOffsetAttribute.self] = fonts.iconBaselineOffset

            // Icons get their own pieces, in the icon font; everything else keeps the text font.
            var piece = String.UnicodeScalarView()
            var pieceIsIcon = false
            func emit() {
                guard !piece.isEmpty else { return }
                out.append(AttributedString(String(piece), attributes: pieceIsIcon ? icon : text))
                piece = String.UnicodeScalarView()
            }
            for scalar in run.text.unicodeScalars {
                let iconScalar = isIcon(scalar)
                if iconScalar != pieceIsIcon {
                    emit()
                    pieceIsIcon = iconScalar
                }
                piece.append(scalar)
            }
            emit()
        }
        return out
    }
}
