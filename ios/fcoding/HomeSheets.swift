import SwiftUI

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

/// Title in the middle, a 72 pt text button on either side.
struct SheetHeader: View {
    let title: String
    var left: (String, () -> Void)? = nil
    var right: (String, () -> Void)? = nil
    var rightBold = false

    var body: some View {
        HStack(spacing: 0) {
            side(left, alignment: .leading, bold: false)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            side(right, alignment: .trailing, bold: rightBold)
        }
        .frame(minHeight: 44)
        .padding(.bottom, 6)
    }

    private func side(_ item: (String, () -> Void)?, alignment: Alignment, bold: Bool) -> some View {
        Group {
            if let item = item {
                Button(action: item.1) {
                    Text(item.0)
                        .font(.system(size: 16, weight: bold ? .semibold : .regular))
                        .foregroundColor(.accentBlue)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

extension View {
    /// Sheet paragraph: 14.5 pt secondary text.
    func sheetBody() -> some View {
        font(.system(size: 14.5)).foregroundColor(.l2).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
    }

    /// Grouped note box (mockup .now).
    func sheetNote() -> some View {
        font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.grp2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 14)
    }
}

// MARK: - Box info (tap on the ring)

struct BoxInfoSheet: View {
    let box: HomeBox?
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
                now(HomeLogic.ring(box, now: ctx.date), maxRun: maxRun, idle: idle).sheetNote()
            }
            Button("Đã hiểu") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func hours(_ minutes: Int) -> String { minutes % 60 == 0 ? "\(minutes / 60) giờ" : "\(minutes) phút" }

    private func step(_ tag: String, _ color: Color, _ title: Text, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(tag)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                title.font(.system(size: 14.5))
                Text(detail).font(.system(size: 13)).foregroundColor(.l2)
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
            return Text("Bây giờ: chưa biết giờ box nghỉ. Kéo màn hình chính xuống để làm mới.")
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
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(color)
                        .frame(width: 34, height: 34)
                        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
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
                        .font(.system(size: 14.5))
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
    let onOpened: (String) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var picked: String?
    /// The harness whose POST /api/open is in flight; the sheet cannot be closed meanwhile.
    @State private var opening: String?
    @State private var errorText: String?

    static let harnesses = ["omp", "claude", "codex"]

    var body: some View {
        SheetScaffold {
            if let p = picked ?? initialProject {
                let back: (String, () -> Void) = initialProject != nil ? ("Huỷ", { dismiss() })
                                                                         : ("‹ Dự án", { picked = nil; errorText = nil })
                SheetHeader(title: initialProject ?? "Phiên mới", left: back)
                (Text(initialProject != nil ? "" : "Bước 2/2 · ") + Text("Chọn chương trình cho ") + Text(p).bold())
                    .stepCaption()
                options(Self.harnesses) { h in
                        row(disabled: opening != nil, action: { Task { await open(p, h) } }) {
                            HarnessAvatar(harness: h)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h).font(.system(size: 15, weight: .semibold, design: .monospaced))
                                Text(HarnessStyle.description(h)).font(.system(size: 13)).foregroundColor(.l2)
                            }
                            Spacer()
                            if opening == h { ProgressView() } else { chevron }
                        }
                }
                if let errorText = errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundColor(.redTone)
                }
            } else {
                SheetHeader(title: "Phiên mới", left: ("Huỷ", { dismiss() }))
                Text("Bước 1/2 · Chọn dự án").stepCaption()
                if let projects = projects {
                    if projects.isEmpty {
                        Text("Chưa có dự án nào trong cấu hình máy chủ.").sheetBody()
                    } else {
                        options(projects) { p in
                                row(disabled: false, action: { picked = p }) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentBlue)
                                        .frame(width: 34, height: 34)
                                        .background(Color.accentBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p).font(.system(size: 15, weight: .semibold))
                                        Text(detail(p)).font(.system(size: 13)).foregroundColor(.l2)
                                    }
                                    Spacer()
                                    chevron
                                }
                        }
                    }
                } else {
                    Text("Chưa tải được danh sách dự án").sheetBody()
                    if let loadError = loadError {
                        Text(loadError).font(.system(size: 13)).foregroundColor(.redTone)
                    }
                }
            }
        }
        .interactiveDismissDisabled(opening != nil)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.l3)
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
        font(.system(size: 13)).foregroundColor(.l2).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.bottom, 10)
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
            Text("Tên mới").font(.system(size: 13)).foregroundColor(.l2).padding(.bottom, 6)
            TextField("", text: $text)
                .font(.system(size: 15, design: .monospaced))
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
                Text(errorText ?? " ").font(.system(size: 13)).foregroundColor(.redTone)
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
