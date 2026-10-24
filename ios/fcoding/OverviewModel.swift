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
    private static let seenKey = "inbox.seen"

    init() {
        seen = UserDefaults.standard.dictionary(forKey: OverviewModel.seenKey) as? [String: Double] ?? [:]
    }

    /// One request at a time. A call while one is in flight is not dropped: it schedules one
    /// follow-up load and returns only when that follow-up is done (so callers see fresh data).
    func load(_ app: AppState) async {
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

    /// Keeps the last data on failure; a 401 goes back to pairing through `app.report`.
    private func fetchOnce(_ app: AppState) async {
        guard let api = app.api else { return }
        do {
            let fresh = try await api.overview()
            overview = fresh
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

    /// Kills the tmux session; its draft goes with it (as before).
    func delete(_ name: String, app: AppState) async {
        _ = await perform(name, app) { api in
            try await api.call("DELETE", "api/sessions/\(name)")
            UserDefaults.standard.removeObject(forKey: "draft.\(name)")
        }
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
