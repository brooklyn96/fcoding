import SwiftUI

/// Colour and glyph per harness (CONTRACT A5 update 3). "all" is the dock's "Tất cả".
enum HarnessStyle {
    static let all = ["omp", "claude", "codex", "shell"]

    static func color(_ harness: String?) -> Color {
        switch harness {
        case "claude": return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case "omp": return Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255)
        case "codex": return Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 0xFF / 255)
        case "shell": return Color(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255)
        default: return .accentColor
        }
    }

    static func description(_ harness: String) -> String {
        switch harness {
        case "omp": return "oh-my-pi · tác tử lập trình"
        case "claude": return "Claude Code"
        case "codex": return "Codex CLI"
        default: return "Dòng lệnh trên box"
        }
    }
}

/// The harness mark at about `size` points, in the current foreground colour.
struct HarnessGlyph: View {
    let harness: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch harness {
            case "claude":
                ClaudeMark()
                    .stroke(style: StrokeStyle(lineWidth: size * 2.2 / 16, lineCap: .round))
                    .frame(width: size * 0.9, height: size * 0.9)
            case "codex":
                CodexMark().fill(style: FillStyle(eoFill: true)).frame(width: size, height: size)
            case "omp":
                Text("π").font(.system(size: size, weight: .bold, design: .monospaced))
            case "shell":
                Text(">_").font(.system(size: size * 0.85, weight: .bold, design: .monospaced))
            case "all":
                AllMark().fill().frame(width: size * 0.9, height: size * 0.9)
            default:
                Image(systemName: "terminal").font(.system(size: size * 0.85, weight: .semibold))
            }
        }
        .frame(minWidth: size, minHeight: size)
        .accessibilityHidden(true)
    }
}

/// Rounded-square avatar tinted with the harness colour (mockup `.hav`).
struct HarnessAvatar: View {
    let harness: String?
    var side: CGFloat = 34

    var body: some View {
        let c = HarnessStyle.color(harness)
        HarnessGlyph(harness: harness, size: side * 0.44)
            .foregroundColor(c)
            .frame(width: side, height: side)
            .background(c.opacity(0.17), in: RoundedRectangle(cornerRadius: side * 0.265, style: .continuous))
    }
}

/// Small tinted tag "glyph + name" (mockup `.hb`).
struct HarnessBadge: View {
    let harness: String

    var body: some View {
        let c = HarnessStyle.color(harness)
        HStack(spacing: 3) {
            HarnessGlyph(harness: harness, size: 9)
            Text(harness).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(c)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(c.opacity(0.17), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Claude: the eight-ray asterisk from the mockup (rays from 1.5 to 14.5 on a 16 grid), stroked.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 13
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 1.5) * s, y: rect.minY + (y - 1.5) * s)
        }
        var p = Path()
        let rays = [(P(8, 1.5), P(8, 14.5)), (P(1.5, 8), P(14.5, 8)),
                    (P(3.4, 3.4), P(12.6, 12.6)), (P(12.6, 3.4), P(3.4, 12.6))]
        for (a, b) in rays {
            p.move(to: a)
            p.addLine(to: b)
        }
        return p
    }
}

/// "Tất cả": four rounded squares (mockup 16 x 16 grid, squares from 1 to 15).
struct AllMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 14
        var p = Path()
        for (x, y) in [(0.0, 0.0), (8.0, 0.0), (0.0, 8.0), (8.0, 8.0)] {
            p.addRoundedRect(in: CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: 6 * s, height: 6 * s),
                             cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))
        }
        return p
    }
}

