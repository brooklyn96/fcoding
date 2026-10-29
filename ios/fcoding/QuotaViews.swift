import SwiftUI
import UIKit

// MARK: - Pane colours (facts/pane-ui-spec.md)

extension Color {
    static let paneBlue = Color(hex: 0x3B82F6)
    static let paneWarn = Color(hex: 0xEAB308)
    static let paneLow = Color(hex: 0xEF4444)
    static let paneTrack = Color(hex: 0x27272A)
    static let paneMuted = Color(hex: 0xA1A1AA)
    static let paneFg = Color(hex: 0xFAFAFA)
}

extension HomeLogic.Level {
    var color: Color {
        switch self {
        case .normal: return .paneBlue
        case .warn: return .paneWarn
        case .low: return .paneLow
        }
    }
}

enum QuotaLinks {
    static func usage(_ harness: String) -> URL? {
        URL(string: harness == "codex" ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")
    }
    static func status(_ harness: String) -> URL? {
        URL(string: harness == "codex" ? "https://status.openai.com" : "https://status.anthropic.com")
    }
    static func name(_ harness: String) -> String { harness == "codex" ? "Codex" : harness == "claude" ? "Claude" : harness }
}

// MARK: - Top card

/// Left: the box ring (tap = box info). Right: one quota account at a time, rolling to the next
/// every 4 s (tap = Hạn mức detail).
struct TopCard: View {
    @ObservedObject var home: HomeModel
    /// The main screen is on top and the app active: the tile may roll.
    let visible: Bool
    let onRing: () -> Void
    let onQuota: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            BoxRing(box: home.home?.box, offset: home.offset, onTap: onRing)
            Rectangle().fill(Color.hair).frame(width: 0.5, height: 88).accessibilityHidden(true)
            QuotaTile(home: home, visible: visible, onTap: onQuota)
        }
        .padding(16)
        .background(Color.grp, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 88 pt clock ring, 6 pt stroke: "Sleeps in" hh:mm while the box runs (yellow under 10 min),
/// "Wakes in" during the cooldown. It drains continuously (1 s linear glide per tick).
struct BoxRing: View {
    let box: HomeBox?
    /// Server clock minus phone clock (HomeModel.offset).
    let offset: TimeInterval
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            let r = HomeLogic.ring(box, now: ctx.date.addingTimeInterval(offset))
            Button(action: onTap) { ring(r) }
                .buttonStyle(.plain)
                .accessibilityLabel(label(r, now: ctx.date))
        }
    }

    private func colors(_ mode: HomeLogic.RingMode) -> (Color, Color, Color, Color) {
        switch mode {
        case .warn: return (.orangeTone, .yellowTone, Color(hex: 0xFFF4BF), .yellowTone)
        case .paused: return (Color(hex: 0x5E5CE6), Color(hex: 0xA5A3FF), Color(hex: 0xE4E3FF), Color(hex: 0xA5A3FF))
        default: return (.accentBlue, Color(hex: 0x64D2FF), Color(hex: 0xCFF3FF), .white)
        }
    }

    /// "88:88" must fit inside the ring minus 16 % padding on each side.
    private static let textWidth: CGFloat = 2 * 41 - 6 - 2 * 0.16 * 88
    /// Mockup layoutRing: the time takes the size at which "88:88" fits `textWidth`; 6 pt from
    /// the label baseline to the cap top of the digits; the pair is centred on its cap block.
    private static let labelFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    private static let timeFont: UIFont = {
        let base = UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        let width = ("88:88" as NSString).size(withAttributes: [.font: base]).width
        return UIFont.monospacedDigitSystemFont(ofSize: 23 * min(1, textWidth / max(1, width)), weight: .semibold)
    }()
    /// Text frames run ascender to descender: remove the label descent and the space above the digit caps.
    private static let textSpacing: CGFloat = 6 + labelFont.descender - (timeFont.ascender - timeFont.capHeight)
    /// Moves the frames so the label cap top to digit baseline block sits on the ring centre.
    private static let textOffset: CGFloat = (-timeFont.descender - (labelFont.ascender - labelFont.capHeight)) / 2

    private func ring(_ r: HomeLogic.Ring) -> some View {
        let c = colors(r.mode)
        let f: Double = r.mode == .unknown ? 0 : r.fraction
        return ZStack {
            Circle().stroke(Color(hex: 0x767680, alpha: 0.22), lineWidth: 6).padding(3)
            arc(f, mode: r.mode, g1: c.0, g2: c.1, core: c.2)
            texts(r, color: c.3)
        }
        .frame(width: 88, height: 88)
        .contentShape(Circle())
    }

    private func arc(_ f: Double, mode: HomeLogic.RingMode, g1: Color, g2: Color, core: Color) -> some View {
        let gradient = LinearGradient(colors: [g1, g2], startPoint: .topLeading, endPoint: .bottomTrailing)
        let angle = Angle.degrees(360 * f)
        return ZStack {
            Circle()
                .trim(from: 0, to: CGFloat(f))
                .stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            if mode != .unknown {
                ZStack {
                    Circle().fill(g2).frame(width: 8, height: 8).shadow(color: g2, radius: 2)
                    Circle().fill(core).frame(width: 3, height: 3)
                }
                .offset(y: -41)
                .rotationEffect(angle)
            }
        }
        // A change of state snaps; inside a state the ring glides 1 s per tick.
        .animation(reduceMotion ? nil : .linear(duration: 1), value: f)
        .id(mode)
    }

