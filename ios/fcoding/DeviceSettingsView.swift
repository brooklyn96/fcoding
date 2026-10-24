import SwiftUI

/// Settings sheet: server address and the two unpair actions. "Gỡ iPhone này" always clears
/// this phone (a box failure is shown on the pairing screen). "Gỡ mọi thiết bị" clears it only
/// after the box confirms; otherwise it stays signed in and offers "Thử lại" here.
struct DeviceSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAll = false
    @State private var running: Action?
    @State private var allError: String?

    private enum Action { case here, all }

    var body: some View {
        NavigationStack {
            Form {
                Section("Máy chủ") {
                    Text(app.serverURL).textSelection(.enabled)
                }
                Section {
                    Button { run(.here) } label: { row("Gỡ iPhone này", .here) }
                    Button(role: .destructive) { confirmAll = true } label: { row("Gỡ mọi thiết bị", .all) }
                } footer: {
                    Text("“Gỡ iPhone này” gỡ điện thoại này khỏi box. “Gỡ mọi thiết bị” gỡ tất cả thiết bị đã ghép; iPhone này chỉ đăng xuất khi box xác nhận. Muốn dùng lại thì gõ fcode-pair trên box và ghép lại.")
                }
                .disabled(running != nil)
                if let allError = allError {
                    Section {
                        Label(allError, systemImage: "xmark.octagon").foregroundColor(.red)
                        Button { run(.all) } label: { row("Thử lại", .all) }
                            .disabled(running != nil)
                    }
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .confirmationDialog("Gỡ mọi thiết bị khỏi box?", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Gỡ mọi thiết bị", role: .destructive) { run(.all) }
                Button("Huỷ", role: .cancel) {}
            }
        }
    }

    private func row(_ title: String, _ action: Action) -> some View {
        HStack {
            Text(title)
            Spacer()
            if running == action { ProgressView() }
        }
    }

    private func run(_ action: Action) {
        guard running == nil else { return }
        running = action
        if action == .all { allError = nil }
        Task {
            switch action {
            case .here: await app.logoutHere().value
            case .all: allError = await app.logoutEverywhere()
            }
            running = nil
        }
    }
}
