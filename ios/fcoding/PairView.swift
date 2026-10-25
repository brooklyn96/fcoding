import SwiftUI

/// "Ghép máy": server address + the 6-digit code that `fcode-pair` prints on the box.
/// A `fcode://pair` link (QR) fills only the server and asks "Ghép với máy chủ <host>?"; the
/// user types the code shown on the old device and taps "Ghép". While paired (shown as a
/// sheet), it first asks whether to re-pair at all.
struct PairView: View {
    @EnvironmentObject private var app: AppState
    @State private var server = ""
    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var askRepair = false
    @FocusState private var focus: Field?

    private enum Field { case server, code }

    private var canPair: Bool { !busy && code.count == 6 && AppState.normalize(server) != nil }
    /// host[:port] of the address in the field, for the link confirmation.
    private var linkHost: String? {
        guard app.pairLink != nil, let url = AppState.normalize(server) else { return nil }
        return PairLink.label(url.absoluteString)
    }

    var body: some View {
        Form {
            if let notice = app.notice {
                Section { Label(notice, systemImage: "exclamationmark.circle").foregroundColor(.orange) }
            }
            if let host = linkHost {
                Section {
                    Label {
                        Text("Ghép với máy chủ ") + Text(host).bold() + Text("?")
                    } icon: {
                        Image(systemName: "qrcode")
                    }
                    .font(.headline)
                } footer: {
                    Text("Chỉ bấm Ghép nếu đây đúng là box của bạn.")
                }
            }
            Section {
                TextField("https://…", text: $server)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .server)
                    .submitLabel(.next)
                    .onSubmit { focus = .code }
            } header: {
                Text("Địa chỉ máy chủ")
            } footer: {
                Text("Địa chỉ công khai của box, bắt đầu bằng https://")
            }
            .disabled(busy)
            Section {
                codeField
            } header: {
                Text("Mã ghép")
            } footer: {
                if app.pairLink != nil {
                    Text("Nhập mã 6 số đang hiện trên iPhone cũ (hoặc trên máy tính). Hết hạn thì tạo mã mới trên iPhone cũ.")
                } else {
                    Text("Trên box gõ: ") + Text("fcode-pair").font(.footnote.monospaced()) + Text(" — mã có hạn 2 phút")
                }
            }
            .disabled(busy)
            if let errorText = errorText {
                Section { Label(errorText, systemImage: "xmark.octagon").foregroundColor(.red) }
            }
            Section {
                Button(action: pair) {
                    ZStack {
                        Text(pairTitle).bold().opacity(busy ? 0 : 1)
                        if busy { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canPair)
                .accessibilityLabel(busy ? "Đang ghép" : pairTitle)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Ghép máy")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // Re-pair from a link while paired: a way back without pairing.
            if app.token != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { app.pairLink = nil }.disabled(busy)
                }
            }
        }
        .alert("Thiết bị này đã ghép. Ghép lại với máy chủ mới?", isPresented: $askRepair) {
            Button("Ghép lại") {}
            Button("Huỷ", role: .cancel) { app.pairLink = nil }
        } message: {
            Text("Đang ghép với \(PairLink.label(app.serverURL)). Máy chủ mới: \(PairLink.label(app.pairLink?.server ?? "")).")
        }
        .interactiveDismissDisabled(busy)
        .onAppear {
            if app.pairLink != nil { applyLink(); return }
            if server.isEmpty { server = app.serverURL }
            focus = server.isEmpty ? .server : .code
        }
        .onChange(of: app.pairLink) { _ in applyLink() }
        // After "Ghép lại", straight to the code with the number pad.
        .onChange(of: askRepair) { asking in if !asking && app.pairLink != nil { focus = .code } }
    }

    private var pairTitle: String { app.pairLink == nil ? "Ghép iPhone này" : "Ghép" }

    /// Fills the server from the pending link and asks for the code; never pairs by itself.
    private func applyLink() {
        guard let link = app.pairLink, !busy else { return }
        server = link.server
        code = ""
        errorText = nil
        askRepair = app.token != nil
        focus = askRepair ? nil : .code
    }

    /// Six boxes (3 + 3) drawn over a hidden numeric TextField that holds the real input,
    /// so the number pad, one-time-code autofill, paste and VoiceOver all work natively.
    private var codeField: some View {
        let digits = Array(code)
        return HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { digitBox($0, digits) }
            Text("–").font(.title2).foregroundColor(.secondary).padding(.horizontal, 2)
            ForEach(3..<6, id: \.self) { digitBox($0, digits) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
        .background(
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
                .opacity(0.02)
                .accessibilityLabel("Mã ghép 6 số")
                .accessibilityValue(code.isEmpty ? "Chưa nhập" : code.map(String.init).joined(separator: " "))
        )
        .contentShape(Rectangle())
        .onTapGesture { focus = .code }
        .onChange(of: code) { value in
            let clean = String(value.filter { ("0"..."9").contains($0) }.prefix(6))
            if clean != value { code = clean; return }
            // All six in: drop the keyboard so the button below is in view.
            if clean.count == 6 { focus = nil }
        }
    }

    private func digitBox(_ index: Int, _ digits: [Character]) -> some View {
        let active = focus == .code && index == min(digits.count, 5)
        return Text(index < digits.count ? String(digits[index]) : " ")
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .frame(minWidth: 32, maxWidth: 46, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Color.accentColor : Color(.separator), lineWidth: active ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: active)
    }

    private func pair() {
        guard canPair else { return }
        busy = true
        errorText = nil
        focus = nil
        Task {
            do {
                try await app.pair(server: server, code: code)
            } catch {
                errorText = vietnameseMessage(error, pairing: true)
                if let e = error as? APIError, e.status == 401 {
                    if app.pairLink != nil { errorText = "Mã sai hoặc đã hết hạn. Tạo mã mới trên iPhone cũ rồi nhập lại." }
                    code = ""
                    focus = .code
                }
            }
            busy = false
        }
    }
}
