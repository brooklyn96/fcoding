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
                } footer: {
                    Text("Ghép một iPhone khác với box này mà không phải gõ địa chỉ.")
                }
                .disabled(running != nil)
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

/// "Thêm thiết bị (mã QR)": POST /api/pair-code, then a QR of the app link for the new
/// iPhone's Camera, the 6-digit code, a live countdown and a share link.
struct AddDeviceView: View {
    @EnvironmentObject private var app: AppState
    @State private var reply: PairCodeResponse?
    @State private var qr: UIImage?
    @State private var minutes = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if let reply = reply {
                let left = Int(reply.expiresAt.timeIntervalSince(now).rounded(.up))
                Section {
                    VStack(spacing: 16) {
                        if let qr = qr {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 240)
                                .padding(24)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .opacity(left > 0 ? 1 : 0.15)
                                .accessibilityLabel("Mã QR để ghép iPhone mới")
                        }
                        Text(spaced(reply.code))
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .foregroundColor(left > 0 ? .primary : .secondary)
                            .accessibilityLabel("Mã ghép " + reply.code.map(String.init).joined(separator: " "))
                        Text(left > 0 ? "còn \(left / 60):" + String(format: "%02d", left % 60) : "Mã đã hết hạn")
                            .font(.headline.monospacedDigit())
                            .foregroundColor(left > 0 ? .secondary : .orange)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } footer: {
                    Text("Quét mã bằng Camera của iPhone mới, rồi bấm Ghép trong app FCode. Mã dùng 1 lần, hết hạn sau \(minutes) phút.")
                }
                Section {
                    if left > 0 {
                        if let link = URL(string: reply.shareLink) {
                            ShareLink(item: link, message: Text("Mở link này trên iPhone mới để ghép với FCode.")) {
                                Label("Gửi link", systemImage: "square.and.arrow.up")
                            }
                        }
                    } else {
                        newCodeButton
                    }
                }
            } else if loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Đang tạo mã…").foregroundColor(.secondary)
                    }
                }
            }
            if let errorText = errorText {
                Section {
                    Label(errorText, systemImage: "xmark.octagon").foregroundColor(.red)
                    if reply == nil { newCodeButton }
                }
            }
        }
        .navigationTitle("Thêm thiết bị")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
        .task { if reply == nil && !loading { await load() } }
    }

    private var newCodeButton: some View {
        Button { Task { await load() } } label: {
            HStack {
                Text(reply == nil ? "Thử lại" : "Tạo mã mới")
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
            qr = AddDeviceView.qrImage(r.appLink)
            minutes = max(1, Int((r.expiresAt.timeIntervalSinceNow / 60).rounded()))
            now = Date()
            reply = r
        } catch let e as APIError where [404, 405, 501].contains(e.status) {
            errorText = "Máy chủ chưa hỗ trợ, cập nhật máy chủ trước."
        } catch {
            errorText = app.report(error)
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
