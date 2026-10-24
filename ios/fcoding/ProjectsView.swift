import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var app: AppState
    @State private var path: [String] = []
    @State private var meta: Meta?
    @State private var sessions: [SessionInfo] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var harness = "omp"
    @State private var opening: String?
    @State private var pendingDelete: SessionInfo?
    @State private var showSettings = false

    private var harnesses: [String] {
        let list = meta?.harnesses ?? []
        return list.isEmpty ? ["omp", "claude", "codex", "shell"] : list
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorText = errorText {
                    Section { Label(errorText, systemImage: "exclamationmark.triangle").foregroundColor(.red) }
                }
                projectSection
                sessionSection
            }
            .navigationTitle("fcoding")
            .navigationDestination(for: String.self) { SessionView(name: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Cài đặt")
                }
            }
            .refreshable { await load() }
            .onAppear { Task { await load() } }
            .confirmationDialog(
                "Xoá phiên \(pendingDelete?.name ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { s in
                Button("Xoá phiên", role: .destructive) { Task { await delete(s) } }
                Button("Huỷ", role: .cancel) {}
            } message: { _ in
                Text("Chương trình đang chạy trong phiên này sẽ bị tắt.")
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app) }
        }
    }

    private var projectSection: some View {
        Section {
            Picker("Chương trình", selection: $harness) {
                ForEach(harnesses, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            if meta == nil {
                if loading { HStack(spacing: 10) { ProgressView(); Text("Đang tải…").foregroundColor(.secondary) } }
            } else if meta?.projects.isEmpty == true {
                Text("Chưa có dự án nào trong cấu hình máy chủ.").foregroundColor(.secondary)
            }
            ForEach(meta?.projects ?? [], id: \.self) { project in
                Button { Task { await open(project) } } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(project).foregroundColor(.primary)
                        Spacer()
                        if opening == project { ProgressView() } else { Image(systemName: "chevron.right").foregroundColor(.secondary) }
                    }
                    .frame(minHeight: 36)
                }
                .disabled(opening != nil)
            }
        } header: {
            Text("Mở dự án")
        } footer: {
            Text("Chạm vào một dự án để mở phiên \(harness) (tạo mới nếu chưa có).")
        }
    }

    private var sessionSection: some View {
        Section("Phiên đang chạy") {
            if sessions.isEmpty && !loading {
                Text("Chưa có phiên nào.").foregroundColor(.secondary)
            }
            ForEach(sessions) { s in
                NavigationLink(value: s.name) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.system(.body, design: .monospaced))
                        if !s.subtitle.isEmpty {
                            Text(s.subtitle).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions {
                    Button { pendingDelete = s } label: { Label("Xoá", systemImage: "trash") }
                        .tint(.red)
                }
                .contextMenu {
                    Button(role: .destructive) { pendingDelete = s } label: { Label("Xoá phiên", systemImage: "trash") }
                }
            }
        }
    }

    private func load() async {
        guard let api = app.api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let m = api.get("api/meta", as: Meta.self)
            async let s = api.get("api/sessions", as: SessionsResponse.self)
            let (newMeta, newSessions) = try await (m, s)
            meta = newMeta
            sessions = newSessions.sessions.sorted { $0.name < $1.name }
            if !harnesses.contains(harness), let first = harnesses.first { harness = first }
            errorText = nil
        } catch {
            errorText = app.report(error)
        }
    }

    private func open(_ project: String) async {
        guard let api = app.api else { return }
        let harness = self.harness
        opening = project
        defer { opening = nil }
        do {
            let data = try await api.call("POST", "api/open", body: ["project": project, "harness": harness])
            let reply = try JSONDecoder().decode(OpenResponse.self, from: data)
            errorText = nil
            path.append(reply.name)
        } catch {
            if let e = error as? APIError, e.status == 500, e.code == "harness_exited" {
                errorText = "Không mở được \(harness) trên box (chương trình thoát ngay)."
            } else {
                errorText = app.report(error)
            }
        }
    }

    private func delete(_ s: SessionInfo) async {
        guard let api = app.api else { return }
        do {
            try await api.call("DELETE", "api/sessions/\(s.name)")
            sessions.removeAll { $0.name == s.name }
            errorText = nil
        } catch {
            errorText = app.report(error)
        }
        await load()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAll = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Máy chủ") {
                    Text(app.serverURL).textSelection(.enabled)
                }
                Section {
                    Button("Đăng xuất trên máy này") { app.logoutHere() }
                    Button(role: .destructive) { confirmAll = true } label: {
                        HStack {
                            Text("Đăng xuất mọi nơi")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                } footer: {
                    Text("“Đăng xuất trên máy này” chỉ xoá đăng nhập trên điện thoại này. “Đăng xuất mọi nơi” thu hồi đăng nhập trên tất cả thiết bị.")
                }
                .disabled(busy)
                if let errorText = errorText {
                    Section {
                        Label(errorText, systemImage: "xmark.octagon").foregroundColor(.red)
                        Button("Thử lại") { logoutEverywhere() }.disabled(busy)
                    } header: {
                        Text("Chưa đăng xuất mọi nơi")
                    }
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .confirmationDialog("Đăng xuất trên mọi thiết bị?", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Đăng xuất mọi nơi", role: .destructive) { logoutEverywhere() }
                Button("Huỷ", role: .cancel) {}
            }
        }
    }

    /// Local credentials stay until the server confirms; a 401 still goes back to login (via report).
    private func logoutEverywhere() {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await app.logoutEverywhere()
            } catch {
                errorText = app.report(error)
            }
            busy = false
        }
    }
}
