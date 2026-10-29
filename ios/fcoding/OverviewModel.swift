import Foundation

/// Data behind the inbox: the last GET /api/overview, the per-session "last seen activity"
/// (unread is client-side, CONTRACT A5) and the names with a request in flight.
@MainActor
final class OverviewModel: ObservableObject {
    @Published private(set) var overview: Overview?
    @Published var errorText: String?
    @Published private(set) var busy: Set<String> = []
    /// Prompts answered with y/n: session name -> its `activity` when the answer was sent. The
    /// buttons stay disabled until a successful refresh shows newer activity or a non-waiting state.
    @Published private(set) var answered: [String: Double] = [:]
    @Published private(set) var seen: [String: Double]
    /// Marked read after the next successful load (the session that was just closed).
    var pendingRead: String?

    /// The one load in flight; a load() call during it asks for exactly one more (`reloadAfter`).
    private var current: Task<Void, Never>?
    private var reloadAfter = false
    /// Renames in flight: every overview reply that arrives meanwhile is dropped, because it may
    /// hold the old name or the new one, and syncSeen would mark the renamed session read.
    private var renaming = 0
    /// Bumped when a rename ends: a reply to a fetch that started before that is dropped too, and
    /// the fetch is repeated.
    private var generation = 0
    private static let seenKey = "inbox.seen"
    /// `overview` is the copy saved on this phone (ResponseCache), not yet confirmed by the box:
    /// show "đang cập nhật". Its ages still count from its own `now`. Cleared by the first good reply.
    @Published private(set) var fromCache = false
    private var restored = false

    init() {
        seen = UserDefaults.standard.dictionary(forKey: OverviewModel.seenKey) as? [String: Double] ?? [:]
    }

    /// One request at a time. A call while one is in flight is not dropped: it schedules one
    /// follow-up load and returns only when that follow-up is done (so callers see fresh data).
    func load(_ app: AppState) async {
        restore(app)
        if let running = current {
            reloadAfter = true
            await running.value
            return
        }
        let task = Task { await self.loadLoop(app) }
        current = task
        await task.value
    }

    private func loadLoop(_ app: AppState) async {
        repeat {
            reloadAfter = false
            await fetchOnce(app)
        } while reloadAfter
        current = nil
    }

    /// Once, before the first request: the saved reply for this server and login, if it decodes.
    /// Read marks, answered prompts and pendingRead wait for a real reply.
    private func restore(_ app: AppState) {
        guard !restored else { return }
        restored = true
        guard overview == nil, let api = app.api else { return }
        let key = ResponseCache.key(server: api.base.absoluteString, token: api.token)
        guard let saved = ResponseCache.load("overview", key: key) else { return }
        guard let cached = ResponseCache.decode(Overview.self, saved.data) else {
            ResponseCache.remove("overview", key: key)
            return
        }
        overview = cached
        fromCache = true
    }

    /// Keeps the last data on failure; a 401 goes back to pairing through `app.report`.
    private func fetchOnce(_ app: AppState) async {
        guard let api = app.api else { return }
        let started = generation
        do {
            let data = try await api.call("GET", "api/overview")
            let fresh = try JSONDecoder().decode(Overview.self, from: data)
            if renaming > 0 { return }   // the rename fetches once its PATCH has answered
            guard started == generation else {
                reloadAfter = true
                return
            }
            overview = fresh
            fromCache = false
            // Not after a sign-out or re-pair that happened while the request was out.
            if app.token == api.token {
                ResponseCache.save(data, "overview", key: ResponseCache.key(server: api.base.absoluteString, token: api.token))
            }
            errorText = nil
            syncSeen(fresh)
            answered = answered.filter { name, sentAt in
                guard let s = fresh.sessions.first(where: { $0.name == name }) else { return false }
                return s.state == "waiting" && (s.activity ?? 0) <= sentAt
            }
            if let name = pendingRead {
                pendingRead = nil
                markRead(name)
            }
        } catch {
            if let message = app.report(error) { errorText = message }
            if app.token == nil { ResponseCache.clear() }
        }
    }

    // MARK: - Time

    /// "vừa xong", "N phút", "N giờ", "hôm qua", "N ngày" from now - activity (epoch seconds, A5 update 5).
    func relativeTime(_ s: OverviewSession) -> String {
        guard let now = overview?.now, let activity = s.activity else { return "" }
        let d = max(0, now - activity)
        switch d {
        case ..<60: return "vừa xong"
        case ..<3600: return "\(Int(d / 60)) phút"
        case ..<86400: return "\(Int(d / 3600)) giờ"
        case ..<172_800: return "hôm qua"
        default: return "\(Int(d / 86400)) ngày"
        }
    }

