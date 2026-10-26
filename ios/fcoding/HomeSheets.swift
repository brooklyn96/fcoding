import SwiftUI
import UIKit

// MARK: - Sheet chrome (mockup .sheet: header row that scrolls, 16 pt sides)

/// Bottom sheet body: scrolls (header included), no scroll indicator.
struct SheetScaffold<Content: View>: View {
    var large = false
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .presentationDetents(large ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Title in the middle, a 72 pt text button on either side (dimmed when disabled).
struct SheetHeader: View {
    let title: String
    var left: (String, () -> Void)? = nil
    var right: (String, () -> Void)? = nil
    var rightBold = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            side(left, alignment: .leading, bold: false)
            Text(title)
                .scaledFont(17, weight: .semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            side(right, alignment: .trailing, bold: rightBold)
        }
        .frame(minHeight: 44)
        .padding(.bottom, 6)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func side(_ item: (String, () -> Void)?, alignment: Alignment, bold: Bool) -> some View {
        Group {
            if let item = item {
                Button(action: item.1) {
                    Text(item.0)
                        .scaledFont(16, weight: bold ? .semibold : .regular)
                        .foregroundColor(.accentBlue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isEnabled ? 1 : 0.4)
            }
        }
        .frame(width: 72, alignment: alignment)
    }
}

/// Full-width 44 pt button (mockup .btn.block).
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = .accentBlue
    var text: Color = .white
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(16, weight: .semibold)
            .foregroundColor(text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

extension View {
    /// Sheet paragraph: 14.5 pt secondary text.
    func sheetBody() -> some View {
        scaledFont(14.5).foregroundColor(.l2).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
    }

    /// Grouped note box (mockup .now).
    func sheetNote() -> some View {
        scaledFont(14)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 14)
    }
}

// MARK: - Dynamic Type

/// The mockup's point size, scaled with the user's text size like the nearest text style.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        let style: Font.TextStyle = size >= 16 ? .body : size >= 14 ? .subheadline : size >= 13 ? .footnote
            : size >= 12 ? .caption : .caption2
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight, design: design)) }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

// MARK: - Box info (tap on the ring)

struct BoxInfoSheet: View {
    let box: HomeBox?
    /// Server clock minus phone clock (HomeModel.offset).
    let offset: TimeInterval
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let maxRun = Int(box?.maxRunMinutes ?? 480), idle = Int(box?.idlePauseMinutes ?? 30), cool = Int(box?.cooldownMinutes ?? 10)
        SheetScaffold(large: true) {
            SheetHeader(title: "Box coder tự nghỉ", right: ("Xong", { dismiss() }))
            Text("Để tiết kiệm, box coder tự nghỉ:").sheetBody()
            VStack(alignment: .leading, spacing: 0) {
                step(maxRun % 60 == 0 ? "\(maxRun / 60)h" : "\(maxRun)′", Color(hex: 0xE5C07B),
                     Text("Khi đã chạy đủ ") + Text("\(hours(maxRun))").bold(),
                     "Tính từ lúc box bật lên. Đồng hồ đếm ngược tới mốc này.")
                step("\(idle)′", Color(hex: 0xE5C07B),
                     Text("Hoặc ") + Text("sớm hơn").bold() + Text(", nếu rảnh \(idle) phút"),
                     "Không phiên nào làm gì trong \(idle) phút. Mốc này app không đếm được.")
                step("\(cool)′", Color(hex: 0xA5A3FF),
                     Text("Sau đó nghỉ ") + Text("\(cool) phút").bold() + Text(", rồi ") + Text("tự dậy").bold(),
                     "Bạn không cần làm gì.")
            }
            .padding(.bottom, 16)
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                now(HomeLogic.ring(box, now: ctx.date.addingTimeInterval(offset)), maxRun: maxRun, idle: idle).sheetNote()
            }
            Button("Đã hiểu") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func hours(_ minutes: Int) -> String { minutes % 60 == 0 ? "\(minutes / 60) giờ" : "\(minutes) phút" }

