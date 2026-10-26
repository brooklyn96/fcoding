import SwiftUI

/// A pushed session; `reply` opens it with the composer focused ("Trả lời").
struct Route: Hashable {
    let name: String
    var reply = false
    var harness: String? = nil
}

/// The pushed "Hạn mức" detail screen.
struct QuotaRoute: Hashable {}

/// Main screen (home v2, mockup home.html): a header that scrolls with the content (? and ⚙),
/// the top card (box ring + rotating quota tile), the session summary, the project cards
/// (filter), the sessions ("Cần bạn", "Đang chạy", "Đang nghỉ") and a floating "+".
struct ProjectsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = OverviewModel()
    @StateObject private var home = HomeModel()
    @State private var path = NavigationPath()
    @State private var project = "all"
    @AppStorage("inbox.open.running") private var runningOpen = true
    @AppStorage("inbox.open.idle") private var idleOpen = false
    @State private var sheet: HomeSheet?
    @State private var openAfterSheet: String?
    @State private var pendingClose: OverviewSession?
    @State private var lastOpened: String?
    @State private var flash: String?
    @State private var toast: String?

    /// Poll only while the list itself is on screen and the app is in the foreground.
    private var polling: Bool { path.isEmpty && scenePhase == .active }

    private var allSessions: [OverviewSession] { model.overview?.sessions ?? [] }
    private var projectNames: [String] {
        if let o = model.overview { return o.projects.map(\.name) }
        return home.home?.projects.map(\.name) ?? []
    }

    private var visible: [OverviewSession] {
        allSessions
            .filter { project == "all" || $0.project == project }
            .sorted { ($0.activity ?? 0) > ($1.activity ?? 0) }
    }

    private func sessions(_ state: String) -> [OverviewSession] {
        visible.filter { state == "idle" ? !["waiting", "running"].contains($0.state ?? "") : $0.state == state }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    topBar.homeRow(top: 0, bottom: 0)
                    if let notice = app.notice {
                        Button { app.notice = nil } label: {
                            Label(notice, systemImage: "exclamationmark.circle").foregroundColor(.orange)
                        }
                        .accessibilityHint("Chạm để ẩn")
                        .homeRow(top: 0, bottom: 8)
                    }
                    if let errorText = model.errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .homeRow(top: 0, bottom: 8)
                    }
                    TopCard(home: home, visible: polling, onRing: { sheet = .box }, onQuota: { path.append(QuotaRoute()) })
                        .homeRow(top: 0, bottom: 0)
                    summary(proxy).homeRow(top: 6, bottom: 2)
                    Text("Dự án")
                        .scaledFont(13)
                        .foregroundColor(.l2)
                        .padding(.horizontal, 2)
                        .homeRow(top: 10, bottom: 6)
                    rail.homeRow(top: 0, bottom: 0, side: 0)
                    sessionRows
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .background(Color.black)
                .refreshable { await reload() }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 60) }
                .overlay(alignment: .bottomTrailing) { fab }
                .overlay(alignment: .top) { StatusBarCover() }
                .overlay(alignment: .top) { ToastView(text: $toast) }
                .background(SwipeBackEnabler().frame(width: 0, height: 0))
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("FCode")
            .navigationDestination(for: Route.self) { SessionView(name: $0.name, harness: $0.harness, focusComposer: $0.reply) }
            .navigationDestination(for: QuotaRoute.self) { _ in QuotaDetailView(home: home) }
            .task(id: polling) {
                guard polling else { return }
                while !Task.isCancelled {
                    await model.load(app)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            .task(id: polling) {
                guard polling else { return }
                while !Task.isCancelled {
                    await home.load(app)
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            .onChange(of: path) { newPath in
                // Back on the list: what was read inside the session counts as read.
                if newPath.isEmpty, let name = lastOpened {
                    model.pendingRead = name
                    lastOpened = nil
                }
            }
            .confirmationDialog(
                "Đóng phiên \(pendingClose?.name ?? "")?",
                isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
                titleVisibility: .visible,
                presenting: pendingClose
            ) { s in
                Button("Đóng phiên", role: .destructive) {
                    Task {
                        if await model.delete(s.name, app: app) { toast = "Đã đóng \(s.name)" }
                    }
                }
                Button("Huỷ", role: .cancel) {}
            } message: { _ in
                Text("Chương trình đang chạy trong phiên này sẽ bị tắt.")
            }
            .sheet(item: $sheet, onDismiss: {
                if let name = openAfterSheet {
                    openAfterSheet = nil
                    open(name)
                }
            }) { which in
                sheetView(which).environmentObject(app)
            }
        }
    }

    private func reload() async {
        let quota = Task { await home.load(app) }
        await model.load(app)
        await quota.value
    }

    private func open(_ name: String, reply: Bool = false) {
        model.markRead(name)
        lastOpened = name
        let known = allSessions.first { $0.name == name }
        path.append(Route(name: name, reply: reply, harness: known?.harness))
    }

    @ViewBuilder
    private func sheetView(_ which: HomeSheet) -> some View {
        switch which {
        case .settings:
            DeviceSettingsView()
        case .guide:
            HomeGuideView()
        case .box:
            BoxInfoSheet(box: home.home?.box, offset: home.offset)
        case .new(let project):
            NewSessionSheet(projects: model.overview == nil ? nil : projectNames,
                            loadError: model.errorText,
                            sessions: allSessions,
                            initialProject: project,
                            onOpened: { openAfterSheet = $0 })
        case .rename(let name):
            RenameSheet(name: name, taken: Set(allSessions.map(\.name))) { newName in
                await model.rename(name, to: newName, app: app)
            } onDone: { newName in
                toast = "Đã đổi tên thành \(newName)"
            }
        }
    }

    // MARK: - Header

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Image("Brand")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text("FCode - EZ Vibecoding")
                    .scaledFont(17, weight: .bold)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            headerButton("questionmark.circle", label: "Hướng dẫn") { sheet = .guide }
            headerButton("gearshape", label: "Cài đặt") { sheet = .settings }
                .padding(.trailing, -10)
        }
        .frame(minHeight: 52)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(20)
                .foregroundColor(.accentBlue)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Summary

    private func summary(_ proxy: ScrollViewProxy) -> some View {
        let all = allSessions
        let run = all.filter { $0.state == "running" }.count
        let wait = all.filter { $0.state == "waiting" }.count
        return HStack(spacing: 2) {
            if model.overview != nil && all.isEmpty {
                Text("Chưa có phiên nào đang mở").foregroundColor(.l2).padding(.leading, 2)
            } else if model.overview != nil {
                Button {
                    project = "all"
                    runningOpen = true
                    jump(to: first("running"), proxy, flash: false)
                } label: {
                    HStack(spacing: 7) {
                        StatusDot(state: "running")
                        Text("**\(run)** đang chạy")
                    }
                    .padding(.leading, 2).padding(.trailing, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(run) phiên đang chạy, chạm để xem")
                Text("·").foregroundColor(.l3)
                Button {
                    project = "all"
                    jump(to: first("waiting"), proxy, flash: true)
                } label: {
                    HStack(spacing: 7) {
                        StatusDot(state: wait > 0 ? "waiting" : "idle")
                        Text("\(wait) chờ bạn")
                            .fontWeight(wait > 0 ? .semibold : .regular)
                            .foregroundColor(wait > 0 ? .orangeTone : .l2)
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(wait == 0)
                .accessibilityLabel("\(wait) phiên chờ bạn" + (wait > 0 ? ", chạm để xem" : ""))
            } else {
                Text(model.errorText == nil ? "Đang tải…" : " ").foregroundColor(.l2).padding(.leading, 2)
            }
            Spacer(minLength: 0)
        }
        .scaledFont(15)
        .frame(minHeight: 44)
    }

    /// The first card of `state` once the filter is "Tất cả" (the tap clears the filter).
    private func first(_ state: String) -> String? {
        allSessions.filter { $0.state == state }.max { ($0.activity ?? 0) < ($1.activity ?? 0) }?.name
    }

    private func jump(to name: String?, _ proxy: ScrollViewProxy, flash doFlash: Bool) {
        guard let name = name else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(name, anchor: .center) }
            if doFlash {
                flash = name
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { if flash == name { flash = nil } }
            }
        }
    }

    // MARK: - Project cards

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Top-aligned: a card with the git line is one line taller.
            HStack(alignment: .top, spacing: 10) {
                projectCard("all")
                ForEach(projectNames, id: \.self) { projectCard($0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        // 182 pt cards: text grows up to xxLarge, then stops.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func projectCard(_ id: String) -> some View {
        let inP = allSessions.filter { id == "all" || $0.project == id }
        let waiting = inP.filter { $0.state == "waiting" }.count
        let info = home.home?.projects.first { $0.name == id }
        let lines: [ProjectLine]
        if id == "all" {
            lines = [
                ProjectLine(text: Text("\(projectNames.count) dự án · \(inP.count) phiên")),
                ProjectLine(text: Text(LocalizedStringKey(HomeLogic.allPrLine(home.home?.projects)))),
                ProjectLine(text: Text(waiting > 0 ? "\(waiting) phiên chờ bạn" : "không ai chờ bạn"),
                            color: waiting > 0 ? .orangeTone : .l2),
            ]
        } else {
            let prs = info?.prs
            let branch = info?.branch ?? model.overview?.projects.first { $0.name == id }?.branch
            let checks = HomeLogic.checksLine(prs, branch: branch)
            let deploy = HomeLogic.deployLine(info?.lastRun, now: home.serverNow())
            let reading = info?.loading == true
            let git = HomeLogic.gitLine(info?.git)
            lines = [
                ProjectLine(text: Text(LocalizedStringKey(HomeLogic.prLine(info)))),
                ProjectLine(text: Text(checks.text.isEmpty ? " " : checks.text), color: checks.tone.color),
            ] + (git.map { g -> [ProjectLine] in
                let t = Text(g.text)
                return [ProjectLine(text: g.label.map { t.accessibilityLabel($0) } ?? t, color: g.tone.color)]
            } ?? []) + [
                // Before the first gh read there is no deploy to report yet.
                ProjectLine(text: Text(reading ? " " : deploy.text), color: deploy.tone.color),
            ]
        }
        return ProjectCard(title: id == "all" ? "Tất cả" : id, count: waiting > 0 ? waiting : inP.count,
                           waiting: waiting > 0, lines: lines, selected: project == id,
                           onTap: { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { project = id } },
                           onMore: { sheet = .new(project: id == "all" ? nil : id) },
                           showMore: id != "all")
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionRows: some View {
        if model.overview != nil && visible.isEmpty {
            EmptySessions(project: project == "all" ? nil : project) {
                sheet = .new(project: project == "all" ? nil : project)
            }
            .homeRow(top: 8, bottom: 0)
        } else {
            let waiting = sessions("waiting")
            if !waiting.isEmpty {
                HStack(spacing: 8) {
                    StatusDot(state: "waiting")
                    Text("Cần bạn · \(waiting.count)")
                }
                .scaledFont(14, weight: .semibold)
                .foregroundColor(.orangeTone)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .homeRow(top: 8, bottom: 0)
                ForEach(waiting) { row($0) }
            }
            fold("running", title: "Đang chạy", isOpen: $runningOpen)
            fold("idle", title: "Đang nghỉ", isOpen: $idleOpen)
        }
    }

    /// One header row (dot, name, count, harness badges, chevron); tapping expands / collapses.
    @ViewBuilder
    private func fold(_ state: String, title: String, isOpen: Binding<Bool>) -> some View {
        let rows = sessions(state)
        if !rows.isEmpty {
            Button {
                // Reduce Motion: expand / collapse and the chevron change without animation.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    Text(title).scaledFont(15, weight: .semibold).foregroundColor(.primary).fixedSize()
                    Text("\(rows.count)").scaledFont(14).foregroundColor(.l2)
                    HStack(spacing: 4) {
                        ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { item in
                            HarnessBadge(harness: item.element.harness ?? "omp")
                        }
                        if rows.count > 3 {
                            Text("+\(rows.count - 3)").scaledFont(12).foregroundColor(.l2)
                        }
                    }
                    .padding(.leading, 4)
                    .clipped()
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.l3)
                        .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(rows.count) phiên")
            .accessibilityHint(isOpen.wrappedValue ? "Chạm để thu gọn" : "Chạm để mở rộng")
            .homeRow(top: 8, bottom: 0)
            if isOpen.wrappedValue {
                ForEach(rows) { row($0) }
            }
        }
    }

    private func row(_ s: OverviewSession) -> some View {
        SessionRow(
            session: s,
            info: model.overview?.projects.first { $0.name == s.project },
            showProject: project == "all",
            unread: model.isUnread(s),
            time: model.relativeTime(s),
            busy: model.busy.contains(s.name),
            answered: model.answered[s.name] != nil,
            flash: flash == s.name,
            onOpen: { open(s.name) },
            onReply: { open(s.name, reply: true) },
            onAnswer: { text in Task { await model.answer(s, text, app: app) } }
        )
        .id(s.name)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { pendingClose = s } label: { Label("Đóng", systemImage: "xmark") }
                .tint(.redTone)
            Button { sheet = .rename(s.name) } label: { Label("Đổi tên", systemImage: "pencil") }
                .tint(.accentBlue)
        }
        .homeRow(top: 4, bottom: 4)
    }

    // MARK: - Floating "+"

    private var fab: some View {
        Button { sheet = .new(project: nil) } label: {
            Image(systemName: "plus")
                .scaledFont(18, weight: .semibold)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [Color(hex: 0x2E95FF), .accentBlue], startPoint: .top, endPoint: .bottom),
                            in: Circle())
                .shadow(color: Color.accentBlue.opacity(0.22), radius: 6, y: 4)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel("Tạo phiên mới")
    }
}

/// The sheets of the main screen (one at a time).
enum HomeSheet: Identifiable {
    case settings, guide, box
    case new(project: String?)
    case rename(String)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .guide: return "guide"
        case .box: return "box"
        case .new(let p): return "new." + (p ?? "")
        case .rename(let n): return "rename." + n
        }
    }
}

private extension View {
    /// A full-width List row with the mockup's 16 pt side gutters and no separator.
    func homeRow(top: CGFloat, bottom: CGFloat, side: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.black)
    }
}

