import Foundation
import UIKit

/// Live screen of one tmux session: SSE stream with reconnect + backoff,
/// polling GET /api/screen every 1.5 s while the stream is down.
/// Reading, decoding, patching and styling run off the main actor (`readStream`, `ScreenRender`);
/// the main actor only receives the finished styled screen, and holds it while the user scrolls.
@MainActor
final class SessionModel: ObservableObject {
    enum Link { case connecting, live, polling, offline }

    static let hPad: CGFloat = 6
    static let vPad: CGFloat = 4
    /// Ask for SGR colour escapes in the screen text (an older server ignores it).
    static let ansi = [URLQueryItem(name: "ansi", value: "1")]

    /// The screen text with its SGR colours and tappable links (or the loading line).
    @Published private(set) var styled = ScreenRender.loading
    @Published private(set) var link: Link = .connecting
    @Published private(set) var gone = false
    @Published var errorText: String?

    let name: String
    private weak var app: AppState?
    private var loop: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    /// Generation of the resize whose request is on the wire (past its sleep), if any.
    private var resizeGen = 0
    private var inFlightGen: Int?
    private var sentCols = 0
    private var sentRows = 0

    init(name: String) { self.name = name }

    private lazy var render = ScreenRender { [weak self] value in await self?.show(value) }
    /// The terminal's scroll view (set by TerminalView): a new screen waits while the finger is on
    /// it or it is still moving, so a swipe never pays for a re-layout.
    weak var scrollView: UIScrollView?
    private var pending: AttributedString?
    private var flushTask: Task<Void, Never>?

    /// Font size and wrap joining for the styled screen (`joinWraps`: join URLs hard-wrapped across
    /// lines, omp sessions only); a change rebuilds it off the main actor.
    func style(fontSize: Double, joinWraps: Bool) {
        let render = render
        Task { await render.style(fontSize: fontSize, joinWraps: joinWraps) }
    }

    private func show(_ value: AttributedString) {
        pending = value
        flush()
    }