    private func step(_ tag: String, _ color: Color, _ title: Text, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(tag)
                .scaledFont(13, weight: .bold)
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .dynamicTypeSize(...DynamicTypeSize.large)
            VStack(alignment: .leading, spacing: 2) {
                title.scaledFont(14.5)
                Text(detail).scaledFont(13).foregroundColor(.l2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func now(_ r: HomeLogic.Ring, maxRun: Int, idle: Int) -> Text {
        let at = Text(r.changeAt.map { HomeLogic.clock($0) } ?? "").bold().monospacedDigit()
        let left = Text(HomeLogic.hms(r.seconds)).bold().monospacedDigit()
        switch r.mode {
        case .unknown:
            return Text("Bây giờ: chưa biết giờ box nghỉ.")
        case .paused:
            return Text("Bây giờ: box đang nghỉ, tự dậy lúc ") + at + Text(" (sau ") + left + Text(").")
        default:
            return Text("Bây giờ: box sẽ nghỉ lúc ") + at + Text(", sau ") + left
                + Text(" (chạy đủ \(maxRun) phút), hoặc sớm hơn nếu rảnh \(idle) phút.")
        }
    }
}

// MARK: - Hướng dẫn (the (?) button): one exclusive accordion, numbered steps per area

struct HomeGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = 0

    private let topics: [(title: String, color: UInt32, steps: [String])] = [
        ("Phiên", 0x0A84FF, [
            "Bấm nút nổi **+** ở góc dưới bên phải để tạo phiên mới.",
            "Chọn dự án, rồi chọn **omp**, **claude** hoặc **codex**.",
            "Chạm vào một phiên để mở. Thẻ **Cần bạn** đang chờ bạn trả lời: bấm **y** / **n** ngay trên thẻ.",
            "Vuốt một phiên sang trái để **Đổi tên** hoặc **Đóng**.",
            "Kéo danh sách xuống để làm mới.",
        ]),
        ("Vòng giờ box", 0x64D2FF, [
            "**Sleeps in**: box còn chạy bao lâu rồi tự nghỉ (tối đa 8 giờ, sớm hơn nếu rảnh 30 phút).",
            "Vòng chuyển **vàng** khi còn dưới 10 phút.",
            "**Wakes in**: box đang nghỉ 10 phút và sẽ tự dậy.",
            "Chạm vào vòng để xem giờ chính xác.",
        ]),
        ("Hạn mức", 0xD97757, [
            "Ô hạn mức tự chuyển qua từng tài khoản mỗi 4 giây. Giữ ngón tay trên ô để dừng.",
            "Chạm vào ô để xem chi tiết từng tài khoản.",
            "**Codex**: bấm **Reset** để dùng lượt reset ngay trong app.",
            "**Claude**: bấm **Reset** để mở trang chính thức, rồi bấm **Reset for free** ở đó.",
        ]),
        ("Thêm iPhone bằng mã QR", 0x30D158, [
            "Trên iPhone này: **⚙ Cài đặt** → **Thêm thiết bị (mã QR)** → **Tạo mã**.",
            "Trên iPhone mới: mở **Camera** và hướng vào mã, rồi gõ mã 6 số đang hiện.",
            "Mã dùng 1 lần, hết hạn sau 2 phút. Hết hạn thì bấm **Tạo mã mới**.",
            "Không quét được: bấm **Gửi link** để gửi sang iPhone mới.",
        ]),
        ("Dự án", 0xA78BFA, [
            "Mỗi thẻ dự án cho biết số **PR** đang mở, kết quả **checks** và lần **deploy** gần nhất.",
            "Chạm vào thẻ để chỉ xem phiên của dự án đó; chạm **Tất cả** để xem lại hết.",
            "Giữ lâu một thẻ, hoặc bấm **…**, để mở phiên mới cho dự án đó.",
            "Dòng **Staging** cho biết box staging đang chạy hay đang nghỉ; bấm **Bật** để bật nó.",
            "Trong **…** có **Phiên omp gần đây** (cả phiên từ laptop): bấm **Tiếp tục** để làm tiếp trên box.",
            "Thêm dự án: bấm **+** → **Thêm dự án**, dán link repo GitHub hoặc chọn repo trong danh sách, rồi bấm **Thêm**.",
        ]),
    ]

    var body: some View {
        SheetScaffold(large: true) {
            SheetHeader(title: "Hướng dẫn", right: ("Xong", { dismiss() }))
            VStack(spacing: 0) {
                ForEach(topics.indices, id: \.self) { i in
                    if i > 0 { Rectangle().fill(Color.hair).frame(height: 0.5) }
                    topic(i)
                }
            }
            .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func topic(_ i: Int) -> some View {
        let t = topics[i], color = Color(hex: t.color), isOpen = open == i
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { open = isOpen ? -1 : i }
            } label: {
                HStack(spacing: 12) {
                    Text("\(i + 1)")
                        .scaledFont(15, weight: .bold)
                        .foregroundColor(color)
                        .frame(width: 34, height: 34)
                        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .accessibilityHidden(true)
                    Text(t.title).scaledFont(15, weight: .semibold).foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.l3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Chạm để thu gọn" : "Chạm để mở")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(t.steps.indices, id: \.self) { k in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(k + 1).").monospacedDigit()
                            Text(HomeGuideView.styled(t.steps[k]))
                        }
                        .scaledFont(14.5)
                        .foregroundColor(.l2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 58).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
    }

    /// "**x**" parts in white semibold, the rest in the secondary colour.
    static func styled(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s)) ?? AttributedString(s)
        let bold = a.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.map(\.range)
        for r in bold { a[r].foregroundColor = Color.white }
        return a
    }
}

// MARK: - New session: project first, then the harness

/// Always a NEW session (POST /api/open {fresh:true}). From the floating "+": step 1 picks the
/// project, step 2 the harness. From a project card ("…" or a long press): the harness only.
struct NewSessionSheet: View {
    /// nil while the overview has not loaded (or failed to load).
    let projects: [String]?
    let loadError: String?
    let sessions: [OverviewSession]
    let initialProject: String?
    /// Server clock minus phone clock (HomeModel.offset), for the omp sessions' times.
    var clockOffset: TimeInterval = 0
    let onOpened: (String) -> Void
    /// A project was added (the finished add: toast text or cleanup notice); the sheet then closes.
    let onAdded: (HomeLogic.AddState) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var picked: String?
    /// Step 1 shows the "Thêm dự án" form instead of the list.
    @State private var adding = false
    /// The harness whose POST /api/open is in flight, or "r:<id>" for an omp resume; the sheet
    /// cannot be closed meanwhile.
    @State private var opening: String?
    @State private var errorText: String?
    /// Recent omp sessions of the shown project; nil while loading.
    @State private var omp: [OmpSession]?
    @State private var ompError: String?
    /// The server has no omp-sessions route: the section is left out.
    @State private var ompHidden = false

