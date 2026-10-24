import SwiftUI

struct SessionView: View {
    let name: String
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: SessionModel
    @AppStorage("fontSize") private var fontSize: Double = 13
    @State private var stoppedInBackground = false

    init(name: String) {
        self.name = name
        _model = StateObject(wrappedValue: SessionModel(name: name))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                TerminalView(model: model, fontSize: fontSize, viewportHeight: geo.size.height)
                    .onAppear { model.resize(to: geo.size, fontSize: fontSize) }
                    .onChange(of: geo.size.width) { _ in model.resize(to: geo.size, fontSize: fontSize) }
                    .onChange(of: fontSize) { newSize in model.resize(to: geo.size, fontSize: newSize) }
            }
            .background(Color.black)

            if let errorText = model.errorText {
                Button { model.errorText = nil } label: {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.85))
                }
                .accessibilityHint("Chạm để ẩn")
            }

            Divider()
            ComposerView(
                draftKey: "draft.\(name)",
                onSend: { text, enter in model.send(text, enter: enter) },
                onKey: { key in model.key(key) }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .overlay { if model.gone { goneView } }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                linkDot
                Button { fontSize = max(9, fontSize - 1) } label: { Text("A-").font(.callout.bold()) }
                    .accessibilityLabel("Chữ nhỏ hơn")
                    .disabled(fontSize <= 9)
                Button { fontSize = min(24, fontSize + 1) } label: { Text("A+").font(.callout.bold()) }
                    .accessibilityLabel("Chữ to hơn")
                    .disabled(fontSize >= 24)
            }
        }
        .onAppear { model.start(app: app) }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { phase in
            // Background: close the stream and polling so the server frees its slot.
            // Back to active: restart only if it was the background that stopped it.
            if phase == .background {
                model.stop()
                stoppedInBackground = true
            } else if phase == .active, stoppedInBackground {
                stoppedInBackground = false
                model.restart()
            }
        }
    }

    private var linkDot: some View {
        let (color, label): (Color, String) = {
            switch model.link {
            case .live: return (.green, "Đang kết nối trực tiếp")
            case .polling: return (.yellow, "Đang cập nhật định kỳ")
            case .connecting: return (.orange, "Đang kết nối")
            case .offline: return (.red, "Mất kết nối")
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityElement()
            .accessibilityLabel(label)
    }

    private var goneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon").font(.largeTitle)
            Text("Phiên đã đóng.").font(.headline)
            Button("Quay lại") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Terminal screen

private struct ContentFrame: Equatable {
    var maxY: CGFloat
    var height: CGFloat
}

private struct ContentFrameKey: PreferenceKey {
    static let defaultValue = ContentFrame(maxY: 0, height: 0)
    static func reduce(value: inout ContentFrame, nextValue: () -> ContentFrame) { value = nextValue() }
}

/// Scroll bookkeeping kept in a plain class so the preference closure (which Xcode 16 marks
/// @Sendable) can update it through a captured reference instead of the view's @State.
final class ScrollState: ObservableObject {
    @Published var stick = true
    var contentHeight: CGFloat = 0
}

/// Monospaced, selectable screen text. Sticks to the bottom unless the user scrolls up.
struct TerminalView: View {
    @ObservedObject var model: SessionModel
    let fontSize: Double
    let viewportHeight: CGFloat
    @StateObject private var scroll = ScrollState()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text.isEmpty ? "Đang tải màn hình…" : model.text)
                        .font(.system(size: CGFloat(fontSize), design: .monospaced))
                        .foregroundColor(model.text.isEmpty ? .gray : Color(white: 0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SessionModel.hPad)
                        .padding(.vertical, SessionModel.vPad)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentFrameKey.self,
                                           value: ContentFrame(maxY: g.frame(in: .named("term")).maxY,
                                                               height: g.size.height))
                })
            }
            .coordinateSpace(name: "term")
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(ContentFrameKey.self) { [scroll, viewportHeight, proxy] frame in
                if frame.height != scroll.contentHeight {
                    // Content grew or shrank: follow it if we were at the bottom.
                    scroll.contentHeight = frame.height
                    if scroll.stick { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                } else {
                    // Same content, new offset: the user scrolled.
                    let atBottom = frame.maxY <= viewportHeight + 24
                    if scroll.stick != atBottom { scroll.stick = atBottom }
                }
            }
            .onChange(of: viewportHeight) { _ in
                if scroll.stick { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if !scroll.stick {
                    Button {
                        scroll.stick = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Xuống cuối", systemImage: "arrow.down")
                            .font(.callout.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(10)
                }
            }
        }
    }
}

// MARK: - Composer

private struct QuickKey {
    let title: String
    let key: String
    let label: String
}

private let quickKeys: [QuickKey] = [
    QuickKey(title: "Esc", key: "Escape", label: "Phím Escape"),
    QuickKey(title: "Ctrl+C", key: "C-c", label: "Control C, dừng"),
    QuickKey(title: "↑", key: "Up", label: "Mũi tên lên"),
    QuickKey(title: "↓", key: "Down", label: "Mũi tên xuống"),
    QuickKey(title: "←", key: "Left", label: "Mũi tên trái"),
    QuickKey(title: "→", key: "Right", label: "Mũi tên phải"),
    QuickKey(title: "Tab", key: "Tab", label: "Phím Tab"),
    QuickKey(title: "⇧Tab", key: "BTab", label: "Shift Tab"),
    QuickKey(title: "Enter", key: "Enter", label: "Phím Enter"),
    QuickKey(title: "y", key: "y", label: "Chữ y, đồng ý"),
    QuickKey(title: "n", key: "n", label: "Chữ n, từ chối"),
]

private let slashCommands = ["/model", "/clear", "/compact", "/help", "/resume", "/exit"]

/// The draft lives only here and is only written by the keyboard, except: restored from
/// UserDefaults when the view appears (if empty), cleared after a successful send (if unchanged)
/// and appended to by the "/" menu. Never rewritten while typing. Every change is mirrored to
/// UserDefaults (`draftKey`) so a 401 / re-login does not lose it.
struct ComposerView: View {
    let draftKey: String
    /// Queues the send synchronously (FIFO with key presses); the task says whether it succeeded.
    let onSend: (String, Bool) -> Task<Bool, Never>
    let onKey: (String) -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var draft = ""
    @State private var sending = false
    @State private var showKeys = false

    /// Landscape on iPhone: short editor, buttons side by side, key row behind a toggle.
    private var compact: Bool { verticalSizeClass == .compact }
    private var buttonLayout: AnyLayout {
        compact ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
    }

    var body: some View {
        VStack(spacing: 6) {
            if !compact || showKeys { keyRow }

            HStack(alignment: .bottom, spacing: 8) {
                if compact {
                    Button { showKeys.toggle() } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundColor(showKeys ? Color.accentColor : Color.primary)
                    }
                    .accessibilityLabel(showKeys ? "Ẩn phím nhanh" : "Hiện phím nhanh")
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.system(size: 17))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .frame(height: compact ? 44 : 84)
                    if draft.isEmpty {
                        Text("Nhập tin nhắn…")
                            .font(.system(size: 17))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 4)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                buttonLayout {
                    Button { submit(enter: true) } label: {
                        Group {
                            if sending { ProgressView() } else { Text("Gửi").font(.headline) }
                        }
                        .frame(width: 84, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Gửi nội dung rồi nhấn Enter")

                    Button { submit(enter: false) } label: {
                        Text("Gửi không Enter")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .frame(width: 84, height: compact ? 44 : 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(draft.isEmpty)
                }
                .disabled(sending)
            }
        }
        .onAppear {
            if draft.isEmpty, let saved = UserDefaults.standard.string(forKey: draftKey) { draft = saved }
        }
        .onChange(of: draft) { value in
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: draftKey)
            } else {
                UserDefaults.standard.set(value, forKey: draftKey)
            }
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(slashCommands, id: \.self) { cmd in
                        Button(cmd) { draft = draft.isEmpty ? cmd : draft + cmd }
                    }
                } label: {
                    keyLabel("/")
                }
                .accessibilityLabel("Lệnh gạch chéo")
                ForEach(quickKeys, id: \.key) { k in
                    Button { onKey(k.key) } label: { keyLabel(k.title) }
                        .accessibilityLabel(k.label)
                }
            }
        }
    }

    private func keyLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .frame(minWidth: 44, minHeight: 36)
            .padding(.horizontal, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .foregroundColor(.primary)
    }

    private func submit(enter: Bool) {
        let text = draft
        guard !sending, enter || !text.isEmpty else { return }
        sending = true
        let job = onSend(text, enter) // queued now, in tap order with the quick keys
        Task {
            if await job.value, draft == text { draft = "" }
            sending = false
        }
    }
}