    /// Publishes the newest built screen, or checks again in 0.1 s while the user scrolls.
    private func flush() {
        guard let value = pending, flushTask == nil else { return }
        if let s = scrollView, s.isTracking || s.isDragging || s.isDecelerating {
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.flushTask = nil
                self?.flush()
            }
            return
        }
        pending = nil
        screens += 1
        styled = value
    }

    /// Bumped with every published screen: a cheap change signal for the view (no text compare).
    private(set) var screens = 0

    private func setLink(_ value: Link) {
        if link != value { link = value }
    }

    func start(app: AppState) {
        self.app = app
        guard loop == nil, !gone else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func restart() {
        guard let app = app else { return }
        stop()
        start(app: app)
    }

    // MARK: - Screen updates

    private func run() async {
        var failures = 0
        while !Task.isCancelled && !gone {
            guard let api = app?.api else { return }
            do {
                try await readStream(api, render)
                failures = 0
            } catch is ScreenFeed.Mismatch {
                // The first in a row reconnects at once (the new stream starts with a full
                // screen); a repeat takes the backoff and polling path below.
                if await render.mismatch() { continue }
                failures += 1
            } catch {
                if Task.isCancelled || isTerminal(error) { return }
                failures += 1
            }
            if Task.isCancelled || gone || app?.api == nil { return }
            // Stream is down: keep the screen fresh by polling until the next reconnect attempt.
            let wait = failures == 0 ? 1.5 : min(30, pow(2, Double(failures)))
            let until = Date().addingTimeInterval(wait)
            repeat {
                guard await pollOnce(api) else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } while Date() < until && !Task.isCancelled && !gone
        }
    }

    /// Off the main actor: the bytes are read and split here, decoded and patched in `render`; the
    /// main actor only sees link changes, `gone`, and finished screens.
    private nonisolated func readStream(_ api: API, _ render: ScreenRender) async throws {
        await setLink(.connecting)
        let delta = await render.delta
        var req = try api.request("GET", "api/stream/\(name)", query: ScreenFeed.streamQuery(delta: delta), timeout: 45)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 8192 { break }
            }
            try API.check(resp, body, token: api.token)
            throw APIError(status: http.statusCode, code: "", token: api.token)
        }
        await setLink(.live)
        // Lines split on LF only (ScreenFeed.Lines). An event is dispatched on its "data:" line
        // (the server sends one data line per event).
        var event = ""
        var lines = ScreenFeed.Lines()
        for try await byte in bytes {
            guard let line = try lines.push(byte) else { continue }
            if line.hasPrefix("event:") {
                event = ScreenFeed.field(line, "event:")
            } else if line.hasPrefix("data:") {
                let data = ScreenFeed.field(line, "data:")
                switch event {
                case "gone":
                    await handleGone(data, api)
                    return
                case "", "screen":
                    await render.screen(Data(data.utf8))
                case "patch":
                    guard await render.patch(Data(data.utf8)) else { throw ScreenFeed.Mismatch() }
                default:
                    break
                }
                event = ""
            } else if line.isEmpty {
                event = ""
            }
        }
    }

    /// Returns false when the loop must stop (session gone or logged out).
    private func pollOnce(_ api: API) async -> Bool {
        do {
            let data = try await api.call("GET", "api/screen/\(name)", query: SessionModel.ansi)
            await render.screen(data)
            setLink(.polling)
            return true
        } catch {
            if Task.isCancelled || isTerminal(error) { return false }
            setLink(.offline)
            return true
        }
    }

    /// `event: gone` data is {"reason":"auth"} (logged out: back to login) or {"reason":"session"}
    /// (tmux session closed). Without a known reason, GET /api/me decides: 401 means logged out.
    private func handleGone(_ data: String, _ api: API) async {
        let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
        switch obj?["reason"] as? String {
        case "auth":
            errorText = app?.report(APIError(status: 401, code: "unauthorized", token: api.token))
        case "session":
            gone = true
        default:
            do {
                try await api.call("GET", "api/me")
                gone = true
            } catch {
                // 401 goes to login; anything else: the reconnect/poll loop finds out (404 = closed).
                _ = isTerminal(error)
            }
        }
    }

    /// 404 = session gone, 401 = back to login; both end the loop.
    private func isTerminal(_ error: Error) -> Bool {
        guard let e = error as? APIError else { return false }
        if e.status == 404 { gone = true; return true }
        if e.status == 401 { errorText = app?.report(error); return true }
        return false
    }

    private func fail(_ error: Error) {
        if let e = error as? APIError, e.status == 404 { gone = true; return }
        errorText = app?.report(error)
    }

    // MARK: - Input

    /// One FIFO chain for keys and sends: each request starts only after the previous one
    /// finished, so "↓ then Enter" reaches tmux in tap order. Enqueued synchronously by the caller.
    private var inputTail: Task<Bool, Never>?

    private func enqueue(_ op: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = inputTail
        let job = Task { @MainActor () async -> Bool in
            _ = await previous?.value
            return await op()
        }
        inputTail = job
        return job
    }

    /// Queues the text; the returned task's value is true when the server accepted it.
    func send(_ text: String, enter: Bool) -> Task<Bool, Never> {
        enqueue { [weak self] in
            guard let self = self, let api = self.app?.api else { return false }
            do {
                try await api.call("POST", "api/send/\(self.name)", body: ["text": text, "enter": enter])
                self.errorText = nil
                return true
            } catch {
                self.fail(error)
                return false
            }
        }
    }

    func key(_ key: String) {
        _ = enqueue { [weak self] in
            guard let self = self, let api = self.app?.api else { return false }
            do {
                try await api.call("POST", "api/key/\(self.name)", body: ["key": key])
                self.errorText = nil
                return true
            } catch {
                self.fail(error)
                return false
            }
        }
    }

    // MARK: - Image attach

    /// On from the moment an image is selected (before it is loaded or converted) until its upload
    /// ends; one image at a time. While on, the composer disables Send and the image button, so no
    /// message can overtake the image path and a second pick is never dropped silently.
    @Published private(set) var imageBusy = false
    /// Status line for the image: sending, attached, saved but not attached, or an image error
    /// (`imageFailed`). Image results never go to `errorText`, so a later Send cannot wipe them.
    @Published var imageNote: String?
    /// `imageNote` is an error (or the camera is off): shown as a warning and kept on Send.
    @Published private(set) var imageFailed = false

    /// Photo library, called at selection: `load` reads the picked file (seconds for an iCloud
    /// original), then ImageIO downsamples it without decoding the full bitmap.
    func attachPhoto(_ load: @escaping () async -> Data?) {
        attach {
            guard let data = await load() else { throw APIError(status: 0, code: "bad_type") }
            return try await Task.detached(priority: .userInitiated) { try ImageAttach.jpeg(data: data) }.value
        }
    }

    /// Camera shot.
    func attachImage(_ image: UIImage) {
        attach { try await Task.detached(priority: .userInitiated) { try ImageAttach.jpeg(image) }.value }
    }

    /// Camera access is denied or restricted for FCode: say where to turn it on; nothing is opened.
    func cameraDenied() {
        guard !imageBusy else { return }
        let text = "Camera đang bị tắt cho FCode: vào Cài đặt → FCode → bật Camera"
        imageFailed = true
        imageNote = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// True while the busy image can still be cancelled by a tap on its note: from selection until
    /// its upload request starts (an upload on the wire may already be saved and pasted).
    @Published private(set) var imageCancellable = false
    /// The busy image's op; replaced by the next pick, so a cancelled op never touches later state.
    private var imageOp: ImageOp?

    /// Takes the image's input-chain slot at once (at selection), so every later send or key waits
    /// behind it. Inside that slot: make the JPEG (load + conversion, bounded by 60 s), then find the
    /// session's project and upload. A cancelled op returns quietly: `cancelImage` already reset the note.
    private func attach(_ makeJPEG: @escaping @MainActor () async throws -> Data) {
        guard !imageBusy else { return }
        let op = ImageOp()
        imageOp = op
        imageBusy = true
        imageCancellable = true
        imageFailed = false
        imageNote = "Đang gửi ảnh…"
        _ = enqueue { [weak self] in
            guard let self = self else { return false }
            do {
                let jpeg = try await op.load(makeJPEG)
                guard !op.cancelled else { return false }
                guard let api = self.app?.api else { self.finishImage(nil, nil); return false }
                // The session's project, from the server (a renamed session keeps its project).
                let sessions = try await api.get("api/sessions", as: SessionsResponse.self).sessions
                guard !op.cancelled else { return false }
                guard let project = sessions.first(where: { $0.name == self.name })?.project, !project.isEmpty else {
                    throw APIError(status: 404, code: "no_session")
                }
                self.imageCancellable = false
                let reply = try await api.uploadImage(project: project, session: self.name, jpeg: jpeg)
                self.finishImage(reply, nil)
                return true
            } catch {
                if !op.cancelled { self.finishImage(nil, error) }
                return false
            }
        }
    }

    /// Tap on the busy note: drops the image before its upload starts. The note clears and the
    /// composer frees at once; the op's FIFO slot still runs, in order, and ends without uploading.
    func cancelImage() {
        guard imageBusy, imageCancellable, let op = imageOp else { return }
        op.cancel()
        finishImage(nil, CancellationError())
        UIAccessibility.post(notification: .announcement, argument: "Đã huỷ ảnh")
    }

    private func finishImage(_ reply: UploadReply?, _ error: Error?) {
        imageOp = nil
        imageCancellable = false
        imageBusy = false
        // Saved but not attached is a warning too: kept on Send like the errors.
        imageFailed = reply?.attached != true
        if let reply = reply {
            imageNote = reply.attached ? "Đã gắn ảnh — gõ lời nhắn rồi gửi" : "Đã lưu ảnh nhưng chưa gắn được vào phiên"
        } else if error is CancellationError {
            imageNote = nil
        } else if let e = error as? APIError, e.status == 401 {
            imageNote = app?.report(e)
        } else {
            imageNote = error.map(ImageAttach.message) ?? "Không gửi được ảnh, thử lại"
        }
        if let said = imageNote { UIAccessibility.post(notification: .announcement, argument: said) }
    }

    /// Tells tmux how many columns/rows fit in `size` at this font size (debounced, skipped if unchanged).
    func resize(to size: CGSize, fontSize: Double) {
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        guard charWidth > 0, font.lineHeight > 0, size.width > 0, size.height > 0 else { return }
        let cols = min(300, max(20, Int((size.width - 2 * SessionModel.hPad) / charWidth)))
        let rows = min(200, max(10, Int((size.height - 2 * SessionModel.vPad) / font.lineHeight)))
        // Cancel first: a size that returns to the sent one must also drop a pending resize.
        resizeTask?.cancel()
        // A request already on the wire may have been applied by the server: the sent size is then
        // unknown, so never short-circuit on it.
        if inFlightGen != nil {
            inFlightGen = nil
            sentCols = 0
            sentRows = 0
        }
        guard cols != sentCols || rows != sentRows else { return }
        resizeGen += 1
        let gen = resizeGen
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, !Task.isCancelled, let api = self.app?.api else { return }
            self.inFlightGen = gen
            do {
                try await api.call("POST", "api/resize/\(self.name)", body: ["cols": cols, "rows": rows])
                if !Task.isCancelled {
                    self.sentCols = cols
                    self.sentRows = rows
                }
            } catch {
                // Cancelled in flight: the server may or may not have it, so resend next time.
                if Task.isCancelled { self.sentCols = 0; self.sentRows = 0 } else { self.fail(error) }
            }
            if self.inFlightGen == gen { self.inFlightGen = nil }
        }
    }
}