    private func texts(_ r: HomeLogic.Ring, color: Color) -> some View {
        let unknown = r.mode == .unknown
        let time = unknown ? "--:--" : HomeLogic.hhmm(r.seconds)
        return VStack(spacing: BoxRing.textSpacing) {
            Text(r.mode == .paused ? "Wakes in" : "Sleeps in")
                .font(Font(BoxRing.labelFont as CTFont))
                .tracking(0.22)
                .foregroundColor(.l2)
            Text(time)
                .font(Font(BoxRing.timeFont as CTFont))
                .foregroundColor(unknown ? Color.l2 : color)
                .lineLimit(1)
                .fixedSize()
        }
        .offset(y: BoxRing.textOffset)
    }

    private func label(_ r: HomeLogic.Ring, now: Date) -> String {
        let h = r.seconds / 3600, m = r.seconds % 3600 / 60
        let at = r.changeAt.map { HomeLogic.clock($0) } ?? ""
        switch r.mode {
        case .unknown: return "Chưa biết giờ box nghỉ. Chạm để xem giải thích."
        case .paused: return "Box đang nghỉ, đánh thức lại được sau \(h) giờ \(m) phút, lúc \(at). Chạm để xem giải thích."
        default: return "Box nghỉ sau \(h) giờ \(m) phút, lúc \(at), hoặc sớm hơn nếu rảnh 30 phút. Chạm để xem giải thích."
        }
    }
}

/// Reports the press state of a button (the tile stops rolling while a finger is on it).
private struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed = $0 }
    }
}

/// Mode A of the mockup: the outgoing page rolls up and fades over the first 60 %, the
/// incoming one rolls in from below and fades in over the last 70 %. Reduce Motion: crossfade.
private struct Roll: ViewModifier, Animatable {
    var p: Double
    let incoming: Bool
    let size: CGFloat
    let reduce: Bool
    var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        let t = incoming ? p : 1 - p
        let y: CGFloat = reduce ? 0 : (incoming ? (1 - t) * size : -t * size)
        let o: Double = reduce ? p : incoming ? (t < 0.3 ? 0 : (t - 0.3) / 0.7) : (t < 0.6 ? 1 - t / 0.6 : 0)
        return content.offset(y: y).opacity(o)
    }
}

struct QuotaTile: View {
    @ObservedObject var home: HomeModel
    let visible: Bool
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("quota.showUsed") private var showUsed = false
    @State private var index = 0
    @State private var hold = false
    @State private var lastMove = Date()

