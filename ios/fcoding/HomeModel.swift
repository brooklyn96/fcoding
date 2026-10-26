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
    /// Requests started so far, and the number of the one in flight.
    private var starts = 0
    private var currentIndex = 0

    /// One request at a time; a call during one waits for it. `fresh`: the reply must come from
    /// a request started after this call (one already in flight may carry older server state).
    func load(_ app: AppState, fresh: Bool = false) async {
        let needed = starts + 1
        while let running = current {
            if !fresh || currentIndex >= needed { await running.value; return }
            await running.value
        }
        starts += 1
        let index = starts
        currentIndex = index
        // Cleared inside the task, so a waiter never sees a finished task as still running.
        let task = Task {
            await self.fetch(app)
            if self.currentIndex == index { self.current = nil }
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

    /// When "Bật" was tapped per project (this phone's clock); the chip shows "đang bật…" meanwhile.
    @Published private(set) var stagingStarted: [String: Date] = [:]
    /// The project list is on screen and the app in the foreground (ProjectsView's `polling`);
    /// the follow-up loads after "Bật" stop when it is not.
    var visible = false

    /// POST staging/start; returns the error text, nil on success. The server caches the box
    /// state for 30 s, so the home reply is fetched a few times until it can say "running".
    func startStaging(_ project: String, app: AppState) async -> String? {
        guard let api = app.api else { return unpairedNotice }
        stagingStarted[project] = Date()
        var failure: String?
        var replyState: String?
        do {
            let reply = try await api.startStaging(project: project)
            replyState = reply.state
            if reply.ok == false {
                failure = HomeLogic.stagingFailure(status: 200, code: reply.error) ?? "Không bật được staging."
            }
        } catch {
            let e = error as? APIError
            failure = HomeLogic.stagingFailure(status: e?.status ?? 0, code: e?.code)
                ?? "Không bật được staging: " + (app.report(error) ?? "lỗi mạng").lowercased(with: Locale(identifier: "vi"))
        }
        if failure != nil {
            stagingStarted[project] = nil
            return failure
        }
        // The "đang bật…" override stays until a load started after this reply shows running (or
        // its 180 s window ends): a load already in flight may still carry the cached old state.
        let reloads = HomeLogic.stagingReloads(replyState: replyState)
        Task {
            var waited = 0.0
            for at in reloads {
                try? await Task.sleep(nanoseconds: UInt64((at - waited) * 1_000_000_000))
                waited = at
                // Off screen: ProjectsView loads home again as soon as the list is back.
                guard self.visible else { break }
                await self.load(app, fresh: true)
                if self.home?.projects.first(where: { $0.name == project })?.staging?.state == "running" {
                    self.stagingStarted[project] = nil
                    break
                }
            }
        }
        return nil
    }
}
