import CoreImage.CIFilterBuiltins
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
    @State private var showGuide = false

    private enum Action { case here, all }

    var body: some View {
        NavigationStack {
            Form {
                Section("Máy chủ") {
                    Text(app.serverURL).textSelection(.enabled)
                }
                Section {
                    NavigationLink { AddDeviceView() } label: {
                        Label("Thêm thiết bị (mã QR)", systemImage: "qrcode")
                    }
                }
                .disabled(running != nil)
                Section {
                    Button { run(.here) } label: { row("Gỡ iPhone này", .here) }
                    Button(role: .destructive) { confirmAll = true } label: { row("Gỡ mọi thiết bị", .all) }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("Hướng dẫn")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .sheet(isPresented: $showGuide) { PairGuideView() }
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

/// "Thêm thiết bị (mã QR)": on the tap of "Tạo mã", POST /api/pair-code. The QR holds only
/// the server (contract DECISION r2); the 6-digit code is shown in big digits for the user to
/// type on the new iPhone. Live countdown on this phone's clock; a share link with the server.
struct AddDeviceView: View {
    @EnvironmentObject private var app: AppState
    @State private var reply: PairCodeResponse?
    /// Expiry on this phone's clock (see API.pairCode).
    @State private var expires = Date()
    @State private var qr: UIImage?
    @State private var showGuide = false
    /// A code was made on this screen before, so the button says "Tạo mã mới".
    @State private var made = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if let reply = reply {
                let left = Int(expires.timeIntervalSince(now).rounded(.up))
                Section {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { qrView(left); codeView(reply.code, left) }
                        VStack(spacing: 16) { qrView(left); codeView(reply.code, left) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Section {
                    if left > 0, let link = URL(string: reply.shareLink) {
                        ShareLink(item: link, message: Text("Mở link này trên iPhone mới để mở FCode với địa chỉ máy chủ.")) {
                            Label("Gửi link", systemImage: "square.and.arrow.up")
                        }
                    }
                    // Always there: a new code replaces this phone's live one on the box.
                    makeButton
                }
            } else {
                Section { makeButton }
            }
            if let errorText = errorText {
                Section { Label(errorText, systemImage: "xmark.octagon").foregroundColor(.red) }
            }
        }
        .navigationTitle("Thêm thiết bị")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Hướng dẫn")
            }
        }
        .sheet(isPresented: $showGuide) { PairGuideView() }
        .onReceive(tick) { now = $0 }
    }

    private func qrView(_ left: Int) -> some View {
        Group {
            if let qr = qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(22)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(left > 0 ? 1 : 0.15)
                    .accessibilityLabel(left > 0 ? "Mã QR địa chỉ máy chủ, để quét bằng iPhone mới"
                                                 : "Mã QR đã hết hạn")
            }
        }
    }

    private func codeView(_ code: String, _ left: Int) -> some View {
        VStack(spacing: 8) {
            Text(spaced(code))
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundColor(left > 0 ? .primary : .secondary)
                .accessibilityLabel((left > 0 ? "Mã ghép " : "Mã đã hết hạn ") + code.map(String.init).joined(separator: " "))
            Text(left > 0 ? "còn \(left / 60):" + String(format: "%02d", left % 60) : "Mã đã hết hạn")
                .font(.headline.monospacedDigit())
                .foregroundColor(left > 0 ? .secondary : .orange)
                .accessibilityAddTraits(.updatesFrequently)
            if left > 0 {
                Label("Không gửi mã cho người khác", systemImage: "lock")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var makeButton: some View {
        Button { Task { await load() } } label: {
            HStack {
                Label(made ? "Tạo mã mới" : "Tạo mã", systemImage: "qrcode")
                Spacer()
                if loading { ProgressView() }
            }
        }
        .disabled(loading)
    }

    private func load() async {
        guard let api = app.api, !loading else { return }
        loading = true
        errorText = nil
        do {
            let r = try await api.pairCode()
            qr = AddDeviceView.qrImage(r.reply.appLink)
            expires = r.expires
            now = Date()
            reply = r.reply
            made = true
        } catch {
            var message: String?
            if let e = error as? APIError, [404, 405, 501].contains(e.status) {
                message = "Máy chủ chưa hỗ trợ, cập nhật máy chủ trước."
            } else if let e = error as? APIError, e.status == 409, e.code == "no_public_url" {
                message = "Máy chủ chưa đặt địa chỉ công khai (publicUrl), cập nhật cấu hình máy chủ trước."
            } else {
                message = app.report(error)
            }
            if reply != nil {
                // The box may already have replaced the old code: never leave it on screen.
                reply = nil
                qr = nil
                if message != nil { message = "Không tạo được mã mới. Bấm Tạo mã mới để thử lại." }
            }
            errorText = message
        }
        loading = false
    }

    private func spaced(_ code: String) -> String {
        code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code
    }

    /// Crisp black-on-white QR (one pixel per module; `.interpolation(.none)` scales it up).
    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