    private var accounts: [QuotaAccount] { home.home?.accounts ?? [] }
    private var current: Int { accounts.isEmpty ? 0 : index % accounts.count }
    /// On screen, app active, more than one account: the tile may roll.
    private var rolling: Bool { visible && scenePhase == .active && accounts.count > 1 }
    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.35) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.52)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(home.cacheLabel ?? (accounts.isEmpty ? "Hạn mức" : "Hạn mức · \(current + 1)/\(accounts.count)"))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.l3)
                }
                .font(.system(size: 11.5))
                .foregroundColor(.l2)
                .frame(height: 14)
                ZStack {
                    page.id(current).transition(transition)
                }
                // The saved copy from the last launch: dimmed until the live reply lands.
                .opacity(home.fromCache ? 0.45 : 1)
                .animation(.easeOut(duration: 0.25), value: home.fromCache)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 6 / 62),
                                           .init(color: .black, location: 56 / 62), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .background(Color(hex: 0x26262A), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                dots
            }
            .frame(height: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressReportingStyle(pressed: $hold))
        .onChange(of: hold) { down in
            // After a release the next roll waits at least 1.5 s.
            if !down { lastMove = max(lastMove, Date().addingTimeInterval(-2.5)) }
        }
        // One 4 s loop tied to the tile's place on screen, not to the struct: parent re-renders
        // (the 5 s overview poll) neither restart nor duplicate it. It ends off screen, in the
        // background and with one account.
        .task(id: rolling) {
            guard rolling else { return }
            lastMove = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, !hold, !accounts.isEmpty, Date().timeIntervalSince(lastMove) >= 4 else { continue }
                lastMove = Date()
                withAnimation(animation) { index = (current + 1) % accounts.count }
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var transition: AnyTransition {
        .asymmetric(insertion: .modifier(active: Roll(p: 0, incoming: true, size: 62, reduce: reduceMotion),
                                         identity: Roll(p: 1, incoming: true, size: 62, reduce: reduceMotion)),
                    removal: .modifier(active: Roll(p: 0, incoming: false, size: 62, reduce: reduceMotion),
                                       identity: Roll(p: 1, incoming: false, size: 62, reduce: reduceMotion)))
    }

    @ViewBuilder
    private var page: some View {
        if home.home == nil && !home.failed {
            VStack(alignment: .leading, spacing: 6) {
                ShimmerLine(width: 0.4, height: 10)
                ShimmerLine(width: 1, height: 8)
                ShimmerLine(width: 0.65, height: 8)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if accounts.isEmpty {
            Text(home.home == nil ? "Chưa tải được hạn mức" : "Chưa có tài khoản nào")
                .font(.system(size: 11.5))
                .foregroundColor(.l2)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            TilePage(account: accounts[current], stale: home.failed || accounts[current].stale, showUsed: showUsed,
                     now: home.serverNow())
        }
    }

    private var dots: some View {
        let n = accounts.count
        let width = CGFloat(n * 4 + max(0, n - 1) * 5)
        return ZStack {
            HStack(spacing: 5) {
                ForEach(0..<n, id: \.self) { _ in Circle().fill(Color.fill3).frame(width: 4, height: 4) }
            }
            if n > 0 {
                Capsule().fill(Color.l2).frame(width: 10, height: 4)
                    .offset(x: -width / 2 + CGFloat(current) * 9 + 2)
                    .animation(animation, value: current)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var accessibility: String {
        guard !accounts.isEmpty else { return "Hạn mức tài khoản. Chạm để xem chi tiết." }
        let a = accounts[current]
        var detail = "chưa có số liệu"
        let now = home.serverNow()
        if let w = HomeLogic.worst(a.shown, now: now) {
            detail = w.label + " " + HomeLogic.headline(w, showUsed: showUsed).lowercased() + ", "
                + HomeLogic.resetText(w, now: now, exact: false).lowercased()
        }
        return (home.cacheLabel.map { "Số liệu cũ, " + $0 + ". " } ?? "")
            + "Hạn mức tài khoản \(current + 1) trên \(accounts.count):\(a.email), \(a.plan ?? "")\(a.org.map { " " + $0 } ?? ""), \(detail). Chạm để xem chi tiết."
    }
}

/// One account on the tile: name + plan, the worst window, its bar and reset time.
private struct TilePage: View {
    let account: QuotaAccount
    let stale: Bool
    let showUsed: Bool
    /// Server clock.
    let now: Date

    var body: some View {
        let color = HarnessStyle.color(account.harness)
        let worst = HomeLogic.worst(account.shown, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(HomeLogic.shortMail(account.email)).lineLimit(1).truncationMode(.tail)
                if let plan = account.plan { Chip(text: plan, color: color, small: true) }
                if stale { Chip(text: "⚠ Cũ", color: .yellowTone, small: true) }
                if account.harness == "codex" && account.resetsAvailable > 0 {
                    Chip(text: "↻ \(account.resetsAvailable)", color: .greenTone, small: true)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(height: 16)
            Spacer(minLength: 0)
            if let w = worst {
                let pace = HomeLogic.pace(w, now: now)
                HStack(spacing: 6) {
                    Text(w.label).foregroundColor(.l2).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(HomeLogic.headline(w, showUsed: showUsed)).bold().monospacedDigit()
                        .foregroundColor(pace.level == .normal ? .white : pace.level.color)
                }
                .font(.system(size: 11.5))
                Spacer(minLength: 0)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.fill3)
                        Capsule().fill(pace.level.color).frame(width: g.size.width * HomeLogic.clampPercent(w.usedPercent) / 100)
                    }
                }
                .frame(height: 4)
                Spacer(minLength: 0)
                Text(HomeLogic.resetText(w, now: now, exact: false))
                    .font(.system(size: 11)).foregroundColor(.l2).lineLimit(1)
            } else {
                Text(account.rateLimited ? "Bị giới hạn tốc độ — nhà cung cấp yêu cầu chờ một lúc" : "Chưa có số liệu hạn mức")
                    .font(.system(size: 11)).foregroundColor(.paneMuted).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var small = false

    var body: some View {
        Text(text)
            .font(.system(size: small ? 10 : 11, weight: .bold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, small ? 5 : 6)
            .padding(.vertical, small ? 2 : 4)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
    }
}

/// Pane skeleton line with the 1.4 s shimmer (still under Reduce Motion).
struct ShimmerLine: View {
    /// Fraction of the available width.
    let width: CGFloat
    var height: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(LinearGradient(colors: [.paneTrack, Color(hex: 0x3F3F46), .paneTrack],
                                     startPoint: UnitPoint(x: phase, y: 0.5), endPoint: UnitPoint(x: phase + 1, y: 0.5)))
                .frame(width: g.size.width * width)
        }
        .frame(height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Touch tooltips (one bubble for the whole quota screen)

struct TipItem: Equatable {
    let id: String
    let text: String
    /// Horizontal point inside the anchor (the trend day); nil = its centre.
    var x: CGFloat? = nil
    var token = UUID()
}

private struct TipAnchor {
    let text: String
    let x: CGFloat?
    let bounds: Anchor<CGRect>
}

private struct TipKey: PreferenceKey {
    static var defaultValue: [TipAnchor] = []
    static func reduce(value: inout [TipAnchor], nextValue: () -> [TipAnchor]) { value += nextValue() }
}

private extension View {
    /// Marks this view as the anchor of `tip` when its id matches.
    func tipAnchor(_ id: String, _ tip: TipItem?) -> some View {
        anchorPreference(key: TipKey.self, value: .bounds) { a in
            tip?.id == id ? [TipAnchor(text: tip?.text ?? "", x: tip?.x, bounds: a)] : []
        }
    }
}

private struct TipBubble: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TipKey.self) { anchors in
            GeometryReader { g in
                if let a = anchors.last {
                    let r = g[a.bounds]
                    let cx = a.x.map { r.minX + $0 } ?? r.midX
                    let above = r.minY > 70
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        Text(a.text)
                            .font(.system(size: 12))
                            .foregroundColor(.paneFg)
                            .lineSpacing(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(Color(hex: 0x3F3F46), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                            .alignmentGuide(.leading) { d in -max(8, min(g.size.width - d.width - 8, cx - d.width / 2)) }
                            .alignmentGuide(.top) { d in -(above ? r.minY - 8 - d.height : r.maxY + 8) }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Hạn mức detail

/// All accounts per Pane: the spend donut, then per harness one card per account (bars with the
/// pace colour, trend sparkline, spend rows, links, Reset). The header scrolls with the content.
struct QuotaDetailView: View {
    @ObservedObject var home: HomeModel
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("quota.showUsed") private var showUsed = false
    @AppStorage("quota.exact") private var exact = false
    @State private var tip: TipItem?
    @State private var expanded: Set<String> = []
    @State private var resetTarget: QuotaAccount?
    @State private var toast: String?

    private var accounts: [QuotaAccount] { home.home?.accounts ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                nav
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 48)
            }
            .contentShape(Rectangle())
            .onTapGesture { tip = nil }
            .modifier(TipBubble())
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .refreshable { await home.refresh(app) }
        .overlay(alignment: .top) { StatusBarCover() }
        .overlay(alignment: .top) { ToastView(text: $toast) }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)   // keeps the refresh spinner below the status bar
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await home.load(app)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .task(id: tip) {
            guard let t = tip else { return }
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if tip == t { tip = nil }
        }
        .sheet(item: $resetTarget) { a in
            if a.harness == "codex" {
                CodexResetSheet(account: a, home: home) { email in
                    // HomeModel reloads /api/home itself (now and after 12 s).
                    toast = "Đã reset \(email)"
                }
                .environmentObject(app)
            } else {
                ClaudeResetSheet(account: a)
            }
        }
    }

    /// Back button, title, and an empty side as wide as the back button: the title stays centred
    /// and never runs under the button (it shrinks first).
    private var nav: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").scaledFont(20, weight: .semibold)
                    Text("FCode").scaledFont(17).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundColor(.accentBlue)
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quay lại FCode")
            .frame(width: 104, alignment: .leading)
            Text("Hạn mức")
                .scaledFont(17, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: 104, height: 1)
        }
        .frame(minHeight: 44)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    @ViewBuilder
    private var content: some View {
        if home.home == nil {
            Text(home.failed ? "Chưa tải được hạn mức." : "Đang tải hạn mức…")
                .scaledFont(14)
                .padding(.bottom, 6)
            if !home.failed {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        ShimmerLine(width: 0.4, height: 12)
                        ShimmerLine(width: 1)
                        ShimmerLine(width: 0.65)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .background(Color(hex: 0x18181B), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.paneTrack))
                    .padding(.bottom, 10)
                }
            }
        } else {
            summaryLine.padding(.bottom, 6)
            // The saved copy from the last launch: dimmed until the live reply lands.
            Group {
                SpendDonut(accounts: accounts, totals: home.home?.totals, tip: $tip)
                ForEach(harnesses, id: \.self) { h in group(h) }
            }
            .opacity(home.fromCache ? 0.45 : 1)
            .animation(.easeOut(duration: 0.25), value: home.fromCache)
            Text(footer)
                .scaledFont(12).foregroundColor(.paneMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 14).padding(.bottom, 4)
            Text("Dựa trên Pane (MIT) · OpenUsage")
                .scaledFont(11).foregroundColor(.l3)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
    }

    private var harnesses: [String] {
        var seen: [String] = []
        for a in accounts where !seen.contains(a.harness) { seen.append(a.harness) }
        return seen.sorted { ($0 == "claude" ? 0 : $0 == "codex" ? 1 : 2) < ($1 == "claude" ? 0 : $1 == "codex" ? 1 : 2) }
    }

    private var footer: String {
        guard let at = home.loadedAt else { return "Tự làm mới mỗi phút" }
        let m = Int(Date().timeIntervalSince(at) / 60)
        return (m < 1 ? "Cập nhật vừa xong" : "Cập nhật \(m) phút trước") + " · tự làm mới mỗi phút"
    }

    private var summaryLine: some View {
        let now = home.serverNow()
        let all = accounts.filter { !$0.shown.isEmpty }.flatMap(\.shown)
        let lo = all.max { HomeLogic.clampPercent($0.usedPercent) < HomeLogic.clampPercent($1.usedPercent) }
        var line = Text("\(accounts.count) tài khoản")
        if let lo = lo {
            let pace = HomeLogic.pace(lo, now: now)
            line = line + Text(" · ít nhất còn ")
                + Text("\(100 - Int(HomeLogic.clampPercent(lo.usedPercent).rounded()))%")
                    .foregroundColor(pace.level == .normal ? .primary : pace.level.color)
                + Text(" (\(lo.label))")
        }
        if home.failed || accounts.contains(where: \.stale) {
            line = line + Text(" · ") + Text("⚠ Cũ").foregroundColor(.paneWarn)
        }
        if let saved = home.cacheLabel {
            line = line + Text(" · ") + Text(saved).foregroundColor(.paneMuted)
        }
        return line.scaledFont(14)
    }

    private func group(_ h: String) -> some View {
        let accs = accounts.filter { $0.harness == h }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HarnessBadge(harness: h)
                Text("\(QuotaLinks.name(h)) · \(accs.count) tài khoản")
            }
            .scaledFont(12.5, weight: .semibold)
            .foregroundColor(.l2)
            .padding(.top, 4).padding(.bottom, 6)
            ForEach(accs) { a in
                AccountCard(account: a, stale: home.failed || a.stale, now: home.serverNow(), showUsed: $showUsed, exact: $exact,
                            expanded: Binding(get: { expanded.contains(a.id) },
                                              set: { if $0 { expanded.insert(a.id) } else { expanded.remove(a.id) } }),
                            tip: $tip, onReset: { resetTarget = a })
            }
        }
    }
}

/// One account (Pane card): head row, then the panel with the windows, trend, spend and links.
private struct AccountCard: View {
    let account: QuotaAccount
    let stale: Bool
    /// Server clock.
    let now: Date
    @Binding var showUsed: Bool
    @Binding var exact: Bool
    @Binding var expanded: Bool
    @Binding var tip: TipItem?
    let onReset: () -> Void
    @Environment(\.openURL) private var openURL

    private var error: String? {
        guard account.shown.isEmpty else { return nil }
        return account.rateLimited ? "Bị giới hạn tốc độ — nhà cung cấp yêu cầu chờ một lúc" : "Chưa có số liệu hạn mức"
    }

    private var staleText: String {
        "Lần làm mới gần nhất bị lỗi.\n"
            + (account.rateLimited ? "Nhà cung cấp đang giới hạn tốc độ; box chờ đúng thời gian họ yêu cầu rồi tự thử lại."
                                   : "Không lấy được số mới từ nhà cung cấp hoặc từ box.")
            + "\nĐang hiện số liệu tốt gần nhất."
    }

    var body: some View {
        let h = account.harness
        let canReset = error == nil && (h == "claude" || account.canCodexReset)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HarnessGlyph(harness: h, size: 16).foregroundColor(HarnessStyle.color(h))
                Text(HomeLogic.shortMail(account.email))
                    .scaledFont(14, weight: .semibold)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text([account.plan, account.org].compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(11)
                    .foregroundColor(.paneMuted)
                    .lineLimit(1)
                if stale {
                    Button { tip = TipItem(id: "stale." + account.id, text: staleText) } label: {
                        Text("⚠ Cũ").scaledFont(10.5).foregroundColor(.paneWarn)
                            .frame(minHeight: 44).padding(.horizontal, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tipAnchor("stale." + account.id, tip)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if canReset {
                    Button(action: onReset) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise").scaledFont(11, weight: .bold)
                            Text("Reset")
                        }
                        .scaledFont(13, weight: .semibold)
                        .foregroundColor(.accentBlue)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Color.fill3, in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("Reset \(account.email)" + (h == "claude" ? ": mở trang chính thức để dùng lượt reset được tặng"
                                                                                   : ": dùng 1 lượt reset ngay trong app"))
                }
            }
            .frame(minHeight: 44)
            .padding(.leading, 2)
            panel
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.top, 7).padding(.bottom, 3)
        .padding(.bottom, 6)
        .opacity(error == nil ? 1 : 0.7)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder
    private var panel: some View {
        if let error = error {
            Text(error).scaledFont(11).foregroundColor(.paneMuted).padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(account.shown.indices, id: \.self) { i in
                    MetricRow(window: account.shown[i], id: account.id + ".\(i)", now: now, showUsed: $showUsed, exact: $exact, tip: $tip)
                }
                if let daily = account.spend?.daily30, !daily.isEmpty {
                    TrendRow(days: daily, id: account.id, tip: $tip)
                }
                SpendRows(spend: account.spend, weekly: account.hasWeekly)
                    .padding(.top, 2).padding(.bottom, 6)
                HStack(spacing: 6) {
                    link("Trang Usage", QuotaLinks.usage(account.harness))
                    Text("·").scaledFont(11).foregroundColor(.paneTrack)
                    link("Trạng thái", QuotaLinks.status(account.harness))
                }
                if account.harness == "codex" {
                    if expanded {
                        HStack {
                            Text("Lượt reset").fontWeight(.semibold)
                            Spacer()
                            Text(account.resetsAvailable > 0 ? "\(account.resetsAvailable) lượt còn dùng" : "Chưa có lượt")
                                .foregroundColor(.paneFg)
                        }
                        .scaledFont(12)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { Rectangle().fill(Color.paneTrack).frame(height: 0.5) }
                    }
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "Ẩn bớt" : "Thêm")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").scaledFont(9, weight: .semibold)
                        }
                        .scaledFont(11)
                        .foregroundColor(.paneMuted)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func link(_ title: String, _ url: URL?) -> some View {
        Button { if let url = url { openURL(url) } } label: {
            Text(title).scaledFont(11).foregroundColor(.paneMuted)
                .padding(.horizontal, 4).frame(minHeight: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pane progress row: label + pace note, the 6 pt bar (used %, pace colour, even-pace tick),
/// then the headline (tap: left / used) and the reset text (tap: countdown / exact time).
private struct MetricRow: View {
    let window: QuotaWindow
    let id: String
    /// Server clock.
    let now: Date
    @Binding var showUsed: Bool
    @Binding var exact: Bool
    @Binding var tip: TipItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pace = HomeLogic.pace(window, now: now)
        let used = HomeLogic.clampPercent(window.usedPercent)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(window.label).scaledFont(13, weight: .semibold).foregroundColor(.paneFg)
                Spacer(minLength: 0)
                if !pace.note.isEmpty {
                    HStack(spacing: 4) {
                        if pace.flame { Image(systemName: "flame.fill").scaledFont(10) }
                        Text(pace.note)
                    }
                    .scaledFont(12)
                    .foregroundColor(pace.level == .low ? .paneLow : pace.level == .warn ? .paneWarn : .paneMuted)
                    .lineLimit(1)
                }
            }
            .padding(.bottom, 4)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.paneTrack)
                    Capsule().fill(pace.level.color).frame(width: g.size.width * used / 100)
                    if pace.tick > 1 && pace.tick < 99 {
                        RoundedRectangle(cornerRadius: 1).fill(Color.paneFg).opacity(0.55)
                            .frame(width: 2, height: 10)
                            .offset(x: g.size.width * pace.tick / 100 - 1)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: used)
            }
            .frame(height: 6)
            .tipAnchor("bar." + id, tip)
            // Touch area: 10 pt above the 6 pt bar, 4 pt below (where the toggles begin).
            .padding(.top, 10).padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { if !pace.title.isEmpty { tip = TipItem(id: "bar." + id, text: pace.title) } }
            .padding(.top, -10).padding(.bottom, -4)
            .accessibilityElement()
            .accessibilityLabel("\(window.label): đã dùng \(Int(used.rounded()))%" + (pace.note.isEmpty ? "" : ", " + pace.note))
            HStack(spacing: 8) {
                // 30 pt tall hit areas from the end of the bar's touch area to the end of the row.
                Button { showUsed.toggle() } label: {
                    Text(HomeLogic.headline(window, showUsed: showUsed)).monospacedDigit().foregroundColor(.paneFg)
                        .frame(minHeight: 30).contentShape(Rectangle())
                }
                Spacer(minLength: 0)
                Button { exact.toggle() } label: {
                    Text(HomeLogic.resetText(window, now: now, exact: exact)).foregroundColor(.paneMuted)
                        .frame(minHeight: 30).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .scaledFont(12)
            .lineLimit(1)
            .padding(.top, 4)
        }
        .padding(.top, 10)
    }
}

/// "Xu hướng dùng": 30 day bars (Pane: slot/2 wide, non-zero >= 2 of 18 units, zero = 1 unit,
/// no axes). Touch or drag across the bars to read one day.
private struct TrendRow: View {
    let days: [DailySpend]
    let id: String
    @Binding var tip: TipItem?
    @State private var active: Int?

    var body: some View {
        let values = days.suffix(30).map(\.tokens)
        let list = Array(days.suffix(30))
        let peak = values.max() ?? 0
        let peakDay = list.first { $0.tokens == peak }
        let summary = "\(values.count) ngày qua (\(dm(list.first?.date)) – \(dm(list.last?.date))) · cao nhất "
            + HomeLogic.tokens(peak) + " ngày " + dm(peakDay?.date) + " · từ log trên máy"
        HStack(spacing: 10) {
            Button { tip = TipItem(id: "trend." + id, text: summary) } label: {
                Text("Xu hướng dùng").scaledFont(13, weight: .semibold).foregroundColor(.paneFg)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .tipAnchor("trend." + id, tip)
            Spacer(minLength: 0)
            GeometryReader { g in
                Canvas { ctx, size in
                    let n = max(1, values.count), slot = size.width / CGFloat(n), sy = size.height / 18
                    for (i, v) in values.enumerated() {
                        let h = v > 0 ? max(2, v / max(peak, 1) * 16) : 1
                        let rect = CGRect(x: CGFloat(i) * slot + slot / 4, y: (18 - h) * sy, width: slot / 2, height: h * sy)
                        let color: Color = i == active ? Color(hex: 0x93C5FD) : v > 0 ? .paneBlue : .paneTrack
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { e in
                    let n = list.count
                    guard n > 0 else { return }
                    let k = max(0, min(n - 1, Int(e.location.x / g.size.width * CGFloat(n))))
                    active = k
                    let text = dm(list[k].date) + " · " + (list[k].tokens > 0 ? HomeLogic.tokens(list[k].tokens) : "không dùng")
                    if tip?.text != text {
                        tip = TipItem(id: "day." + id, text: text, x: (CGFloat(k) + 0.5) / CGFloat(n) * g.size.width)
                    }
                })
                .tipAnchor("day." + id, tip)
            }
            .frame(width: 168, height: 22)
            .accessibilityElement()
            .accessibilityLabel(summary)
        }
        .frame(minHeight: 44)
        .onChange(of: tip) { t in if t?.id != "day." + id { active = nil } }
    }

    /// "2026-10-26" -> "26/10".
    private func dm(_ date: String?) -> String {
        guard let parts = date?.split(separator: "-"), parts.count == 3 else { return "?" }
        return "\(parts[2])/\(parts[1])"
    }
}

/// Pane spend rows: "Hôm nay / Hôm qua / 30 ngày" and, with a weekly window, "Ước tính tuần".
private struct SpendRows: View {
    let spend: Spend?
    let weekly: Bool

    private var rows: [(String, SpendAmount?, Bool)] {
        var rows: [(String, SpendAmount?, Bool)] = [("Hôm nay", spend?.today, false), ("Hôm qua", spend?.yesterday, false),
                                                    ("30 ngày", spend?.last30, false)]
        if weekly, let w = spend?.weeklyEstimate { rows.append(("Ước tính tuần", w, true)) }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(rows[i].0).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(rows[i].1.map { HomeLogic.spendLine($0, approx: rows[i].2) } ?? "—")
                        .monospacedDigit()
                        .foregroundColor(.paneFg)
                        .lineLimit(1)
                }
                .scaledFont(12)
                .padding(.top, i == 0 ? 6 : 2)
                .padding(.bottom, 6)
            }
        }
    }
}

/// "Tổng chi phí": donut per harness over 30 days (annular wedges, outer 44 / inner 30 on a
/// 96 box drawn at 112 pt), a legend, and the total spend rows.
private struct SpendDonut: View {
    let accounts: [QuotaAccount]
    let totals: HomeTotals?
    @Binding var tip: TipItem?

    private var wedges: [HomeLogic.Wedge] {
        var byHarness: [(key: String, name: String, usd: Double)] = []
        if let list = totals?.byHarness, !list.isEmpty {
            byHarness = list.map { ($0.harness, QuotaLinks.name($0.harness), $0.usd) }
        } else {
            for a in accounts {
                let v = a.spend?.last30?.usd ?? 0
                if let i = byHarness.firstIndex(where: { $0.key == a.harness }) { byHarness[i].usd += v }
                else { byHarness.append((a.harness, QuotaLinks.name(a.harness), v)) }
            }
        }
        return HomeLogic.donut(byHarness)
    }

    private func color(_ key: String) -> Color { key == "other" ? Color(hex: 0x71717A) : HarnessStyle.color(key) }

    var body: some View {
        let ws = wedges
        let total = ws.reduce(0) { $0 + $1.usd }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tổng chi phí").scaledFont(13, weight: .semibold).foregroundColor(.paneFg)
                Spacer()
                Text("\(accounts.count) tài khoản").scaledFont(12).foregroundColor(.paneMuted)
            }
            .frame(minHeight: 36)
            HStack(spacing: 16) {
                ZStack {
                    if ws.isEmpty {
                        Circle().stroke(Color.paneTrack, lineWidth: 14 * 112 / 96).padding(11 * 112 / 96)
                    }
                    ForEach(ws.indices, id: \.self) { i in
                        Wedge(start: ws[i].start, end: ws[i].end)
                            .fill(color(ws[i].key))
                            .onTapGesture { tip = TipItem(id: "wedge", text: wedgeTip(ws[i], total)) }
                    }
                    VStack(spacing: 0) {
                        // Inside the fixed 70 pt hole: fixed sizes.
                        Text(HomeLogic.usd(total)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("30 ngày").font(.system(size: 10.5)).foregroundColor(.paneMuted)
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: 112, height: 112)
                .tipAnchor("wedge", tip)
                .accessibilityElement()
                .accessibilityLabel("Tổng chi phí 30 ngày " + HomeLogic.usd(total))
                VStack(alignment: .leading, spacing: 0) {
                    if ws.isEmpty { Text("Chưa có chi phí").scaledFont(13).frame(minHeight: 36) }
                    ForEach(ws.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Circle().fill(color(ws[i].key)).frame(width: 8, height: 8)
                            Text(ws[i].name)
                            Spacer(minLength: 0)
                            Text(HomeLogic.usd(ws[i].usd)).fontWeight(.semibold).monospacedDigit()
                        }
                        .scaledFont(13)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                        .onTapGesture { tip = TipItem(id: "legend.\(i)", text: ws[i].name + " · " + HomeLogic.usd(ws[i].usd)) }
                        .tipAnchor("legend.\(i)", tip)
                    }
                }
            }
            .padding(.top, 8)
            SpendRows(spend: totals?.spend ?? summed, weekly: accounts.contains(where: \.hasWeekly))
                .padding(.top, 6)
                .overlay(alignment: .top) { Rectangle().fill(Color.paneTrack).frame(height: 0.5) }
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10).padding(.bottom, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 4).padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func wedgeTip(_ w: HomeLogic.Wedge, _ total: Double) -> String {
        let share = total > 0 ? Int((w.usd / total * 100).rounded()) : 0
        return "\(w.name) · \(HomeLogic.usd(w.usd)) · \(share)%" + (w.parts.isEmpty ? "" : " (\(w.parts))")
    }

    /// Sum of the accounts' spend when the server sends no totals.
    private var summed: Spend? {
        let list = accounts.compactMap(\.spend)
        guard !list.isEmpty else { return nil }
        func add(_ k: KeyPath<Spend, SpendAmount?>) -> SpendAmount? {
            let parts = list.compactMap { $0[keyPath: k] }
            return parts.isEmpty ? nil : SpendAmount(usd: parts.reduce(0) { $0 + $1.usd }, tokens: parts.reduce(0) { $0 + $1.tokens })
        }
        var s = list[0]
        s.today = add(\.today)
        s.yesterday = add(\.yesterday)
        s.last30 = add(\.last30)
        s.weeklyEstimate = add(\.weeklyEstimate)
        return s
    }
}

/// Annular wedge (outer 44, inner 30 of a 96 box), angles clockwise from 12 o'clock.
private struct Wedge: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 96
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a0 = Angle(radians: start - .pi / 2), a1 = Angle(radians: end - .pi / 2)
        var p = Path()
        p.addArc(center: c, radius: 44 * s, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: 30 * s, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Reset sheets

/// Codex: the reset runs in the app through POST /api/codex-reset. The request id is minted once
/// for this confirm and reused on every "Thử lại".
struct CodexResetSheet: View {
    let account: QuotaAccount
    @ObservedObject var home: HomeModel
    let onDone: (String) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var requestId = UUID().uuidString
    @State private var running = false
    @State private var done = false
    @State private var stopped = false
    @State private var tried = false
    @State private var errorText: String?
    /// errorText is a status (pending, no answer yet), not an error.
    @State private var info = false

    var body: some View {
        SheetScaffold {
            SheetHeader(title: "Reset Codex", left: ("Huỷ", { dismiss() }))
                .disabled(running)
            (Text("Dùng 1 lượt reset cho ") + Text(account.email).foregroundColor(.white)
                + Text("? Còn \(account.resetsAvailable) lượt."))
                .sheetBody()
            Text(errorText ?? " ")
                .scaledFont(13)
                .foregroundColor(info ? .l2 : .redTone)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .padding(.vertical, 6)
                .accessibilityHidden(errorText == nil)
                .onChange(of: errorText) { t in
                    // The mockup's error is role="alert": VoiceOver reads it when it appears.
                    if let t = t { UIAccessibility.post(notification: .announcement, argument: t) }
                }
            Button(action: run) {
                HStack(spacing: 6) {
                    if running { ProgressView().tint(.white) }
                    Text(running ? "Đang reset…" : done ? "Đã reset ✓" : tried && !stopped ? "Thử lại" : "Dùng lượt reset")
                }
            }
            .buttonStyle(PrimaryButtonStyle(fill: done ? .greenTone : .accentBlue, text: done ? .black : .white))
            .disabled(running || done || stopped)
        }
        .interactiveDismissDisabled(running)
    }

    private func run() {
        guard !running else { return }
        running = true
        errorText = nil
        Task {
            let r = await home.codexReset(account, requestId: requestId, app: app)
            running = false
            tried = true
            if r.done {
                done = true
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
                onDone(account.email)
            } else {
                stopped = !r.canRetry
                info = r.info
                errorText = r.text
            }
        }
    }
}

/// Claude: never reset from the app (ban risk); open the official usage page after a confirm.
struct ClaudeResetSheet: View {
    let account: QuotaAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let url = QuotaLinks.usage("claude")
        SheetScaffold {
            SheetHeader(title: "Reset hạn mức", left: ("Huỷ", { dismiss() }))
            (Text("Mở trang Usage của tài khoản ") + Text(account.email).bold().foregroundColor(.white)
                + Text(" để bấm ") + Text("Reset for free").bold().foregroundColor(.white) + Text("?"))
                .sheetBody()
            (Text("Hãy đăng nhập đúng tài khoản ") + Text(account.email).bold()
                + Text(" trên web. App không tự reset được, chỉ trang chính thức mới có nút này (claude.ai trên web hoặc app Desktop)."))
                .sheetNote()
            Text(url?.absoluteString ?? "")
                .scaledFont(12, design: .monospaced)
                .foregroundColor(.l2)
                .padding(.bottom, 10)
            Button("Mở trang Usage") {
                if let url = url { openURL(url) }
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

// MARK: - Swipe back with a hidden navigation bar

/// The main screen and the quota detail hide the navigation bar (their headers scroll), which
/// also turns off the edge swipe back. Placed once on the main screen (alive for the whole
/// stack), it keeps the swipe on whenever there is a screen to go back to.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
