import SwiftUI

/// A pushed session; `reply` opens it with the composer focused ("Trả lời").
struct Route: Hashable {
    let name: String
    var reply = false
}

/// Inbox (CONTRACT A5): "Cần bạn" first, then the collapsible "Đang chạy" / "Đang nghỉ",
/// a project chip rail on top and a translucent harness dock at the bottom.
struct ProjectsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = OverviewModel()
    @State private var path: [Route] = []
    @State private var project = "all"
    @State private var harness = "all"
    @AppStorage("inbox.open.running") private var runningOpen = false
    @AppStorage("inbox.open.idle") private var idleOpen = false
    @State private var showSettings = false
    @State private var showNew = false
    @State private var openAfterSheet: String?
    @State private var pendingDelete: OverviewSession?
    @State private var lastOpened: String?
    /// Distance from the screen edge to the list's content edge, so the chip rail can bleed.
    @State private var railInset: CGFloat = 16

    /// Poll only while the list itself is on screen and the app is in the foreground.
    private var polling: Bool { path.isEmpty && scenePhase == .active }

    private var allSessions: [OverviewSession] { model.overview?.sessions ?? [] }
    private var projectNames: [String] { model.overview?.projects.map(\.name) ?? [] }

    /// A session without a harness tag counts as "shell" everywhere (avatar, badges, filter).
    private func matchesHarness(_ s: OverviewSession) -> Bool { harness == "all" || (s.harness ?? "shell") == harness }

    private var visible: [OverviewSession] {
        allSessions
            .filter { matchesHarness($0) && (project == "all" || $0.project == project) }
            .sorted { ($0.activity ?? 0) > ($1.activity ?? 0) }
    }

    private func sessions(_ state: String) -> [OverviewSession] {
        visible.filter { state == "idle" ? !["waiting", "running"].contains($0.state ?? "") : $0.state == state }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                topSection
                if let notice = app.notice {
                    Section {
                        Button { app.notice = nil } label: {
                            Label(notice, systemImage: "exclamationmark.circle").foregroundColor(.orange)
                        }
                        .accessibilityHint("Chạm để ẩn")
                    }
                }
                if let errorText = model.errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
                waitingSection
                foldSection("running", title: "Đang chạy", isOpen: $runningOpen)
                foldSection("idle", title: "Đang nghỉ", isOpen: $idleOpen)
                emptyOrFooter
            }
            .listStyle(.insetGrouped)
            .navigationTitle("FCode")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Cài đặt")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNew = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    }
                    .accessibilityLabel("Phiên mới")
                }
            }
            .refreshable { await model.load(app) }
            .safeAreaInset(edge: .bottom) { HarnessDock(selection: $harness) }
            .navigationDestination(for: Route.self) { SessionView(name: $0.name, focusComposer: $0.reply) }
            .task(id: polling) {
                guard polling else { return }
                while !Task.isCancelled {
                    await model.load(app)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            .onChange(of: showNew) { presented in
                // A new "+" sheet never inherits a name from an earlier one.
                if presented { openAfterSheet = nil }
            }
            .onChange(of: path) { newPath in
                // Back on the list: what was read inside the session counts as read.
                if newPath.isEmpty, let name = lastOpened {
                    model.pendingRead = name
                    lastOpened = nil
                }
            }
            .confirmationDialog(
                "Xoá phiên \(pendingDelete?.name ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { s in
                Button("Xoá phiên", role: .destructive) { Task { await model.delete(s.name, app: app) } }
                Button("Huỷ", role: .cancel) {}
            } message: { _ in
                Text("Chương trình đang chạy trong phiên này sẽ bị tắt.")
            }
            .sheet(isPresented: $showSettings) { DeviceSettingsView().environmentObject(app) }
            .sheet(isPresented: $showNew, onDismiss: {
                if let name = openAfterSheet {
                    openAfterSheet = nil
                    open(name)
                }
            }) {
                NewSessionSheet(projects: model.overview == nil ? nil : projectNames,
                                loadError: model.errorText,
                                sessions: allSessions,
                                fixedHarness: harness == "all" ? nil : harness,
                                onOpened: { openAfterSheet = $0 })
                    .environmentObject(app)
            }
        }
    }

    private func open(_ name: String, reply: Bool = false) {
        model.markRead(name)
        lastOpened = name
        path.append(Route(name: name, reply: reply))
    }

    // MARK: - Header: subtitle + project chips

    private var topSection: some View {
        // Same filtered set as "Cần bạn · N" (project chip + dock), so the numbers agree.
        let waiting = sessions("waiting").count
        return Section {
            // Zero row insets put this content on the large title's leading edge; the rail then
            // extends by `railInset` on both sides so it scrolls edge to edge like the mockup.
            VStack(alignment: .leading, spacing: 10) {
                if waiting > 0 {
                    Text("\(waiting) phiên đang chờ bạn")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("all", label: "Tất cả")
                        ForEach(projectNames, id: \.self) { chip($0, label: $0) }
                    }
                    .padding(.horizontal, railInset)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -railInset)
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: RailInsetKey.self, value: geo.frame(in: .global).minX)
            })
            .onPreferenceChange(RailInsetKey.self) { if $0 >= 0 { railInset = $0 } }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func chip(_ value: String, label: String) -> some View {
        let inChip = allSessions.filter { matchesHarness($0) && (value == "all" || $0.project == value) }
        let waiting = inChip.filter { $0.state == "waiting" }.count
        let selected = project == value
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { project = value }
        } label: {
            HStack(spacing: 7) {
                Text(label).font(.subheadline.weight(.medium))
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(Color.orange, in: Capsule())
                } else {
                    Text("\(inChip.count)")
                        .font(.subheadline)
                        .foregroundColor(selected ? Color.black.opacity(0.55) : .secondary)
                }
            }
            .foregroundColor(selected ? .black : .primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(selected ? Color.white : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(waiting > 0 ? "\(label), \(waiting) chờ bạn" : "\(label), \(inChip.count) phiên")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Sections

    @ViewBuilder
    private var waitingSection: some View {
        let rows = sessions("waiting")
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row($0) }
            } header: {
                HStack(spacing: 7) {
                    StatusDot(state: "waiting")
                    Text("Cần bạn · \(rows.count)")
                }
                .foregroundColor(.orange)
            }
        }
    }

    /// One header row (dot, name, count, harness badges, chevron); tapping expands / collapses.
    @ViewBuilder
    private func foldSection(_ state: String, title: String, isOpen: Binding<Bool>) -> some View {
        let rows = sessions(state)
        if !rows.isEmpty {
            Section {
                Button {
                    // Reduce Motion: expand / collapse and the chevron change without animation.
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isOpen.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(state: state).padding(.trailing, 3)
                        Text(title).font(.body.weight(.semibold)).foregroundColor(.primary).fixedSize()
                        Text("\(rows.count)").font(.subheadline.weight(.medium)).foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { item in
                                HarnessBadge(harness: item.element.harness ?? "shell")
                            }
                            if rows.count > 3 {
                                Text("+\(rows.count - 3)").font(.caption.weight(.medium)).foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 4)
                        .clipped()
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                            .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(rows.count) phiên")
                .accessibilityHint(isOpen.wrappedValue ? "Chạm để thu gọn" : "Chạm để mở rộng")
                if isOpen.wrappedValue {
                    ForEach(rows) { row($0) }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyOrFooter: some View {
        if model.overview == nil {
            if model.errorText == nil {
                Section { HStack(spacing: 10) { ProgressView(); Text("Đang tải…").foregroundColor(.secondary) } }
            }
        } else if visible.isEmpty {
            Section {
                Text("Chưa có phiên \(harness == "all" ? "" : harness + " ")nào\(project == "all" ? "" : " trong " + project).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else {
            Section {} footer: { Text("Vuốt trái một phiên để đánh dấu đã đọc hoặc xoá.") }
        }
    }

    // MARK: - Rows

    private func row(_ s: OverviewSession) -> some View {
        let unread = model.isUnread(s)
        return SessionRow(
            session: s,
            info: model.overview?.projects.first { $0.name == s.project },
            showProject: project == "all",
            unread: unread,
            time: model.relativeTime(s),
            busy: model.busy.contains(s.name),
            onOpen: { open(s.name) },
            onReply: { open(s.name, reply: true) },
            onAnswer: { text in Task { await model.answer(s, text, app: app) } }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { pendingDelete = s } label: { Label("Xoá", systemImage: "trash") }
                .tint(.red)
            Button { model.toggleRead(s) } label: {
                Label(unread ? "Đã đọc" : "Chưa đọc", systemImage: unread ? "envelope.open" : "envelope.badge")
            }
            .tint(.blue)
        }
    }
}

/// One session in the inbox. Waiting: full preview + answer buttons; running: one-line preview
/// and an activity bar; idle: compact and dimmed.
struct SessionRow: View {
    let session: OverviewSession
    let info: ProjectInfo?
    let showProject: Bool
    let unread: Bool
    let time: String
    let busy: Bool
    let onOpen: () -> Void
    let onReply: () -> Void
    let onAnswer: (String) -> Void

    private var state: String {
        ["waiting", "running"].contains(session.state ?? "") ? session.state! : "idle"
    }

    var body: some View {
        if state == "waiting" {
            content
        } else {
            Button(action: onOpen) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        let idle = state == "idle"
        return HStack(alignment: .top, spacing: 12) {
            HarnessAvatar(harness: session.harness ?? "shell", side: idle ? 28 : 34)
                .opacity(idle ? 0.7 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.system(.subheadline, design: .monospaced, weight: idle ? .medium : .semibold))
                        .foregroundColor(idle ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if unread {
                        Circle().fill(Color(uiColor: .systemBlue)).frame(width: 8, height: 8)
                            .accessibilityLabel("chưa đọc")
                    }
                    Spacer(minLength: 4)
                    Text(time)
                        .font(.footnote)
                        .foregroundColor(state == "waiting" ? .orange : .secondary)
                }
                .frame(minHeight: idle ? 28 : 20)
                if !idle { meta }
                if state == "waiting" {
                    if let preview = session.preview, !preview.isEmpty {
                        Text(preview).font(.subheadline).foregroundColor(.primary).padding(.top, 4)
                    }
                    // The pills' 44 pt hit areas add 6 pt above them, so less padding here.
                    actions.padding(.top, 2)
                } else if state == "running" {
                    if let preview = session.preview, !preview.isEmpty {
                        Text(preview).font(.subheadline).foregroundColor(.secondary).lineLimit(1).padding(.top, 2)
                    }
                    LiveBar().padding(.top, 6)
                }
            }
        }
        .padding(.vertical, idle ? 0 : 4)
        // Waiting rows keep their answer buttons as separate VoiceOver elements.
        .accessibilityElement(children: state == "waiting" ? .contain : .combine)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if showProject, let p = session.project {
                Text(p)
                Text("·")
            }
            if let branch = info?.branch, !branch.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.caption2)
                    Text(branch).font(.system(.caption, design: .monospaced))
                }
                .lineLimit(1)
            }
            if state == "running", let diff = info?.diff {
                (Text("+\(diff.add)").foregroundColor(Color(uiColor: .systemGreen))
                    + Text(" −\(diff.del)").foregroundColor(Color(uiColor: .systemRed)))
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(minHeight: 17)
                    .background(Color(uiColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
                    .accessibilityLabel("thêm \(diff.add) dòng, bớt \(diff.del) dòng")
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if OverviewModel.isYesNo(session.preview) {
                pill("y · Đồng ý", fill: Color(uiColor: .systemGreen), text: .black) { onAnswer("y") }
                pill("n · Từ chối", fill: Color(uiColor: .tertiarySystemFill), text: .primary) { onAnswer("n") }
            } else {
                pill("Trả lời", fill: Color(uiColor: .tertiarySystemFill), text: .accentColor, action: onReply)
            }
            pill("Mở", fill: Color(uiColor: .tertiarySystemFill), text: .accentColor, action: onOpen)
            if busy { ProgressView().padding(.leading, 2) }
        }
        .disabled(busy)
    }

    private func pill(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // 32 pt capsule look, 44 pt tall hit area.
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(text)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(fill, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(busy ? 0.5 : 1)
    }
}

/// 9 pt state dot: waiting orange, running green with a soft pulse, idle grey.
struct StatusDot: View {
    let state: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let color: Color = state == "waiting" ? .orange : state == "running" ? Color(uiColor: .systemGreen) : Color(uiColor: .systemGray)
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .background(
                Circle()
                    .stroke(color.opacity(pulse ? 0 : 0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 2.3 : 1)
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
            LinearGradient(colors: [.clear, Color(uiColor: .systemGreen), .clear], startPoint: .leading, endPoint: .trailing)
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

/// Floating translucent dock: Tất cả / omp / claude / codex / shell, filtering the list.
struct HarnessDock: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(["all"] + HarnessStyle.all, id: \.self) { h in
                let selected = selection == h
                let color = HarnessStyle.color(h)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selection = h }
                } label: {
                    VStack(spacing: 3) {
                        HarnessGlyph(harness: h, size: 16).frame(height: 20)
                        Text(h == "all" ? "Tất cả" : h)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundColor(selected ? color : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected ? color.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(h == "all" ? "Tất cả chương trình" : h)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 15, y: 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lọc theo chương trình")
    }
}

/// "+" sheet: always a NEW session (A5 update 4). Step 1 picks the harness, unless the dock
/// already filters one; step 2 picks the project and calls POST /api/open {fresh:true}.
struct NewSessionSheet: View {
    /// nil while the overview has not loaded (or failed to load).
    let projects: [String]?
    let loadError: String?
    let sessions: [OverviewSession]
    let fixedHarness: String?
    let onOpened: (String) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// The project whose POST /api/open is in flight; the sheet cannot be closed meanwhile.
    @State private var opening: String?

    var body: some View {
        NavigationStack {
            Group {
                if let h = fixedHarness {
                    projectStep(h, skipped: true)
                } else {
                    harnessStep
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }.disabled(opening != nil)
                }
            }
        }
        .interactiveDismissDisabled(opening != nil)
    }

    private func projectStep(_ h: String, skipped: Bool) -> some View {
        NewSessionProjects(harness: h, skipped: skipped, projects: projects, loadError: loadError,
                           sessions: sessions, opening: $opening, onOpened: finish)
    }

    private func finish(_ name: String) {
        onOpened(name)
        dismiss()
    }

    private var harnessStep: some View {
        List {
            Section {
                ForEach(HarnessStyle.all, id: \.self) { h in
                    NavigationLink(value: h) {
                        HStack(spacing: 12) {
                            HarnessAvatar(harness: h)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h).font(.system(.body, design: .monospaced, weight: .semibold))
                                Text(HarnessStyle.description(h)).font(.footnote).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Bước 1/2 · Chọn chương trình").textCase(nil).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Phiên mới")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { h in projectStep(h, skipped: false) }
    }
}

private struct NewSessionProjects: View {
    let harness: String
    let skipped: Bool
    let projects: [String]?
    let loadError: String?
    let sessions: [OverviewSession]
    @Binding var opening: String?
    let onOpened: (String) -> Void
    @EnvironmentObject private var app: AppState
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                if projects == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chưa tải được danh sách dự án").foregroundColor(.secondary)
                        if let loadError = loadError {
                            Text(loadError).font(.footnote).foregroundColor(.red)
                        }
                    }
                } else if projects?.isEmpty == true {
                    Text("Chưa có dự án nào trong cấu hình máy chủ.").foregroundColor(.secondary)
                }
                ForEach(projects ?? [], id: \.self) { p in
                    Button { Task { await open(p) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .font(.body)
                                .foregroundColor(.accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p).foregroundColor(.primary)
                                Text(detail(p)).font(.footnote).foregroundColor(.secondary)
                            }
                            Spacer()
                            if opening == p {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(Color(uiColor: .tertiaryLabel))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(opening != nil)
                }
            } header: {
                HStack(spacing: 4) {
                    Text(skipped ? "Chọn dự án để mở" : "Bước 2/2 · Chọn dự án để mở")
                    HarnessBadge(harness: harness)
                }
                .textCase(nil)
                .frame(maxWidth: .infinity)
            } footer: {
                Text(skipped ? "Đang lọc theo \(harness) ở thanh dưới, nên bỏ qua bước chọn chương trình."
                             : "Phiên mới chạy trong thư mục dự án trên box.")
            }
            if let errorText = errorText {
                Section { Label(errorText, systemImage: "exclamationmark.triangle").foregroundColor(.red) }
            }
        }
        .navigationTitle("Phiên \(harness) mới")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(opening != nil)
    }

    private func detail(_ project: String) -> String {
        let n = sessions.filter { $0.project == project && ($0.harness ?? "shell") == harness }.count
        return n > 0 ? "Phiên mới · đang có \(n) phiên \(harness)" : "Phiên mới"
    }

    private func open(_ project: String) async {
        guard let api = app.api, opening == nil else { return }
        opening = project
        defer { opening = nil }
        do {
            let reply = try await api.openFresh(project: project, harness: harness)
            errorText = nil
            onOpened(reply.name)
        } catch {
            if let e = error as? APIError, e.status == 500, e.code == "harness_exited" {
                errorText = "Không mở được \(harness) trên box (chương trình thoát ngay)."
            } else {
                errorText = app.report(error)
            }
        }
    }
}

/// Global leading edge of the inbox header row (see `railInset`).
private struct RailInsetKey: PreferenceKey {
    static var defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
