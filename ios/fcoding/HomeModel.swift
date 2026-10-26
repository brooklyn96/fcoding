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

    /// One request at a time; a call during one waits for it. `fresh`: the reply must come from a
    /// request started after this call (a project was just added), so one in flight is not enough.
    func load(_ app: AppState, fresh: Bool = false) async {
        if let running = current {
            await running.value
            guard fresh else { return }
            if let next = current { await next.value; return }
        }
        let task = Task {
            await self.fetch(app)
            self.current = nil
        }
        current = task
        await task.value
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
    func codexReset(_ account: QuotaAccount, requestId: String, app: AppState) async -> HomeLogic.CodexOutcome {
        guard let api = app.api else { return HomeLogic.CodexOutcome(text: unpairedNotice) }
        let outcome: HomeLogic.CodexOutcome
        do {
            let data = try await api.call("POST", "api/codex-reset", body: ["accountId": account.id, "requestId": requestId])
            outcome = HomeLogic.codexOutcome(try JSONDecoder().decode(CodexResetReply.self, from: data))
        } catch {
            let e = error as? APIError
            if let known = HomeLogic.codexFailure(status: e?.status ?? 0, code: e?.code,
                                                  timedOut: (error as? URLError)?.code == .timedOut) {
                outcome = known
            } else {
                let why = (app.report(error) ?? "lỗi mạng").lowercased(with: Locale(identifier: "vi"))
                outcome = HomeLogic.CodexOutcome(canRetry: true, text: "Không reset được: " + why + " Thử lại.")
            }
        }
        if !outcome.reload.isEmpty {
            // Refresh the count once the box has had time to finish (the sheet may be gone by then).
            Task {
                var waited = 0.0
                for at in outcome.reload {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, at - waited) * 1_000_000_000))
                    waited = at
                    await self.load(app)
                }
            }
        }
        return outcome
    }
}