    // MARK: - Unread

    func isUnread(_ s: OverviewSession) -> Bool {
        guard let activity = s.activity, let last = seen[s.name] else { return false }
        return activity > last
    }

    func markRead(_ name: String) {
        guard let activity = overview?.sessions.first(where: { $0.name == name })?.activity else { return }
        seen[name] = activity
        saveSeen()
    }

    /// "Đã đọc" / "Chưa đọc" from the swipe actions.
    func toggleRead(_ s: OverviewSession) {
        guard let activity = s.activity else { return }
        seen[s.name] = activity - (isUnread(s) ? 0 : 1)
        saveSeen()
    }

    /// A session seen for the first time counts as read; names that are gone are dropped.
    private func syncSeen(_ o: Overview) {
        var next: [String: Double] = [:]
        for s in o.sessions {
            next[s.name] = seen[s.name] ?? s.activity ?? 0
        }
        if next != seen {
            seen = next
            saveSeen()
        }
    }

    private func saveSeen() { UserDefaults.standard.set(seen, forKey: OverviewModel.seenKey) }

    // MARK: - Actions

    /// y / n on a waiting prompt: POST /api/send/<name> {text, enter:true}.
    func answer(_ s: OverviewSession, _ text: String, app: AppState) async {
        let sentAt = s.activity ?? 0
        let sent = await perform(s.name, app) { api in
            _ = try await api.call("POST", "api/send/\(s.name)", body: ["text": text, "enter": true])
            // Before the follow-up load, so that load can already release it. A failed refresh
            // keeps it (and the error row); the next successful poll decides.
            self.answered[s.name] = sentAt
        }
        if sent { markRead(s.name) }
    }

    /// "Đóng": kills the tmux session; its draft goes with it (as before). True when it closed.
    @discardableResult
    func delete(_ name: String, app: AppState) async -> Bool {
        await perform(name, app) { api in
            try await api.call("DELETE", "api/sessions/\(name)")
            UserDefaults.standard.removeObject(forKey: "draft.\(name)")
        }
    }

    /// "Đổi tên": PATCH /api/sessions/<name> {name}. Returns the error text, nil when renamed.
    /// The draft and the read mark move with the session.
    func rename(_ name: String, to newName: String, app: AppState) async -> String? {
        guard let api = app.api else { return unpairedNotice }
        guard !busy.contains(name) else { return "Phiên đang bận, thử lại." }
        busy.insert(name)
        defer { busy.remove(name) }
        let mark = seen[name]
        renaming += 1
        do {
            defer {
                renaming -= 1
                generation += 1
            }
            try await api.call("PATCH", "api/sessions/\(name)", body: ["name": newName])
        } catch let e as APIError where e.status == 404 && e.code == "not_found" {
            await load(app)
            return "Phiên này không còn nữa."
        } catch let e as APIError where [404, 405, 501].contains(e.status) {
            return "Máy chủ chưa hỗ trợ đổi tên, cập nhật máy chủ trước."
        } catch let e as APIError where e.status == 409 && e.code == "reserved_name" {
            return HomeLogic.reservedNameMessage(newName, projects: overview?.projects.map(\.name) ?? [])
        } catch let e as APIError where e.status == 409 {
            return "Tên này đã có phiên khác."
        } catch let e as APIError where e.status == 400 {
            return "Tên không hợp lệ."
        } catch {
            return app.report(error) ?? "Chưa đổi được tên, thử lại."
        }
        let defaults = UserDefaults.standard
        if let draft = defaults.string(forKey: "draft.\(name)") {
            defaults.set(draft, forKey: "draft.\(newName)")
            defaults.removeObject(forKey: "draft.\(name)")
        }
        // The mark read before the PATCH: no reply since then has been applied to `seen`.
        if let mark = mark { seen[newName] = mark }
        seen[name] = nil
        saveSeen()
        await load(app)
        return nil
    }

    /// Runs one action for `name`; `busy` stays set until the post-action data is in, so the
    /// buttons cannot fire twice on a stale row. Returns true when the request succeeded.
    private func perform(_ name: String, _ app: AppState, _ op: (API) async throws -> Void) async -> Bool {
        guard let api = app.api, !busy.contains(name) else { return false }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await op(api)
            errorText = nil
        } catch {
            errorText = app.report(error)
            return false
        }
        await load(app)
        return true
    }

    /// A waiting prompt that takes y/n gets the "y · Đồng ý" / "n · Từ chối" buttons.
    nonisolated static func isYesNo(_ preview: String?) -> Bool {
        guard let p = preview?.lowercased() else { return false }
        return ["(y/n)", "[y/n]", "yes/no"].contains { p.contains($0) }
    }
}
