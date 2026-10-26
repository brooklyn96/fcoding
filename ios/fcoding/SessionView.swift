import SwiftUI

struct SessionView: View {
    let name: String
    /// From the inbox; nil only for a session the inbox does not know yet (e.g. just made from "+").
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
    /// Floating keyboard button: which edge, and how far down that edge (0 = top, 1 = bottom).
    @AppStorage("kbButtonLeft") private var kbLeft = false
    @AppStorage("kbButtonY") private var kbY: Double = 1
    /// Bumped on every send: the terminal jumps to the bottom and follows again.
    @State private var bottomRequest = 0
    /// Bumped when the app comes back to the foreground: pin the terminal to the bottom again.
    @State private var pinRequest = 0
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
        harness ?? name.split(separator: "-").last { HarnessStyle.all.contains(String($0)) }.map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                TerminalView(model: model, fontSize: fontSize, viewportHeight: geo.size.height,
                             bottomRequest: bottomRequest,
                             pinRequest: pinRequest,
                             joinWraps: chipHarness == "omp",
                             // Never under the keyboard button: the opposite edge while it shows.
                             jumpOnLeft: !composerShown && !kbLeft)
            }
            .background(Color.black)
            .overlay {
                if !composerShown {
                    GeometryReader { area in
                        // Keyed by the setting, so its GestureState reset is rebuilt when it changes.
                        KeyboardButton(size: area.size, left: $kbLeft, y: $kbY,
                                       reduceMotion: reduceMotion, onTap: showComposer)
                            .id(reduceMotion)
                    }
                    .transition(.opacity)
                }
            }

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
                    onSend: { text, enter in
                        bottomRequest += 1
                        return model.send(text, enter: enter)
                    },
                    onKey: { key in model.key(key) },
                    focused: $composerFocused,
                    isOmp: chipHarness == "omp",
                    pinned: $composerPinned,
                    onHide: hideComposer,
                    onSent: { if !composerPinned { hideComposer() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background {
            // tmux size = the FULL terminal area (below the top bar, without composer or keyboard),
            // so showing the composer or the keyboard never resizes tmux; the terminal then shows
            // its bottom part. Only rotation (size) and A-/A+ resize.
            GeometryReader { full in
                Color.clear
                    .onAppear { model.resize(to: full.size, fontSize: fontSize) }
                    .onChange(of: full.size) { size in model.resize(to: size, fontSize: fontSize) }
                    .onChange(of: fontSize) { newSize in model.resize(to: full.size, fontSize: newSize) }
            }
            .ignoresSafeArea(.keyboard)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: composerShown)
        .overlay { if model.gone { goneView } }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(white: 0.086), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
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
            // Back to active from the background: restart and pin to the bottom again. Not after
            // .inactive alone (Control Center, app switcher peek, paste prompt, Face ID): a
            // scrolled-up view never moves.
            if phase == .background {
                model.stop()
                stoppedInBackground = true
            }
            if phase == .active, stoppedInBackground {
                stoppedInBackground = false
                pinRequest += 1
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

// MARK: - Floating keyboard button

/// Tap opens the composer; a drag (from 10 pt of movement) moves the button, and on release it
/// snaps to the nearer side edge. It owns the drag state so its reset follows Reduce Motion: the
/// parent keys it with `.id(reduceMotion)`, which rebuilds it (and the reset transaction) when the
/// setting changes.
private struct KeyboardButton: View {
    let size: CGSize
    /// Stored edge and relative height (SessionView's @AppStorage).
    @Binding var left: Bool
    @Binding var y: Double
    let reduceMotion: Bool
    let onTap: () -> Void
    /// Live drag translation, nil when not dragging (or still under the 10 pt threshold). A
    /// GestureState resets by itself when the gesture is cancelled (a call, the app backgrounded).
    /// Its reset glides with the snap spring, or is instant with Reduce Motion.
    @GestureState private var kbDrag: CGSize?
    /// This gesture moved 10 pt or more, so its release is a drag (snap), never a tap.
    @State private var dragArmed = false
    static let snapSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    init(size: CGSize, left: Binding<Bool>, y: Binding<Double>, reduceMotion: Bool, onTap: @escaping () -> Void) {
        self.size = size
        _left = left
        _y = y
        self.reduceMotion = reduceMotion
        self.onTap = onTap
        _kbDrag = GestureState(wrappedValue: nil,
                               resetTransaction: Transaction(animation: reduceMotion ? nil : KeyboardButton.snapSpring))
    }

    /// Centre of the keyboard button in the terminal area (below the top bar, above the home
    /// indicator, inside the side safe areas): 14 pt from the edge, 8 pt from top and bottom.
    private func kbCenter(in size: CGSize, drag: CGSize? = nil) -> CGPoint {
        let r: CGFloat = 22
        let minY = 8 + r, maxY = max(minY, size.height - 8 - r)
        var p = CGPoint(x: left ? 14 + r : size.width - 14 - r,
                        y: minY + CGFloat(min(1, max(0, y))) * (maxY - minY))
        if let d = drag {
            p.x = min(size.width - r, max(r, p.x + d.width))
            p.y = min(maxY, max(minY, p.y + d.height))
        }
        return p
    }

    /// Tap opens the composer; a drag (from 10 pt of movement) moves the button, and on release
    /// it snaps to the nearer side edge. Not a Button: a Button would also fire its tap on release.
    var body: some View {
        Image(systemName: "keyboard")
            .font(.system(size: 19, weight: .medium))
            .foregroundColor(.accentColor)
            .frame(width: 44, height: 44)
            .background(Color(white: 0.17).opacity(0.92), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.55), radius: 9, y: 6)
            .scaleEffect(kbDrag == nil ? 1 : 1.08)
            .contentShape(Circle())
            .gesture(
                // Global space: the button moves under the finger, so local translation would jitter.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($kbDrag) { v, state, _ in
                        if state != nil || hypot(v.translation.width, v.translation.height) >= 10 {
                            state = v.translation
                        }
                    }
                    .onChanged { v in
                        // kbDrag is nil only before this gesture armed, so this also resets a stale
                        // flag from a cancelled gesture.
                        if hypot(v.translation.width, v.translation.height) >= 10 {
                            if !dragArmed { dragArmed = true }
                        } else if kbDrag == nil, dragArmed {
                            dragArmed = false
                        }
                    }
                    .onEnded { v in
                        // Edge and height are committed only here. A drag that came back near its
                        // start still snaps (back); only an unarmed gesture is a tap.
                        let armed = dragArmed
                        dragArmed = false
                        guard armed else { onTap(); return }
                        let p = kbCenter(in: size, drag: v.translation)
                        let minY: CGFloat = 30, maxY = max(minY, size.height - 30)
                        // Same spring as the GestureState reset, so the button glides to the edge.
                        withAnimation(reduceMotion ? nil : KeyboardButton.snapSpring) {
                            left = p.x < size.width / 2
                            y = maxY > minY ? Double((p.y - minY) / (maxY - minY)) : 1
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Mở khung gõ")
            .accessibilityHint("Kéo để dời nút sang chỗ khác")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .position(kbCenter(in: size, drag: kbDrag))
    }
}

// MARK: - Terminal screen

private struct ContentFrame: Equatable {
    var minY: CGFloat
    var maxY: CGFloat
    var height: CGFloat
}

private struct ContentFrameKey: PreferenceKey {
    static let defaultValue = ContentFrame(minY: 0, maxY: 0, height: 0)
    static func reduce(value: inout ContentFrame, nextValue: () -> ContentFrame) { value = nextValue() }
}

/// Scroll bookkeeping kept in a plain class so the preference closure (which Xcode 16 marks
/// @Sendable) can update it through a captured reference instead of the view's @State.
final class ScrollState: ObservableObject {
    /// Auto-scroll is on: the content bottom was within 24 pt of the viewport bottom.
    @Published var atBottom = true
    var contentHeight: CGFloat = 0
    var minY: CGFloat = 0
    /// Until then, offset changes come from our own animated scroll-to-bottom, not from the user.
    var programmaticUntil = Date.distantPast
    /// After opening or returning to the session: held at the bottom until the user's first scroll.
    /// While pinned, every size change and every frame that is not at the bottom jumps again, so a
    /// jump that landed short (layout still settling) is corrected.
    var pinned = true
    /// Layout settling after a pin: offset changes then are not the user's. Ends early once a jump
    /// has landed, or on a move bigger than a jump's correction (a real drag).
    var settleUntil = Date.distantPast
    /// How far the last pinned jump had to move the content (pt).
    var correction: CGFloat = 0
}

/// Monospaced, selectable, coloured screen text.
///
/// Auto-scroll: new output scrolls to the bottom only if the view was at the bottom BEFORE the
/// update. The user's position is read from the content's top edge (minY): new text grows the
/// content downward without moving minY, so a minY change is a scroll. A user scroll sets
/// atBottom from where it lands (back at the bottom turns auto-scroll on again); our own
/// scroll-to-bottom lands at the bottom (the animated one is ignored for its duration), so it never
/// reads as "the user scrolled up".
struct TerminalView: View {
    @ObservedObject var model: SessionModel
    let fontSize: Double
    let viewportHeight: CGFloat
    /// Changes on every send: jump to the bottom and follow again.
    var bottomRequest = 0
    /// Changes when the app returns to the foreground: pin to the bottom again.
    var pinRequest = 0
    /// omp session: join URLs that omp hard-wraps across lines.
    var joinWraps = false
    /// Put the jump button on the left (the keyboard button is on the right).
    var jumpOnLeft = false
    @StateObject private var scroll = ScrollState()

    private static func jump(_ scroll: ScrollState, _ proxy: ScrollViewProxy, animated: Bool = false) {
        scroll.atBottom = true
        // An instant jump lands at the bottom, so it reads as "at bottom" anyway; only the animated
        // one passes through mid-way offsets. A window on every jump would, while output streams,
        // keep renewing and swallow the user's scroll up.
        if animated { scroll.programmaticUntil = Date().addingTimeInterval(0.6) }
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Open / return: atBottom on and pinned until the user's first scroll.
    private static func pin(_ scroll: ScrollState, _ proxy: ScrollViewProxy) {
        scroll.pinned = true
        scroll.settleUntil = Date().addingTimeInterval(0.8)
        jump(scroll, proxy)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Every run of the styled text carries its own font and colour; these two
                    // modifiers only style the loading line.
                    Text(model.text.isEmpty ? AttributedString("Đang tải màn hình…") : model.styled(fontSize: fontSize, joinWraps: joinWraps))
                        .font(.system(size: CGFloat(fontSize), design: .monospaced))
                        .foregroundColor(.gray)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SessionModel.hPad)
                        .padding(.vertical, SessionModel.vPad)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(GeometryReader { g in
                    let f = g.frame(in: .named("term"))
                    Color.clear.preference(key: ContentFrameKey.self,
                                           value: ContentFrame(minY: f.minY, maxY: f.maxY, height: f.height))
                })
            }
            .coordinateSpace(name: "term")
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(ContentFrameKey.self) { [scroll, viewportHeight, proxy] frame in
                let moved = frame.minY != scroll.minY
                let grew = frame.height != scroll.contentHeight
                let oldMinY = scroll.minY
                let shrank = frame.height < scroll.contentHeight
                scroll.minY = frame.minY
                scroll.contentHeight = frame.height
                let nearBottom = frame.maxY <= viewportHeight + 24
                if Date() < scroll.settleUntil, Date() >= scroll.programmaticUntil,
                   nearBottom || (!shrank && frame.minY - oldMinY > max(scroll.correction, 24)) {
                    // Landed at the bottom, or the content moved down further than a jump would
                    // correct (the user dragging): settling is over, the normal unpin rule applies.
                    scroll.settleUntil = .distantPast
                }
                if moved, Date() >= max(scroll.programmaticUntil, scroll.settleUntil) {
                    // Content moving down = the user scrolling up: off at once, so a streaming jump
                    // never fights the finger. Not when the content shrank (the clamp moves it) or
                    // while the bottom is still inside the viewport (the bounce settling back).
                    if frame.minY > oldMinY, !shrank, frame.height > viewportHeight,
                       frame.maxY > viewportHeight + 0.5 {
                        scroll.pinned = false // the user's first scroll ends the pinned phase
                        if scroll.atBottom { scroll.atBottom = false }
                    } else if nearBottom, !scroll.atBottom {
                        scroll.atBottom = true // landed back at the bottom
                    }
                }
                if scroll.pinned {
                    // Any size change, or a landing short of the bottom: jump (again).
                    if grew || !nearBottom {
                        scroll.correction = max(0, frame.maxY - viewportHeight)
                        TerminalView.jump(scroll, proxy)
                    }
                } else if grew, scroll.atBottom {
                    // Decided by the state from before this update; scrolled up = never moved.
                    TerminalView.jump(scroll, proxy)
                }
            }
            .onChange(of: viewportHeight) { _ in
                if scroll.atBottom { TerminalView.jump(scroll, proxy) }
            }
            .onChange(of: bottomRequest) { _ in TerminalView.jump(scroll, proxy) }
            .onChange(of: pinRequest) { _ in TerminalView.pin(scroll, proxy) }
            .onAppear { TerminalView.pin(scroll, proxy) }
            .overlay(alignment: jumpOnLeft ? .bottomLeading : .bottomTrailing) {
                // Only content taller than the viewport can be away from the bottom.
                if !scroll.atBottom, scroll.contentHeight > viewportHeight {
                    Button { TerminalView.jump(scroll, proxy, animated: true) } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor, in: Circle())
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Xuống cuối")
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
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
    var symbol: String? = nil
    /// Only for omp: in bash C-o runs the line, in claude it toggles the transcript.
    var ompOnly = false
}

private let quickKeys: [QuickKey] = [
    QuickKey(title: "Esc", key: "Escape", label: "Phím Escape"),
    // omp agent hub (Alt+A): ↑/↓ chọn, Enter mở, Esc đóng.
    QuickKey(title: "Agents", key: "M-a", label: "Mở danh sách agent của omp", symbol: "person.2", ompOnly: true),
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
    QuickKey(title: "^O", key: "C-o", label: "Control O, mở rộng", ompOnly: true),
]

private let slashCommands = ["/model", "/clear", "/compact", "/help", "/resume", "/exit"]
/// omp's agent hub; only offered in omp sessions.
private let ompSlashCommands = ["/hub"]

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
    /// omp session: show the agent-hub keys (Agents, ^O) and /hub.
    var isOmp = false
    @Binding var pinned: Bool
    let onHide: () -> Void
    /// After a successful send that emptied the draft.
    let onSent: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var draft = ""
    @State private var sending = false
    /// New identity for the field after a send, so no UITextView keeps the sent text.
    @State private var fieldID = 0
    /// The text just sent and cleared. If the old field writes it back (an IME commit on resign),
    /// onChange drops it instead of storing it again. Reset by the next real edit.
    @State private var justSent: String?
    /// The guard above holds only until then (the rebuild has settled); after it, typing the same
    /// text again is a real edit.
    @State private var justSentUntil = Date.distantPast
    @State private var showKeys = false

    /// Landscape on iPhone: no grab handle, a 1–2 line field, key row behind a toggle.
    private var compact: Bool { verticalSizeClass == .compact }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 10).onEnded { v in
            if !sending, v.translation.height > 30, v.translation.height > abs(v.translation.width) { onHide() }
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
            if let sent = justSent, !value.isEmpty {
                justSent = nil
                if value == sent, Date() < justSentUntil { draft = ""; return }
            }
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
                .id(fieldID)
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
        .disabled(sending) // hiding mid-send would drop the composer before the draft is cleared
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
                    ForEach(isOmp ? slashCommands + ompSlashCommands : slashCommands, id: \.self) { cmd in
                        Button(cmd) { draft = draft.isEmpty ? cmd : draft + cmd }
                    }
                } label: {
                    keyLabel("/")
                }
                .accessibilityLabel("Lệnh gạch chéo")
                ForEach(quickKeys.filter { isOmp || !$0.ompOnly }, id: \.key) { k in
                    Button { onKey(k.key) } label: { keyLabel(k.title, symbol: k.symbol) }
                        .accessibilityLabel(k.label)
                }
            }
        }
    }

    private func keyLabel(_ title: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol = symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            Text(title)
        }
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .frame(minWidth: 44, minHeight: 36)
            .padding(.horizontal, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .foregroundColor(.primary)
    }

    /// On success the field is emptied and the stored draft removed, unless the draft changed while
    /// sending (compared with the exact snapshot taken here).
    ///
    /// Order matters. Vietnamese Telex keeps the last word as marked (composing) text. Clearing the
    /// binding while the field is still first responder, then resigning it (auto-hide), made UIKit
    /// commit the composition and the field write the OLD text back through the binding; onChange
    /// stored it again and onAppear restored it. So: resign first (commits the composition), let that
    /// settle, then clear and rebuild the field.
    private func submit(enter: Bool) {
        let snapshot = draft
        guard !sending, enter || !snapshot.isEmpty else { return }
        sending = true
        let job = onSend(snapshot, enter) // queued now, in tap order with the quick keys
        Task {
            let ok = await job.value
            guard ok else { sending = false; return }
            let unchanged = draft == snapshot
            let stayOpen = pinned
            if unchanged {
                focused.wrappedValue = false
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            // The stored copy is decided on its own (works even if the screen was left mid-send):
            // remove it when it is still exactly what was sent.
            if UserDefaults.standard.string(forKey: draftKey) == snapshot {
                UserDefaults.standard.removeObject(forKey: draftKey)
            }
            // The field is cleared only if the user did not change it while sending.
            guard unchanged, draft == snapshot else { sending = false; return }
            justSent = snapshot.isEmpty ? nil : snapshot
            justSentUntil = Date().addingTimeInterval(0.3)
            draft = ""
            fieldID += 1
            sending = false
            if !draft.isEmpty { return }
            if stayOpen {
                try? await Task.sleep(nanoseconds: 50_000_000)
                focused.wrappedValue = true
            } else {
                onSent()
            }
        }
    }
}
