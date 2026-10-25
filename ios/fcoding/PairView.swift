import SwiftUI

/// "Ghép máy": server address + the 6-digit code that `fcode-pair` prints on the box.
/// A `fcode://pair` link (QR) fills only the server and asks "Ghép với máy chủ <host>?"; the
/// user types the code shown on the old device and taps "Ghép". While paired (a sheet in the
/// overlay window), it first asks inline whether to re-pair at all. Instructions live behind
/// the "Hướng dẫn" button, not in footers.
struct PairView: View {
    @EnvironmentObject private var app: AppState
    @State private var server = ""
    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    /// Paired + link: the user has said "Ghép lại" to this link.
    @State private var repairOK = false
    @State private var showGuide = false
    @FocusState private var focus: Field?

    private enum Field { case server, code }

    private var canPair: Bool { !busy && code.count == 6 && AppState.normalize(server) != nil }
    /// Origin of the address in the field, for the link confirmation.
    private var linkServer: String? {
        guard app.pairLink != nil, let url = AppState.normalize(server) else { return nil }
        return url.absoluteString
    }

    /// Paired and a link is waiting for the "Ghép lại?" answer: only that question is shown.
    /// Not from the unsupported-server card: the card already says why pairing again is needed.
    private var asking: Bool {
        app.token != nil && app.pairLink != nil && app.unsupportedServer == nil && !repairOK
    }

    var body: some View {
        Form {
            if asking {
                Section {
                    Text("Thiết bị này đã ghép. Ghép lại với máy chủ mới?").font(.headline)
                    Text("Đang ghép với \(PairLink.label(app.serverURL)). Máy chủ mới: \(PairLink.label(app.pairLink?.server ?? "")).")
                        .foregroundColor(.secondary)
                    Button("Ghép lại") { repairOK = true }
                    Button("Huỷ", role: .cancel) { app.cancelPairing() }
                }
            } else {
                fields
            }
        }
        .navigationTitle("Ghép máy")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // Re-pair from a link while paired: a way back without pairing.
            if app.token != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { app.cancelPairing() }.disabled(busy)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Hướng dẫn")
            }
        }
        .sheet(isPresented: $showGuide) { PairGuideView() }
        .interactiveDismissDisabled(busy)
        .onAppear {
            if app.pairLink != nil { applyLink(); return }
            if server.isEmpty { server = app.serverURL }
            focus = server.isEmpty ? .server : .code
        }
        .onChange(of: app.pairLink) { _ in applyLink() }
        // After "Ghép lại": the code field appears in this update, so focus it on the next one.
        .onChange(of: repairOK) { ok in if ok { DispatchQueue.main.async { focus = .code } } }
    }

    @ViewBuilder private var fields: some View {
        if let notice = app.notice {
            Section { Label(notice, systemImage: "exclamationmark.circle").foregroundColor(.orange) }
        }
        if let linked = linkServer {
            Section {
                // The host exactly as connected to (ASCII only), with the safety line as part of
                // the question itself.
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text("Ghép với máy chủ ") + Text(PairLink.label(linked)).bold() + Text("?"))
                            .font(.headline)
                        Text("Chỉ ghép nếu đây là box của bạn.").font(.subheadline).foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "qrcode")
                }
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
        }
        .disabled(busy)
        Section {
            codeField
        } header: {
            Text("Mã ghép")
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

    private var pairTitle: String { app.pairLink == nil ? "Ghép iPhone này" : "Ghép" }

    /// Fills the server from the pending link and asks for the code; never pairs by itself.
    /// While paired, a new link asks "Ghép lại?" again first.
    private func applyLink() {
        guard let link = app.pairLink, !busy else { return }
        server = link.server
        code = ""
        errorText = nil
        repairOK = false
        focus = app.token == nil ? .code : nil
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
                app.card(.pairFail)   // from the card: nothing is deleted
                if let e = error as? APIError, e.status == 401 {
                    if app.pairLink != nil { errorText = "Mã sai hoặc đã hết hạn. Gõ lại mã đang hiện trên iPhone cũ; hết hạn thì bấm “Tạo mã mới” ở đó." }
                    code = ""
                    focus = .code
                }
            }
            busy = false
        }
    }
}