/// Off the main actor: holds the screen (full screens and patches), builds its styled text for the
/// current font, and hands each finished build to `publish`, rebuilding only for the newest input.
/// Memory only, for the open screen.
actor ScreenRender {
    static let loading = AttributedString("Đang tải màn hình…")

    private struct Input {
        var text = ""
        /// Width in cells, for joining hard-wrapped links.
        var cols = 0
        /// Nil until the view sets it: nothing is built before.
        var fontSize: Double?
        var joinWraps = false
    }

    private var state = ScreenFeed.State()
    private var mismatches = ScreenFeed.Mismatches()
    private var input = Input()
    private var version = 0
    private var running = false
    private let publish: @Sendable (AttributedString) async -> Void

    init(publish: @escaping @Sendable (AttributedString) async -> Void) { self.publish = publish }

    /// A full screen ({text, rows, cols, cursor, hash}), from the stream or the polling fallback.
    func screen(_ data: Data) {
        guard let s = try? JSONDecoder().decode(Screen.self, from: data) else { return }
        state.set(s.text, hash: s.hash)
        update(s.text, cols: s.cols)
    }

    /// An `event: patch`; false when it does not apply to the screen held here.
    func patch(_ data: Data) -> Bool {
        guard let p = try? JSONDecoder().decode(ScreenFeed.Patch.self, from: data),
              let text = state.apply(p) else { return false }
        mismatches.applied()
        update(text, cols: p.cols)
        return true
    }

    /// Records a patch that did not apply; true = reconnect at once (see ScreenFeed.Mismatches).
    func mismatch() -> Bool { mismatches.record() }

    /// Ask the stream for patches (false after repeated mismatches).
    var delta: Bool { mismatches.delta }

    func style(fontSize: Double, joinWraps: Bool) {
        guard fontSize != input.fontSize || joinWraps != input.joinWraps else { return }
        input.fontSize = fontSize
        input.joinWraps = joinWraps
        rebuild()
    }

    private func update(_ text: String, cols: Int?) {
        let cols = cols ?? input.cols
        guard text != input.text || cols != input.cols else { return }
        input.text = text
        input.cols = cols
        rebuild()
    }

    private func rebuild() {
        version += 1
        guard !running, input.fontSize != nil else { return }
        running = true
        Task { await self.drain() }
    }

    /// Builds until a build matches the newest input. One build at a time, so every finished build
    /// is newer than the one shown and is published; inputs that arrive during a build collapse into
    /// one next build for the newest input. Slow builds never starve the screen.
    private func drain() async {
        var built = -1
        while built != version {
            built = version
            let input = self.input
            let value = await Task.detached(priority: .userInitiated) { ScreenRender.build(input) }.value
            await publish(value)
        }
        running = false
    }

    private static func build(_ i: Input) -> AttributedString {
        guard !i.text.isEmpty else { return loading }
        let runs = ANSI.runs(i.text)
        var value = ANSI.attributed(runs, fonts: ANSI.Fonts(size: CGFloat(i.fontSize ?? 13)))
        Links.apply(Links.find(in: runs.map(\.text).joined(), cols: i.cols, joinWraps: i.joinWraps), to: &value)
        return value
    }
}

