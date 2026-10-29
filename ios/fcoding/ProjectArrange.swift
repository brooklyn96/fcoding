import SwiftUI

// MARK: - GET / PUT /api/prefs (project order + display names, shared with the laptop)

/// The server holds the prefs; this phone keeps the last good copy so the home screen shows
/// the user's order and names at once, before the GET answers.
@MainActor
final class PrefsModel: ObservableObject {
    @Published private(set) var prefs: ProjectPrefs
    private static let cacheKey = "projects.prefs"
    /// Saves started so far; a GET that began before one is dropped (it may carry the old prefs).
    private var saves = 0
    private var saving = false

    init() {
        let data = UserDefaults.standard.data(forKey: PrefsModel.cacheKey)
        prefs = data.flatMap { try? JSONDecoder().decode(ProjectPrefs.self, from: $0) } ?? ProjectPrefs()
    }

    func displayName(_ project: String) -> String { HomeLogic.displayName(project, aliases: prefs.aliases) }

    /// A failed GET keeps what is shown (HomeModel already reports a 401).
    func load(_ app: AppState) async {
        guard let api = app.api, !saving else { return }
        let at = saves
        guard let reply = try? await api.get("api/prefs", as: ProjectPrefs.self), at == saves, !saving else { return }
        keep(reply)
    }

    /// PUT the new prefs; shown at once, put back as they were when the box refuses. Returns the
    /// error text (the server's own message for a 400), nil on success.
    func save(_ new: ProjectPrefs, app: AppState) async -> String? {
        guard let api = app.api else { return unpairedNotice }
        let old = prefs
        saves += 1
        saving = true
        defer { saving = false }
        prefs = new
        do {
            let data = try await api.call("PUT", "api/prefs", body: ["order": new.order, "aliases": new.aliases])
            keep((try? JSONDecoder().decode(ProjectPrefs.self, from: data)) ?? new)
            return nil
        } catch {
            prefs = old
            if let e = error as? APIError {
                if e.status == 400 && e.code.contains(" ") { return e.code }
                if [404, 405, 501].contains(e.status) {
                    return "Máy chủ chưa hỗ trợ lưu thứ tự và tên dự án, cập nhật máy chủ trước."
                }
            }
            return app.report(error) ?? "Không lưu được, thử lại."
        }
    }

    private func keep(_ p: ProjectPrefs) {
        prefs = p
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: PrefsModel.cacheKey) }
    }
}

// MARK: - "Sắp xếp & đổi tên": drag to reorder, a display name per project

struct ProjectArrangeSheet: View {
    /// The projects in the order shown on the home screen.
    let projects: [String]
    let prefs: ProjectPrefs
    let save: (ProjectPrefs) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var order: [String] = []
    @State private var typed: [String: String] = [:]
    /// The names as the sheet opened: only a field the user changed is sent, so a GET that lands
    /// meanwhile (another device's edit, in `prefs`) is not written back over.
    @State private var seed: [String: String] = [:]
    /// The order as the sheet opened: only a drag by the user sends a new order.
    @State private var orderSeed: [String] = []
    @State private var saving = false
    @State private var errorText: String?
    @State private var confirmReset = false

    private var edited: ProjectPrefs {
        var aliases = prefs.aliases
        for p in order where typed[p] != seed[p] { aliases = HomeLogic.settingAlias(aliases, p, typed[p] ?? "") }
        // A names-only edit keeps the saved order (new projects keep their server place).
        return ProjectPrefs(order: order == orderSeed ? prefs.order : order, aliases: aliases)
    }

    private var changed: Bool { order != orderSeed || edited.aliases != prefs.aliases }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { row($0) }
                        .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let errorText = errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle")
                                .foregroundColor(.redTone)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Kéo ≡ để đổi thứ tự. Tên hiển thị dùng được cả trên laptop (fcode); máy chủ vẫn dùng tên repo. Để trống = tên repo.")
                            .foregroundColor(.l2)
                    }
                    .scaledFont(13)
                    .padding(.top, 6)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .disabled(saving)
            .navigationTitle("Sắp xếp & đổi tên")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Lưu", action: submit).disabled(!changed) }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Đặt lại", role: .destructive) { confirmReset = true }
                        .foregroundColor(.redTone)
                        .disabled(saving || (prefs.order.isEmpty && prefs.aliases.isEmpty))
                }
            }
            .confirmationDialog("Đặt lại thứ tự và tên?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Đặt lại", role: .destructive) { run(ProjectPrefs()) }
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Dự án về lại thứ tự của máy chủ và tên repo, trên mọi thiết bị.")
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving || changed)
        .onAppear {
            order = projects
            orderSeed = projects
            typed = Dictionary(uniqueKeysWithValues: projects.map { ($0, HomeLogic.cleanAlias(prefs.aliases[$0] ?? "")) })
            seed = typed
        }
    }

    private func row(_ p: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(p, text: Binding(get: { typed[p] ?? "" },
                                       set: { typed[p] = String($0.prefix(HomeLogic.aliasMax)) }))
                .scaledFont(16, weight: .semibold)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityLabel("Tên hiển thị cho \(p)")
            Text(p)
                .scaledFont(12, design: .monospaced)
                .foregroundColor(.l2)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.grp)
    }

    private func submit() {
        if let problem = HomeLogic.aliasProblem(edited.aliases, projects: projects) {
            errorText = problem
            return
        }
        run(edited)
    }

    private func run(_ p: ProjectPrefs) {
        guard !saving else { return }
        saving = true
        errorText = nil
        Task {
            let failure = await save(p)
            saving = false
            if let failure = failure { errorText = failure } else { dismiss() }
        }
    }
}

// MARK: - "Đổi tên hiển thị…" for one project (long press on its card)

struct ProjectAliasSheet: View {
    let name: String
    let projects: [String]
    let prefs: ProjectPrefs
    let save: (ProjectPrefs) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorText: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetScaffold {
            SheetHeader(title: "Tên hiển thị", left: ("Huỷ", { dismiss() }), right: ("Lưu", submit), rightBold: true)
                .disabled(saving)
            (Text("Repo: ") + Text(name).font(.system(.subheadline, design: .monospaced)))
                .sheetBody()
            TextField(name, text: Binding(get: { text }, set: { text = String($0.prefix(HomeLogic.aliasMax)) }))
                .scaledFont(15)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(submit)
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.grp2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(saving)
                .accessibilityLabel("Tên hiển thị cho \(name)")
            HStack(spacing: 8) {
                if saving { ProgressView() }
                Text(errorText ?? " ").scaledFont(13).foregroundColor(.redTone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 20)
            .padding(.vertical, 6)
            Text("Dùng được cả trên laptop (fcode). Để trống = tên repo. Tối đa \(HomeLogic.aliasMax) ký tự: chữ, số, dấu cách, - _ .")
                .sheetBody()
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            text = HomeLogic.cleanAlias(prefs.aliases[name] ?? "")
            focused = true
        }
    }

    private func submit() {
        guard !saving else { return }
        let aliases = HomeLogic.settingAlias(prefs.aliases, name, text)
        if aliases == prefs.aliases { dismiss(); return }
        if let problem = HomeLogic.aliasProblem(aliases, projects: projects) {
            errorText = problem
            return
        }
        saving = true
        errorText = nil
        Task {
            let failure = await save(ProjectPrefs(order: prefs.order, aliases: aliases))
            saving = false
            if let failure = failure { errorText = failure } else { dismiss() }
        }
    }
}