/// Full-screen card when an older build paired this iPhone to an address this build no
/// longer accepts. Both buttons are local only: nothing is sent to that server.
struct UnsupportedServerView: View {
    @EnvironmentObject private var app: AppState
    let address: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            (Text("Địa chỉ máy chủ đã lưu không còn được hỗ trợ (") + Text(address).font(.body.monospaced())
                + Text("). Ghép lại để tiếp tục."))
                .multilineTextAlignment(.center)
            Text("Chỉ dùng được tên miền chữ thường không dấu, có dấu chấm (ví dụ box.instabox.tech), hoặc địa chỉ IP.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            // Only opens pairing; Huỷ there comes back here with everything kept.
            Button { app.card(.pairAgain) } label: {
                Text("Ghép lại").bold().frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Đăng xuất", role: .destructive) { app.card(.signOut) }
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .alert("Xoá đăng nhập trên iPhone này?",
               isPresented: Binding(get: { app.cardState == .confirmSignOut },
                                    set: { if !$0 && app.cardState == .confirmSignOut { app.card(.signOutCancel) } })) {
            Button("Xoá đăng nhập", role: .destructive) { app.card(.signOutConfirm) }
            Button("Huỷ", role: .cancel) { app.card(.signOutCancel) }
        } message: {
            Text("Box cũ vẫn giữ iPhone này trong danh sách thiết bị.")
        }
    }
}

/// "Hướng dẫn" (question-mark button on the pairing and settings screens): every instruction
/// that used to sit in small footers, as short numbered steps.
struct PairGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let topics: [(title: String, steps: [String])] = [
        ("Ghép iPhone lần đầu", [
            "Trên box gõ lệnh fcode-pair (trên máy tính: fcode pair). Màn hình hiện mã 6 số.",
            "Trên iPhone, ô “Địa chỉ máy chủ”: gõ địa chỉ công khai của box, bắt đầu bằng https://.",
            "Ô “Mã ghép”: gõ 6 số đó, rồi bấm “Ghép iPhone này”.",
        ]),
        ("Thêm iPhone mới bằng mã QR", [
            "Trên iPhone đã ghép: Cài đặt (bánh răng) → “Thêm thiết bị (mã QR)” → “Tạo mã”. Màn hình hiện mã QR và mã 6 số.",
            "Trên iPhone mới (đã cài FCode): mở Camera, quét mã QR, chạm “Mở trong FCode”. Địa chỉ máy chủ tự điền.",
            "Gõ mã 6 số đang hiện trên iPhone cũ (hoặc trên máy tính), rồi bấm “Ghép”.",
            "Không quét được: trên iPhone cũ bấm “Gửi link”, gửi qua AirDrop hoặc Zalo, rồi mở link trên iPhone mới. Link chỉ có địa chỉ máy chủ, không có mã.",
        ]),
        ("Mã ghép hết hạn", [
            "Mỗi mã chỉ dùng được 1 lần và hết hạn sau 2 phút. Đồng hồ trên iPhone cũ cho biết còn bao lâu.",
            "Gõ sai: gõ lại mã đang hiện trên iPhone cũ.",
            "Hết hạn hoặc muốn đổi mã: bấm “Tạo mã mới” trên iPhone cũ (hoặc gõ lại fcode-pair). Mã cũ không dùng được nữa; nhập mã mới.",
        ]),
        ("An toàn", [
            "Ai có mã cũng vào được box của bạn. Chỉ đọc mã cho chính bạn; không gửi mã qua tin nhắn.",
            "Chỉ bấm “Ghép” khi địa chỉ máy chủ đúng là box của bạn.",
            "Ghép sang một box khác thì nội dung đang soạn của box cũ bị xoá.",
        ]),
        ("Gỡ thiết bị", [
            "“Gỡ iPhone này”: gỡ điện thoại này khỏi box. iPhone này luôn được xoá ghép, kể cả khi box không trả lời.",
            "“Gỡ mọi thiết bị”: gỡ mọi thiết bị đã ghép với box. iPhone này chỉ đăng xuất khi box xác nhận.",
            "Muốn dùng lại: ghép lại như trên.",
        ]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(topics, id: \.title) { topic in
                    Section(topic.title) {
                        ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1).").monospacedDigit().foregroundColor(.secondary)
                                Text(step)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hướng dẫn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