/// The official Codex mark (the mockup's inline SVG, 24 x 24 view box). Its SVG arcs were
/// converted to cubic curves offline. Fill with `FillStyle(eoFill: true)` so the ">_" stays cut out.
struct CodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        p.move(to: P(8.086, 0.457))
        p.addCurve(to: P(11.132, 0.042), control1: P(9.049, 0.061), control2: P(10.098, -0.082))
        p.addCurve(to: P(14.696, 1.742), control1: P(12.465, 0.195), control2: P(13.653, 0.762))
        p.addCurve(to: P(14.803, 1.771), control1: P(14.725, 1.769), control2: P(14.765, 1.78))
        p.addCurve(to: P(18.864, 2.137), control1: P(16.211, 1.425), control2: P(17.565, 1.547))
        p.addLine(to: P(18.927, 2.167))
        p.addLine(to: P(19.081, 2.243))
        p.addCurve(to: P(21.999, 5.441), control1: P(20.438, 2.946), control2: P(21.411, 4.013))
        p.addCurve(to: P(22.42, 7.567), control1: P(22.277, 6.12), control2: P(22.417, 6.829))
        p.addCurve(to: P(22.24, 9.198), control1: P(22.44, 8.117), control2: P(22.379, 8.666))
        p.addCurve(to: P(22.28, 9.353), control1: P(22.226, 9.253), control2: P(22.241, 9.312))
        p.addCurve(to: P(23.858, 12.244), control1: P(23.066, 10.15), control2: P(23.613, 11.152))
        p.addCurve(to: P(22.675, 17.384), control1: P(24.243, 14.145), control2: P(23.848, 15.859))
        p.addLine(to: P(22.493, 17.604))
        p.addCurve(to: P(19.559, 19.455), control1: P(21.716, 18.494), control2: P(20.696, 19.137))
        p.addCurve(to: P(19.451, 19.557), control1: P(19.509, 19.47), control2: P(19.468, 19.508))
        p.addCurve(to: P(18.464, 21.549), control1: P(19.196, 20.293), control2: P(18.94, 20.921))
        p.addCurve(to: P(13.516, 24), control1: P(17.265, 23.131), control2: P(15.502, 24.011))
        p.addCurve(to: P(9.306, 22.264), control1: P(11.933, 23.992), control2: P(10.53, 23.413))
        p.addCurve(to: P(9.166, 22.232), control1: P(9.268, 22.229), control2: P(9.215, 22.217))
        p.addCurve(to: P(7.562, 22.417), control1: P(8.648, 22.399), control2: P(8.126, 22.423))
        p.addCurve(to: P(4.967, 21.795), control1: P(6.661, 22.41), control2: P(5.773, 22.197))
        p.addCurve(to: P(2.821, 20.014), control1: P(4.123, 21.376), control2: P(3.388, 20.766))
        p.addCurve(to: P(2.27, 19.193), control1: P(2.618, 19.745), control2: P(2.417, 19.492))
        p.addCurve(to: P(1.775, 17.91), control1: P(2.067, 18.781), control2: P(1.902, 18.352))
        p.addCurve(to: P(1.758, 14.846), control1: P(1.509, 16.907), control2: P(1.503, 15.852))
        p.addCurve(to: P(1.766, 14.772), control1: P(1.766, 14.822), control2: P(1.769, 14.797))
        p.addCurve(to: P(1.729, 14.708), control1: P(1.761, 14.747), control2: P(1.748, 14.725))
        p.addCurve(to: P(0.349, 12.506), control1: P(1.113, 14.084), control2: P(0.641, 13.333))
        p.addCurve(to: P(0.016, 10.917), control1: P(0.155, 11.997), control2: P(0.043, 11.461))
        p.addCurve(to: P(0.204, 8.785), control1: P(-0.032, 10.201), control2: P(0.031, 9.482))
        p.addCurve(to: P(2.781, 5.292), control1: P(0.654, 7.301), control2: P(1.513, 6.137))
        p.addCurve(to: P(3.583, 4.854), control1: P(3.063, 5.104), control2: P(3.331, 4.958))
        p.addCurve(to: P(4.444, 4.55), control1: P(3.869, 4.734), control2: P(4.156, 4.634))
        p.addCurve(to: P(4.531, 4.463), control1: P(4.486, 4.538), control2: P(4.519, 4.505))
        p.addCurve(to: P(5.635, 2.31), control1: P(4.749, 3.678), control2: P(5.125, 2.945))
        p.addCurve(to: P(8.086, 0.457), control1: P(6.315, 1.464), control2: P(7.132, 0.846))
        p.closeSubpath()
        p.move(to: P(7.282, 8.307))
        p.addCurve(to: P(6.125, 7.992), control1: P(7.049, 7.9), control2: P(6.531, 7.759))
        p.addCurve(to: P(5.809, 9.149), control1: P(5.718, 8.224), control2: P(5.576, 8.742))
        p.addLine(to: P(7.503, 12.114))
        p.addLine(to: P(5.815, 14.962))
        p.addCurve(to: P(6.131, 16.094), control1: P(5.6, 15.363), control2: P(5.739, 15.862))
        p.addCurve(to: P(7.275, 15.826), control1: P(6.522, 16.326), control2: P(7.027, 16.207))
        p.addLine(to: P(9.215, 12.554))
        p.addCurve(to: P(9.222, 11.7), control1: P(9.371, 12.291), control2: P(9.373, 11.965))
        p.addLine(to: P(7.282, 8.307))
        p.closeSubpath()
        p.move(to: P(12.728, 14.547))
        p.addCurve(to: P(11.929, 15.395), control1: P(12.279, 14.574), control2: P(11.929, 14.945))
        p.addCurve(to: P(12.728, 16.242), control1: P(11.929, 15.844), control2: P(12.279, 16.215))
        p.addLine(to: P(17.576, 16.242))
        p.addCurve(to: P(18.384, 15.394), control1: P(18.028, 16.22), control2: P(18.384, 15.847))
        p.addCurve(to: P(17.576, 14.546), control1: P(18.384, 14.941), control2: P(18.028, 14.568))
        p.addLine(to: P(12.728, 14.546))
        p.closeSubpath()
        return p
    }
}