/// One image attach. Its load race (`load`) owns its own continuation, resumed exactly once: by the
/// JPEG, by its 60 s timer, or by `cancel`. Whoever ends it cancels the other tasks; a late result
/// (a load that ignored cancellation) finds no continuation and is dropped, never uploaded.
@MainActor
private final class ImageOp {
    private(set) var cancelled = false
    private var wait: CheckedContinuation<Data, Error>?
    private var tasks: [Task<Void, Never>] = []

    /// `make()` or, after 60 s, APIError "load_timeout". An unstructured race, so a load that ignores
    /// cancellation (a stalled iCloud original) cannot hold the input chain.
    func load(_ make: @escaping @MainActor () async throws -> Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            if cancelled { c.resume(throwing: CancellationError()); return }
            wait = c
            // Both tasks start after this closure returns (same actor), so `tasks` is set first.
            let work = Task { [weak self] in
                let result: Result<Data, Error>
                do { result = .success(try await make()) } catch { result = .failure(error) }
                self?.end(result)
            }
            let timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                self?.end(.failure(APIError(status: 0, code: "load_timeout")))
            }
            tasks = [work, timer]
        }
    }

    func cancel() {
        cancelled = true
        end(.failure(CancellationError()))
    }

    private func end(_ result: Result<Data, Error>) {
        guard let c = wait else { return }
        wait = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        c.resume(with: result)
    }
}