// MARK: - Palette (mockup home.html, iOS dark system colours)

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    static let grp = Color(hex: 0x1C1C1E)
    static let grp2 = Color(hex: 0x2C2C2E)
    static let hair = Color(hex: 0x38383A)
    static let fill3 = Color(hex: 0x767680, alpha: 0.24)
    static let fill4 = Color(hex: 0x767680, alpha: 0.18)
    static let l2 = Color(hex: 0xEBEBF5, alpha: 0.6)
    static let l3 = Color(hex: 0xEBEBF5, alpha: 0.3)
    static let accentBlue = Color(hex: 0x0A84FF)
    static let orangeTone = Color(hex: 0xFF9F0A)
    static let greenTone = Color(hex: 0x30D158)
    static let redTone = Color(hex: 0xFF453A)
    static let yellowTone = Color(hex: 0xFFD60A)
}

extension HomeLogic.Tone {
    var color: Color {
        switch self {
        case .ok: return .greenTone
        case .fail: return .redTone
        case .pending, .warn: return .orangeTone
        case .none: return .l3
        }
    }
}

/// Black strip behind the status bar, so content scrolling under it stays readable.
struct StatusBarCover: View {
    var body: some View {
        Color.black.ignoresSafeArea(edges: .top).frame(height: 0)
    }
}

