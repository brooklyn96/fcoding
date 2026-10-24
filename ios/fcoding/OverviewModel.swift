import Foundation

/// Data behind the inbox: the last GET /api/overview, the per-session "last seen activity"
/// (unread is client-side, CONTRACT A5) and the names with a request in flight.
@MainActor
final class OverviewModel: ObservableObject {
    @Published private(set) var overview: Overview?
    @Published var errorText: String?
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var seen: [String: Double]
    /// Marked read after the next successful load (the session that was just closed).
    var pendingRead: String?

    private var loading = false
    private static let seenKey = "inbox.seen"

    init() {
        seen = UserDefaults.standard.dictionary(forKey: OverviewModel.seenKey) as? [String: Double] ?? [:]
    }

    /// Keeps the last data on failure; a 401 goes back to pairing through `app.report`.
    func load(_ app: AppState) async {
        guard let api = app.api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await api.overview()
            overview = fresh
            errorText = nil
            syncSeen(fresh)
            if let name = pendingRead {
                pendingRead = nil
                markRead(name)
            }
        } catch {
            if let message = app.report(error) { errorText = message }
        }
    }

    // MARK: - Time

    /// tmux reports seconds; accept milliseconds too in case `now` comes from Date.now().
    nonisolated static func seconds(_ value: Double) -> Double { value > 100_000_000_000 ? value / 1000 : value }

    /// "vừa xong", "N phút", "N giờ", "hôm qua", "N ngày" from now - activity.
    func relativeTime(_ s: OverviewSession) -> String {
        guard let now = overview?.now, let activity = s.activity else { return "" }
        let d = max(0, OverviewModel.seconds(now) - OverviewModel.seconds(activity))
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
        return OverviewModel.seconds(activity) > last
    }

    func markRead(_ name: String) {
        guard let activity = overview?.sessions.first(where: { $0.name == name })?.activity else { return }
        seen[name] = OverviewModel.seconds(activity)
        saveSeen()
    }

    /// "Đã đọc" / "Chưa đọc" from the swipe actions.
    func toggleRead(_ s: OverviewSession) {
        guard let activity = s.activity else { return }
        seen[s.name] = OverviewModel.seconds(activity) - (isUnread(s) ? 0 : 1)
        saveSeen()
    }

    /// A session seen for the first time counts as read; names that are gone are dropped.
    private func syncSeen(_ o: Overview) {
        var next: [String: Double] = [:]
        for s in o.sessions {
            next[s.name] = seen[s.name] ?? s.activity.map(OverviewModel.seconds) ?? 0
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
        await perform(s.name, app) { api in
            _ = try await api.call("POST", "api/send/\(s.name)", body: ["text": text, "enter": true])
        }
        markRead(s.name)
    }

    /// Kills the tmux session; its draft goes with it (as before).
    func delete(_ name: String, app: AppState) async {
        await perform(name, app) { api in
            try await api.call("DELETE", "api/sessions/\(name)")
            UserDefaults.standard.removeObject(forKey: "draft.\(name)")
        }
    }

    private func perform(_ name: String, _ app: AppState, _ op: (API) async throws -> Void) async {
        guard let api = app.api, !busy.contains(name) else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await op(api)
            errorText = nil
        } catch {
            errorText = app.report(error)
            return
        }
        await load(app)
    }

    /// A waiting prompt that takes y/n gets the "y · Đồng ý" / "n · Từ chối" buttons.
    nonisolated static func isYesNo(_ preview: String?) -> Bool {
        guard let p = preview?.lowercased() else { return false }
        return ["(y/n)", "[y/n]", "yes/no"].contains { p.contains($0) }
    }
}