    static let harnesses = ["omp", "claude", "codex"]

    var body: some View {
        SheetScaffold {
            if let p = picked ?? initialProject {
                let back: (String, () -> Void) = initialProject != nil ? ("Huỷ", { dismiss() })
                                                                         : ("‹ Dự án", {
                                                                             picked = nil
                                                                             errorText = nil
                                                                             // The next project must not show this one's rows.
                                                                             omp = nil
                                                                             ompError = nil
                                                                         })
                // Off while a session opens: a late reply would open it after the sheet is gone.
                SheetHeader(title: initialProject ?? "Phiên mới", left: back).disabled(opening != nil)
                (Text(initialProject != nil ? "" : "Bước 2/2 · ") + Text("Chọn chương trình cho ") + Text(p).bold())
                    .stepCaption()
                options(Self.harnesses) { h in
                        row(disabled: opening != nil, action: { Task { await open(p, h) } }) {
                            HarnessAvatar(harness: h)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h).scaledFont(15, weight: .semibold, design: .monospaced)
                                Text(HarnessStyle.description(h)).scaledFont(13).foregroundColor(.l2)
                            }
                            Spacer()
                            if opening == h { ProgressView() } else { chevron }
                        }
                }
                if let errorText = errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle").scaledFont(13).foregroundColor(.redTone)
                        .padding(.bottom, 14)
                }
                if !ompHidden {
                    ompSection(p).task(id: p) { await loadOmp(p) }
                }
            } else if adding {
                AddProjectForm(onBack: { adding = false }, onAdded: { result in
                    onAdded(result)
                    dismiss()
                })
            } else {
                SheetHeader(title: "Phiên mới", left: ("Huỷ", { dismiss() }))
                Text("Bước 1/2 · Chọn dự án").stepCaption()
                if let projects = projects {
                    if projects.isEmpty {
                        Text("Chưa có dự án nào trong cấu hình máy chủ.").sheetBody()
                        addRow
                    } else {
                        addRow
                        options(projects) { p in
                                row(disabled: false, action: { picked = p }) {
                                    Image(systemName: "folder")
                                        .scaledFont(16)
                                        .foregroundColor(.accentBlue)
                                        .frame(width: 34, height: 34)
                                        .background(Color.accentBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p).scaledFont(15, weight: .semibold)
                                        Text(detail(p)).scaledFont(13).foregroundColor(.l2)
                                    }
                                    Spacer()
                                    chevron
                                }
                        }
                    }
                } else {
                    Text("Chưa tải được danh sách dự án").sheetBody()
                    if let loadError = loadError {
                        Text(loadError).scaledFont(13).foregroundColor(.redTone)
                    }
                }
            }
        }
        .interactiveDismissDisabled(opening != nil)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.l3)
    }

    /// "Thêm dự án": clone a GitHub repo onto the box and add it to the list.
    private var addRow: some View {
        options(["add"]) { _ in
            row(disabled: false, action: { adding = true }) {
                Image(systemName: "plus")
                    .scaledFont(16, weight: .semibold)
                    .foregroundColor(.greenTone)
                    .frame(width: 34, height: 34)
                    .background(Color.greenTone.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thêm dự án").scaledFont(15, weight: .semibold)
                    Text("tải một repo GitHub về box").scaledFont(13).foregroundColor(.l2)
                }
                Spacer()
                chevron
            }
        }
    }

    /// Grouped rows with 0.5 pt hairlines between them (mockup .opts).
    private func options<C: View>(_ items: [String], @ViewBuilder _ content: @escaping (String) -> C) -> some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { Rectangle().fill(Color.hair).frame(height: 0.5) }
                content(items[i])
            }
        }
        .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 14)
    }

    private func row<C: View>(disabled: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Recent omp sessions (laptop and box), "Tiếp tục" resumes one in a box tmux session

    private func ompSection(_ project: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Phiên omp gần đây")
                .scaledFont(13)
                .foregroundColor(.l2)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            if let list = omp, !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(list.indices, id: \.self) { i in
                        if i > 0 { Rectangle().fill(Color.hair).frame(height: 0.5) }
                        ompRow(list[i], project: project)
                    }
                }
                .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    if let ompError = ompError {
                        Label(ompError, systemImage: "exclamationmark.triangle").foregroundColor(.redTone)
                    } else if omp == nil {
                        ProgressView()
                        Text("Đang tải…").foregroundColor(.l2)
                    } else {
                        Text("Chưa có phiên omp nào cho dự án này.").foregroundColor(.l2)
                    }
                }
                .scaledFont(14)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func ompRow(_ s: OmpSession, project: String) -> some View {
        let title = HomeLogic.ompTitle(s.title), origin = HomeLogic.ompOrigin(s.origin)
        let when = HomeLogic.ompWhen(s, now: Date().addingTimeInterval(clockOffset))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(15, weight: .semibold)
                    .foregroundColor(s.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .l2 : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: origin == "laptop" ? "laptopcomputer" : "server.rack").scaledFont(9)
                        Text(origin).font(.system(.caption2, design: .monospaced, weight: .semibold))
                    }
                    .foregroundColor(origin == "laptop" ? .accentBlue : HarnessStyle.color("omp"))
                    .padding(.horizontal, 6)
                    .frame(minHeight: 17)
                    .background((origin == "laptop" ? Color.accentBlue : HarnessStyle.color("omp")).opacity(0.17),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    if !when.isEmpty { Text(when).scaledFont(12.5).foregroundColor(.l2) }
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + ", từ " + origin + (when.isEmpty ? "" : ", " + when))
            Spacer(minLength: 4)
            if opening == "r:" + s.id {
                ProgressView().frame(minWidth: 44, minHeight: 44)
            } else {
                Button { Task { await resume(project, s) } } label: {
                    Text("Tiếp tục")
                        .scaledFont(14.5, weight: .semibold)
                        .foregroundColor(.accentBlue)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .background(Color.fill3, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(opening != nil)
                .opacity(opening != nil ? 0.5 : 1)
                .accessibilityLabel("Tiếp tục phiên " + title)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
    }

    private func loadOmp(_ project: String) async {
        guard let api = app.api else { return }
        omp = nil
        ompError = nil
        do {
            omp = try await api.ompSessions(project: project)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            let e = error as? APIError
            if HomeLogic.ompListHidden(status: e?.status ?? 0, code: e?.code) {
                ompHidden = true
            } else {
                ompError = e?.code == "unknown_project" ? "Dự án này không có trên box." : app.report(error)
            }
        }
    }

    private func resume(_ project: String, _ s: OmpSession) async {
        guard let api = app.api, opening == nil else { return }
        opening = "r:" + s.id
        defer { opening = nil }
        do {
            let name = try await api.resumeOmp(project: project, id: s.id)
            errorText = nil
            onOpened(name)
            dismiss()
        } catch {
            let e = error as? APIError
            errorText = HomeLogic.ompResumeFailure(status: e?.status ?? 0, code: e?.code) ?? app.report(error)
            if e?.code == "unknown_session" { await loadOmp(project) }
        }
    }

    private func detail(_ project: String) -> String {
        let n = sessions.filter { $0.project == project }.count
        return n > 0 ? "đang có \(n) phiên" : "chưa có phiên"
    }

    private func open(_ project: String, _ harness: String) async {
        guard let api = app.api, opening == nil else { return }
        opening = harness
        defer { opening = nil }
        do {
            let reply = try await api.openFresh(project: project, harness: harness)
            errorText = nil
            onOpened(reply.name)
            dismiss()
        } catch {
            if let e = error as? APIError, e.status == 500, e.code == "harness_exited" {
                errorText = "Không mở được \(harness) trên box (chương trình thoát ngay)."
            } else {
                errorText = app.report(error)
            }
        }
    }
}

private extension Text {
    func stepCaption() -> some View {
        scaledFont(13).foregroundColor(.l2).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.bottom, 10)
    }
}

