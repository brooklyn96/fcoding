import SwiftUI

struct SessionView: View {
    let name: String
    /// From the inbox; nil (e.g. a session just made from "+") falls back to the name's suffix.
    let harness: String?
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: SessionModel
    @AppStorage("fontSize") private var fontSize: Double = 13
    /// Pinned: the composer is shown on open and stays open after a send.
    @AppStorage("composerPinned") private var composerPinned = false
    @State private var composerShown: Bool
    @FocusState private var composerFocused: Bool
    @State private var stoppedInBackground = false
    /// "Trả lời" from the inbox: open and focus the composer when the view appears.
    private let focusComposer: Bool

    init(name: String, harness: String? = nil, focusComposer: Bool = false) {
        self.name = name
        self.harness = harness
        self.focusComposer = focusComposer
        _model = StateObject(wrappedValue: SessionModel(name: name))
        _composerShown = State(initialValue: focusComposer || UserDefaults.standard.bool(forKey: "composerPinned"))
    }

    private var chipHarness: String? {
        harness ?? HarnessStyle.all.first { name.split(separator: "-").contains(Substring($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                TerminalView(model: model, fontSize: fontSize, viewportHeight: geo.size.height,
                             trailingInset: composerShown ? 0 : 58)
                    .onAppear { model.resize(to: geo.size, fontSize: fontSize) }
                    .onChange(of: geo.size.width) { _ in model.resize(to: geo.size, fontSize: fontSize) }
                    // Composer or keyboard shown / hidden: new row count (resize() debounces).
                    .onChange(of: geo.size.height) { _ in model.resize(to: geo.size, fontSize: fontSize) }
                    .onChange(of: fontSize) { newSize in model.resize(to: geo.size, fontSize: newSize) }
            }
            .background(Color.black)
            .overlay(alignment: .bottomTrailing) { if !composerShown { keyboardButton } }

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

            if composerShown {
                ComposerView(
                    draftKey: "draft.\(name)",
                    onSend: { text, enter in model.send(text, enter: enter) },
                    onKey: { key in model.key(key) },
                    focused: $composerFocused,
                    pinned: $composerPinned,
                    onHide: hideComposer,
                    onSent: { if !composerPinned { hideComposer() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: composerShown)
        .overlay { if model.gone { goneView } }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(white: 0.086), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { titleChip }
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
        .onAppear {
            model.start(app: app)
            // After the push animation, so the keyboard does not fight the transition.
            if focusComposer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { composerFocused = true } }
        }
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

    /// Opens the composer and focuses the field, so the keyboard comes up in one tap.
    private func showComposer() {
        composerShown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { composerFocused = true }
    }

    private func hideComposer() {
        composerFocused = false
        composerShown = false
    }

    private var keyboardButton: some View {
        Button(action: showComposer) {
            Image(systemName: "keyboard")
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(Color(white: 0.17).opacity(0.92), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 9, y: 6)
        }
        .padding(.trailing, 14)
        .padding(.bottom, 8)
        .accessibilityLabel("Mở khung gõ")
        .transition(.opacity)
    }

    /// The session name in a harness-coloured chip (as HarnessBadge), cut in the middle when long.
    private var titleChip: some View {
        let h = chipHarness
        let c = HarnessStyle.color(h)
        return HStack(spacing: 5) {
            HarnessGlyph(harness: h, size: 13)
            Text(name)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(c)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(c.opacity(0.17), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 190)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(h.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(.isHeader)
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

/// Monospaced, selectable, coloured screen text. Sticks to the bottom unless the user scrolls up.
struct TerminalView: View {
    @ObservedObject var model: SessionModel
    let fontSize: Double
    let viewportHeight: CGFloat
    /// Room kept on the right for the floating keyboard button.
    var trailingInset: CGFloat = 0
    @StateObject private var scroll = ScrollState()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Every run of the styled text carries its own font and colour; these two
                    // modifiers only style the loading line.
                    Text(model.text.isEmpty ? AttributedString("Đang tải màn hình…") : model.styled(fontSize: fontSize))
                        .font(.system(size: CGFloat(fontSize), design: .monospaced))
                        .foregroundColor(.gray)
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
                    .padding(.trailing, trailingInset)
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
/// UserDefaults (`draftKey`) so a 401 / re-login, or hiding the composer, does not lose it.
struct ComposerView: View {
    let draftKey: String
    /// Queues the send synchronously (FIFO with key presses); the task says whether it succeeded.
    let onSend: (String, Bool) -> Task<Bool, Never>
    let onKey: (String) -> Void
    var focused: FocusState<Bool>.Binding
    @Binding var pinned: Bool
    let onHide: () -> Void
    /// After a successful send that emptied the draft.
    let onSent: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var draft = ""
    @State private var sending = false
    @State private var showKeys = false

    /// Landscape on iPhone: no grab handle, a 1–2 line field, key row behind a toggle.
    private var compact: Bool { verticalSizeClass == .compact }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 10).onEnded { v in
            if v.translation.height > 30, v.translation.height > abs(v.translation.width) { onHide() }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if !compact {
                Capsule()
                    .fill(Color(white: 0.28))
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 12)
                    .contentShape(Rectangle())
                    .gesture(swipeDown)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    keyScroll
                    pinButton
                    hideButton
                }
            } else if showKeys {
                keyScroll
            }

            HStack(alignment: .bottom, spacing: 6) {
                if compact { keysToggle }
                field
                if compact {
                    pinButton
                    hideButton
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, compact ? 6 : 2)
        .padding(.bottom, 6)
        .background {
            // Swipe down on the background (not the field or the key row) hides the composer.
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea(edges: .bottom)
                .contentShape(Rectangle())
                .gesture(swipeDown)
        }
        .overlay(alignment: .top) { Divider() }
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

    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Nhập tin nhắn…", text: $draft, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(compact ? 1...2 : 1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focused)
                .padding(.vertical, 8)
            sendButton
        }
        .padding(.leading, 14)
        .frame(minHeight: 38)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    /// Tap: send with Enter. Long press: a menu with "Gửi không Enter".
    private var sendButton: some View {
        Menu {
            Button { submit(enter: true) } label: { Label("Gửi", systemImage: "return") }
            Button { submit(enter: false) } label: { Label("Gửi không Enter", systemImage: "text.cursor") }
                .disabled(draft.isEmpty)
        } label: {
            ZStack {
                Circle().fill(Color.accentColor)
                if sending {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 30, height: 30)
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        } primaryAction: {
            submit(enter: true)
        }
        .disabled(sending)
        .accessibilityLabel("Gửi")
        .accessibilityHint("Gửi rồi nhấn Enter. Giữ lâu để chọn Gửi không Enter.")
        .accessibilityAction(named: "Gửi không Enter") { submit(enter: false) }
    }

    private var pinButton: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(pinned ? Color.accentColor : Color.secondary)
        }
        .accessibilityLabel(pinned ? "Bỏ ghim khung gõ" : "Ghim khung gõ")
        .accessibilityHint("Khi ghim, khung gõ luôn hiện và không tự ẩn sau khi gửi")
    }

    private var hideButton: some View {
        Button(action: onHide) {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(.accentColor)
        }
        .accessibilityLabel("Ẩn khung gõ")
    }

    private var keysToggle: some View {
        Button { showKeys.toggle() } label: {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(showKeys ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel(showKeys ? "Ẩn phím nhanh" : "Hiện phím nhanh")
    }

    private var keyScroll: some View {
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
            let ok = await job.value
            if ok, draft == text { draft = "" }
            sending = false
            if ok, draft.isEmpty { onSent() }
        }
    }
}
