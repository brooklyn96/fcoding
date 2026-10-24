import SwiftUI

/// Settings sheet: server address and the two unpair actions. Both clear the Keychain token
/// on this phone even when the request fails; a failure is shown on the pairing screen.
struct DeviceSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAll = false
    @State private var running: Action?

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
                    Text("“Gỡ iPhone này” gỡ điện thoại này khỏi box. “Gỡ mọi thiết bị” gỡ tất cả thiết bị đã ghép. Muốn dùng lại thì gõ fcode-pair trên box và ghép lại.")
                }
                .disabled(running != nil)
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
        Task {
            switch action {
            case .here: await app.logoutHere().value
            case .all: await app.logoutEverywhere()
            }
            running = nil
        }
    }
}