// MARK: - Add project (POST /api/projects, then GET the job every 2 s while the form is shown)

struct AddProjectForm: View {
    let onBack: () -> Void
    let onAdded: (HomeLogic.AddState) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.openURL) private var openURL
    @State private var repoText = ""
    @State private var nameText = ""
    @State private var add = HomeLogic.AddState()
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "Hoặc chọn repo": nil while loading; `listNote` replaces it; `listHidden` on an older server.
    @State private var repos: [GitHubRepo]?
    @State private var listNote: (text: String, retry: Bool)?
    @State private var listHidden = false
    @State private var listLoad = 0
    @State private var query = ""

    /// The write flag of the NEED_KEY / NEED_WRITE step; nil otherwise.
    private var needKey: Bool? {
        if case .needKey(let write) = add.phase { return write }
        return nil
    }

    var body: some View {
        let repo = HomeLogic.cleanRepo(repoText)
        let locked = add.busy || needKey != nil
        // The name placeholder: the default name once the link is valid.
        let fallback = HomeLogic.validRepo(repo) ? HomeLogic.projectName(repo: repo, typed: "") : "theo tên repo"
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Thêm dự án", left: ("‹ Dự án", onBack)).id("addTop")
            caption("Link repo GitHub")
            field("https://github.com/ten-tai-khoan/ten-repo", text: $repoText, label: "Link repo GitHub")
                .keyboardType(.URL)
                .disabled(locked)
            // The owner/repo the box will clone (the link reduced), or a blank line.
            Text(HomeLogic.validRepo(repo) ? "Repo: " + repo : " ")
                .scaledFont(13, design: .monospaced)
                .foregroundColor(.l2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 6)
                .padding(.bottom, 12)
            caption("Tên (không bắt buộc)")
            field(fallback, text: $nameText, label: "Tên dự án")
                .disabled(locked)
                .padding(.bottom, 14)
            if needKey == nil {
                Button("Thêm") { send(.submit(repo: repoText, name: nameText)) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(add.busy || repo.isEmpty)
                    .padding(.bottom, 12)
            }
            if add.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang tải repo về box… (có thể đóng, box vẫn tải tiếp)").scaledFont(14).foregroundColor(.l2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            } else if let write = needKey {
                keySteps(write)
            } else if let message = add.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .scaledFont(13)
                    .foregroundColor(.redTone)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = add.detail {
                    Text(detail).scaledFont(12).foregroundColor(.l3).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !locked && !listHidden { repoList(proxy) }
        }
        }
        .task(id: add.phase) { await run(add.phase) }
        .task(id: listLoad) { await loadRepos() }
    }

    // MARK: Repo list

    @ViewBuilder
    private func repoList(_ proxy: ScrollViewProxy) -> some View {
        Text("Hoặc chọn repo").scaledFont(13).foregroundColor(.l2).padding(.top, 22).padding(.bottom, 6)
        if let note = listNote {
            Text(note.text).sheetBody()
            if note.retry {
                Button("Thử lại") {
                    listNote = nil
                    listLoad += 1
                }
                .buttonStyle(PrimaryButtonStyle(fill: .grp2, text: .accentBlue))
            }
        } else if let repos = repos {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.l3).accessibilityHidden(true)
                TextField("Tìm repo", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Tìm repo")
            }
            .scaledFont(15)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.grp2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 10)
            let shown = HomeLogic.filterRepos(repos, query: query)
            if shown.isEmpty {
                Text(repos.isEmpty ? "Chưa có repo nào." : "Không có repo khớp.").sheetBody()
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(Color.hair).frame(height: 0.5) }
                        repoRow(r, proxy)
                    }
                }
                .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Đang tải danh sách repo…").scaledFont(14).foregroundColor(.l2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func repoRow(_ r: GitHubRepo, _ proxy: ScrollViewProxy) -> some View {
        let state = HomeLogic.repoRow(r)
        let sub = [state.note ?? "", HomeLogic.repoUpdated(r.updatedAt, now: Date())].filter { !$0.isEmpty }
        return Button {
            // The name stays as typed: empty, the placeholder (and the POST) take the default of the current link.
            repoText = "https://github.com/" + r.repo
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo("addTop", anchor: .top) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.repo).scaledFont(15, weight: .semibold).lineLimit(1).truncationMode(.middle)
                    if r.isPrivate {
                        Text("riêng tư")
                            .scaledFont(11, weight: .semibold)
                            .foregroundColor(.orangeTone)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orangeTone.opacity(0.16), in: Capsule())
                    }
                }
                if !sub.isEmpty { Text(sub.joined(separator: " · ")).scaledFont(13).foregroundColor(.l2) }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.pickable)
        .opacity(state.pickable ? 1 : 0.45)
        .accessibilityHint(state.pickable ? "Chạm để điền link repo" : "")
    }

    private func loadRepos() async {
        guard let api = app.api else { return }
        do {
            let reply = try await api.githubRepos()
            if let note = HomeLogic.repoListNote(reason: reply.reason, status: nil, text: nil) { listNote = note } else { repos = reply.repos }
        } catch {
            if Task.isCancelled { return }
            let e = error as? APIError
            if let note = HomeLogic.repoListNote(reason: nil, status: e?.status ?? 0, text: app.report(error)) {
                listNote = note
            } else {
                listHidden = true
            }
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).scaledFont(13).foregroundColor(.l2).padding(.bottom, 6)
    }

    private func field(_ placeholder: String, text: Binding<String>, label: String) -> some View {
        TextField(placeholder, text: text)
            .scaledFont(15, design: .monospaced)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.grp2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(label)
    }

    /// NEED_KEY / NEED_WRITE: the user adds the box's public key on GitHub, then retries.
    private func keySteps(_ write: Bool) -> some View {
        let steps = [
            "Bấm **Sao chép khóa** bên dưới.",
            "Bấm **Mở GitHub**, dán khóa vào ô **Key**, đặt tên **fcode coder**.",
            "Tích ô **Allow write access** (box cần quyền ghi).",
            "Bấm **Add key**, rồi quay lại đây bấm **Thử lại**.",
        ]
        return VStack(alignment: .leading, spacing: 0) {
            Text(write ? "GitHub đã nhận khóa nhưng khóa chưa có quyền ghi. Xoá khóa “fcode coder” cũ ở trang Deploy keys, rồi làm lại các bước sau:"
                       : "GitHub chưa cho box vào repo này (hoặc link repo chưa đúng). Làm một lần như sau:")
                .sheetBody()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps.indices, id: \.self) { k in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(k + 1).").monospacedDigit()
                        Text(HomeGuideView.styled(steps[k]))
                    }
                    .scaledFont(14.5)
                    .foregroundColor(.l2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 12)
            Text(add.pubkey ?? "")
                .scaledFont(12, design: .monospaced)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.grp2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Khóa công khai của box")
                .accessibilityValue(add.pubkey ?? "")
                .padding(.bottom, 10)
            HStack(spacing: 10) {
                Button(copied ? "Đã sao chép" : "Sao chép khóa") {
                    UIPasteboard.general.string = add.pubkey
                    copied = true
                }
                Button("Mở GitHub") { if let url = add.keyUrl { openURL(url) } }
                    .disabled(add.keyUrl == nil)
            }
            .buttonStyle(PrimaryButtonStyle(fill: .grp2, text: .accentBlue))
            .padding(.bottom, 10)
            if let detail = add.detail {
                Text(detail).scaledFont(12).foregroundColor(.l3).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            Button("Thử lại") {
                copied = false
                send(.retry)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func send(_ event: HomeLogic.AddEvent) {
        add = HomeLogic.addReduce(add, event)
        if add.phase == .done { onAdded(add) }
    }

    /// The effect of each phase; a new phase (or closing the form) cancels the one before.
    private func run(_ phase: HomeLogic.AddState.Phase) async {
        guard let api = app.api else { return }
        switch phase {
        case .posting:
            do {
                let job = try await api.addProject(repo: add.repo, name: add.name)
                if !Task.isCancelled { send(.accepted(job: job)) }
            } catch {
                if Task.isCancelled { return }
                let e = error as? APIError
                send(.postFailed(status: e?.status ?? 0, code: e?.code ?? "", text: app.report(error)))
            }
        case .polling(let id):
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                do {
                    let job = try await api.projectJob(id)
                    if !Task.isCancelled { send(.polled(job)) }
                } catch {
                    if Task.isCancelled { return }
                    let e = error as? APIError
                    send(.pollFailed(status: e?.status ?? 0, code: e?.code ?? "", text: app.report(error)))
                }
            }
        default:
            return
        }
    }
}

// MARK: - Rename

struct RenameSheet: View {
    let name: String
    let taken: Set<String>
    let rename: (String) async -> String?
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorText: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetScaffold {
            SheetHeader(title: "Đổi tên phiên", left: ("Huỷ", { dismiss() }), right: ("Lưu", save), rightBold: true)
            Text("Tên mới").scaledFont(13).foregroundColor(.l2).padding(.bottom, 6)
            TextField("", text: $text)
                .scaledFont(15, design: .monospaced)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.grp2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(saving)
                .accessibilityLabel("Tên mới")
            HStack(spacing: 8) {
                if saving { ProgressView() }
                Text(errorText ?? " ").scaledFont(13).foregroundColor(.redTone)
            }
            .frame(minHeight: 20)
            .padding(.vertical, 6)
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            text = name
            focused = true
        }
    }

    private func save() {
        let v = text.trimmingCharacters(in: .whitespaces)
        guard !saving else { return }
        if v == name { dismiss(); return }
        guard HomeLogic.validSessionName(v) else {
            errorText = "Tên chưa hợp lệ: chỉ chữ thường không dấu, số và “-” (tối đa 32)."
            return
        }
        guard !taken.contains(v) else { errorText = "Tên này đã có phiên khác."; return }
        saving = true
        errorText = nil
        Task {
            let failure = await rename(v)
            saving = false
            if let failure = failure {
                errorText = failure
            } else {
                dismiss()
                onDone(v)
            }
        }
    }
}
