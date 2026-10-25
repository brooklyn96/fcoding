import Foundation

/// GET /api/home for the top card, the quota detail and the project cards. The last good reply
/// stays on screen when a refresh fails (`failed` then marks it as old).
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var home: HomeData?
    /// When `home` arrived, on this phone's clock.
    @Published private(set) var loadedAt: Date?
    /// The last refresh failed; shown as "⚠ Cũ" next to the numbers.
    @Published private(set) var failed = false
    @Published private(set) var loading = false
    /// Server clock minus this phone's clock, from `generatedAt` (0 until a reply has one).
    @Published private(set) var offset: TimeInterval = 0

    /// Now on the server's clock: compare server times (sleepsAt, resetsAt, run times) with this.
    func serverNow(_ date: Date = Date()) -> Date { date.addingTimeInterval(offset) }

    private var current: Task<Void, Never>?

    /// One request at a time; a call during one waits for it.
    func load(_ app: AppState) async {
        if let running = current { await running.value; return }
        let task = Task { await self.fetch(app) }
        current = task
        await task.value
        current = nil
    }

    private func fetch(_ app: AppState) async {
        guard let api = app.api else { return }
        loading = true
        defer { loading = false }
        do {
            let reply = try await api.get("api/home", as: HomeData.self)
            let received = Date()
            if reply.generatedAt != nil {
                offset = HomeLogic.clockOffset(generatedAt: reply.generatedAt, received: received)
            }
            home = reply
            loadedAt = received
            failed = false
        } catch {
            // A 401 goes back to pairing; anything else keeps the last data, marked old.
            _ = app.report(error)
            if !(error is CancellationError) { failed = true }
        }
    }

    /// POST /api/codex-reset. `requestId` is minted once per confirm and reused on every retry.
    func codexReset(_ account: QuotaAccount, requestId: String, app: AppState) async -> (done: Bool, canRetry: Bool, text: String) {
        guard let api = app.api else { return (false, false, unpairedNotice) }
        do {
            let data = try await api.call("POST", "api/codex-reset", body: ["accountId": account.id, "requestId": requestId])
            let reply = try JSONDecoder().decode(CodexResetReply.self, from: data)
            return HomeLogic.codexOutcome(reply)
        } catch let e as APIError where e.status == 400 && e.code == "not_allowed" {
            return (false, false, "Tài khoản này không reset được trong app.")
        } catch let e as APIError where [404, 405, 501].contains(e.status) {
            return (false, false, "Máy chủ chưa hỗ trợ, cập nhật máy chủ trước.")
        } catch let e as APIError where e.status == 409 && e.code == "in_progress" {
            // Another reset of this account is running; the same requestId may be sent again.
            return (false, true, "Đang reset tài khoản này, thử lại sau ít giây.")
        } catch {
            return (false, true, "Không reset được: " + (app.report(error) ?? "lỗi mạng").lowercased(with: Locale(identifier: "vi")) + " Thử lại.")
        }
    }
}