/// Pressed = 0.94 scale (the floating "+").
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Short message at the top of the screen for 2.2 s.
struct ToastView: View {
    @Binding var text: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let t = text {
                Text(t)
                    .scaledFont(14)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color(hex: 0x3A3A3C, alpha: 0.96), in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        if text == t { text = nil }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: text)
    }
}

// MARK: - Project card

struct ProjectLine {
    let text: Text
    var color: Color = .l2
}

/// 182 pt card: name + count, three status lines, "…" for a new session; tap filters the
/// sessions, a long press opens a new session in that project.
struct ProjectCard: View {
    let title: String
    let count: Int
    let waiting: Bool
    let lines: [ProjectLine]
    let selected: Bool
    let onTap: () -> Void
    let onMore: () -> Void
    let showMore: Bool
    @State private var pressing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).scaledFont(15, weight: .semibold).lineLimit(1)
                Text("\(count)")
                    .scaledFont(12, weight: .bold)
                    .foregroundColor(waiting ? .black : .l2)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 19, minHeight: 19)
                    .background(waiting ? Color.orangeTone : Color.fill3, in: Capsule())
            }
            .padding(.trailing, showMore ? 30 : 0)
            .padding(.bottom, 0)
            ForEach(lines.indices, id: \.self) { i in
                lines[i].text
                    .scaledFont(12.5)
                    .foregroundColor(lines[i].color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.top, 11).padding(.horizontal, 12).padding(.bottom, 10)
        .frame(width: 182, alignment: .topLeading)
        .frame(minHeight: 108, alignment: .topLeading)
        .background(selected ? Color(hex: 0x2A2A2E) : Color.grp, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Color.white : .clear, lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            if showMore {
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .scaledFont(14, weight: .bold)
                        .foregroundColor(.l2)
                        .frame(width: 28, height: 28)
                        .background(Color.fill4, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mở phiên mới trong \(title)")
            }
        }
        .scaleEffect(pressing ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: pressing)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.5, perform: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onMore()
        }, onPressingChanged: { pressing = $0 })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // A double tap filters (the combined "…" button would otherwise take it).
        .accessibilityAction(.default, onTap)
        .accessibilityAction(named: "Mở phiên mới", onMore)
    }
}

