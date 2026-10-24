import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var app: AppState
    @State private var server = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Form {
            if let notice = app.notice {
                Section { Label(notice, systemImage: "exclamationmark.circle").foregroundColor(.orange) }
            }
            Section {
                TextField("https://…", text: $server)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Địa chỉ máy chủ")
            } footer: {
                Text("Địa chỉ công khai của box, bắt đầu bằng https://")
            }
            Section("Mật khẩu") {
                SecureField("Mật khẩu", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(login)
            }
            Section {
                Button(action: login) {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("Đăng nhập").bold() }
                        Spacer()
                    }
                }
                .disabled(busy || server.isEmpty || password.isEmpty)
            }
            if let errorText = errorText {
                Section { Label(errorText, systemImage: "xmark.octagon").foregroundColor(.red) }
            }
        }
        .navigationTitle("Đăng nhập")
        .onAppear { if server.isEmpty { server = app.serverURL } }
    }

    private func login() {
        guard !busy, !server.isEmpty, !password.isEmpty else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await app.login(server: server, password: password)
            } catch {
                errorText = vietnameseMessage(error, login: true)
            }
            busy = false
        }
    }
}