// MARK: - Empty state

struct EmptySessions: View {
    let project: String?
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "terminal")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(HarnessStyle.color("omp"))
                .frame(height: 96)
                .accessibilityHidden(true)
            Text("Chưa có phiên nào" + (project.map { " trong \($0)" } ?? ""))
                .scaledFont(19, weight: .bold)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Text("Mở một phiên omp, claude hoặc codex để máy bắt đầu làm việc cho bạn.")
                .scaledFont(14)
                .foregroundColor(.l2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.bottom, 16)
            Button(action: onCreate) {
                Text(project.map { "Tạo phiên trong \($0)" } ?? "Tạo phiên đầu tiên")
                    .scaledFont(16, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Color.accentBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28).padding(.horizontal, 12).padding(.bottom, 18)
        .background(Color.grp, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Session card

/// One session card. Waiting: "Cần bạn", the question and the answer pills; running: the last
/// line and a live bar; idle: compact and dimmed.
struct SessionRow: View {
    let session: OverviewSession
    let info: ProjectInfo?
    let showProject: Bool
    let unread: Bool
    let time: String
    let busy: Bool
    /// A y/n answer was sent and the refresh does not show it yet.
    let answered: Bool
    let flash: Bool
    let onOpen: () -> Void
    let onReply: () -> Void
    let onAnswer: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: String {
        ["waiting", "running"].contains(session.state ?? "") ? session.state! : "idle"
    }

    var body: some View {
        let idle = state == "idle"
        Group {
            if state == "waiting" {
                content
            } else {
                Button(action: onOpen) { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, idle ? 9 : 11)
        .background(Color.grp, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orangeTone, lineWidth: 2.5)
                .shadow(color: Color.orangeTone.opacity(0.5), radius: 11)
                .opacity(flash ? 1 : 0)
                .animation(flash ? nil : (reduceMotion ? nil : .easeOut(duration: 1.2)), value: flash)
        )
        // Waiting rows keep their answer buttons as separate VoiceOver elements.
        .accessibilityElement(children: state == "waiting" ? .contain : .combine)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var content: some View {
        let idle = state == "idle", waiting = state == "waiting"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                HarnessBadge(harness: session.harness ?? "omp")
                Text(session.name)
                    .scaledFont(15, weight: idle ? .medium : .semibold, design: .monospaced)
                    .foregroundColor(idle ? .l2 : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if unread {
                    Circle().fill(Color.accentBlue).frame(width: 8, height: 8)
                        .accessibilityLabel("chưa đọc")
                }
                if waiting {
                    Text("Cần bạn")
                        .scaledFont(12, weight: .bold)
                        .foregroundColor(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.orangeTone, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                }
                Spacer(minLength: 6)
                Text(time)
                    .scaledFont(12.5)
                    .foregroundColor(waiting ? .orangeTone : .l2)
                    .fixedSize()
            }
            meta.padding(.top, 3)
            if let preview = session.preview, !preview.isEmpty {
                PreviewText(text: preview)
                    .scaledFont(12.5, design: .monospaced)
                    .foregroundColor(idle ? .l2 : Color(hex: 0xD1D1D6))
                    .lineLimit(waiting ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.top, 6)
            }
            if state == "running" { LiveBar().padding(.top, 7) }
            if waiting { actions.padding(.top, 4) }
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if showProject, let p = session.project {
                Text(p)
                Text("·").foregroundColor(.l3)
            }
            if let branch = info?.branch, !branch.isEmpty {
                Image(systemName: "arrow.triangle.branch").scaledFont(11)
                Text(branch).scaledFont(12, design: .monospaced).truncationMode(.tail)
            }
        }
        .scaledFont(13)
        .foregroundColor(.l2)
        .lineLimit(1)
    }

    private var actions: some View {
        // y/n stay off while an action runs or the sent answer is not yet reflected; the other
        // buttons are off only while an action runs.
        HStack(spacing: 8) {
            // Not beside a numbered menu: there "n" + Enter would confirm the highlighted option.
            if OverviewModel.isYesNo(session.preview) && session.menu != true {
                pill("y · Đồng ý", fill: .greenTone, text: .black, off: busy || answered) { onAnswer("y") }
                pill("n · Từ chối", fill: .fill3, text: .white, off: busy || answered) { onAnswer("n") }
            } else {
                pill("Trả lời", fill: .fill3, text: .accentBlue, off: busy, action: onReply)
            }
            pill("Mở", fill: .fill3, text: .accentBlue, off: busy, action: onOpen)
            if busy || answered { ProgressView().padding(.leading, 2) }
        }
    }

    private func pill(_ title: String, fill: Color, text: Color, off: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // 32 pt capsule look, 44 pt tall hit area.
            Text(title)
                .scaledFont(14.5, weight: .semibold)
                .foregroundColor(text)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(fill, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(off)
        .opacity(off ? 0.5 : 1)
    }
}

/// The card's last line with omp's Nerd icons drawn in the bundled Symbols Nerd Font, as
/// SessionView does: SF Mono has no glyph for them and the system fallback never searches app
/// fonts, so they showed as boxes. Text keeps the inherited font and colour; an icon the Nerd
/// font lacks too is dropped. Its own view, so the size reads the row's clamped Dynamic Type.
private struct PreviewText: View {
    let text: String
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12.5

    var body: some View { Text(attributed) }

    private var attributed: AttributedString {
        typealias A = AttributeScopes.SwiftUIAttributes
        let nerd = UIFont(name: ANSI.nerdFontName, size: ANSI.iconFontSize(forBase: size))
        var icon = AttributeContainer()
        if let nerd = nerd {
            let base = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            icon[A.FontAttribute.self] = Font(nerd as CTFont)
            icon[A.BaselineOffsetAttribute.self] = (base.ascender + base.descender) / 2 - (nerd.ascender + nerd.descender) / 2
        }
        var out = AttributedString()
        var piece = String.UnicodeScalarView()
        var pieceIsIcon = false
        func emit() {
            guard !piece.isEmpty else { return }
            out.append(AttributedString(String(piece), attributes: pieceIsIcon ? icon : AttributeContainer()))
            piece = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            let isIcon = ANSI.isIcon(scalar)
            if isIcon, !(nerd.map { ANSI.hasGlyph($0 as CTFont, scalar) } ?? false) { continue }
            if isIcon != pieceIsIcon {
                emit()
                pieceIsIcon = isIcon
            }
            piece.append(scalar)
        }
        emit()
        return out
    }
}

/// 9 pt state dot: waiting orange, running green with a soft pulse, idle grey.
struct StatusDot: View {
    let state: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let color: Color = state == "waiting" ? .orangeTone : state == "running" ? .greenTone : Color(hex: 0x636366)
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .background(
                Circle()
                    .stroke(color.opacity(pulse ? 0 : 0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(state == "running" && !reduceMotion ? 1 : 0)
            )
            .onAppear {
                guard state == "running", !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

/// Thin green highlight sweeping left to right under a running session.
struct LiveBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.5

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .greenTone, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width / 2)
                .offset(x: phase * geo.size.width)
        }
        .frame(height: 2)
        .clipShape(Capsule())
        .opacity(0.7)
        .onAppear {
            guard !reduceMotion else { phase = 0.25; return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}
