import Foundation

/// The first requests of an activation (GET api/home, GET api/prefs), started the moment the app
/// opens or comes back to the foreground, before the home screen exists, so the connection is
/// already open when it asks. The screen's first load takes the reply instead of asking again.
/// Each path is requested once per activation; a request that nobody takes within `reuse`
/// seconds is dropped and the next load asks afresh.
@MainActor
final class LaunchFetch {
    /// A second `start` for the same login within this many seconds adds nothing.
    static let dedupe: TimeInterval = 5
    /// A started request can be taken for this many seconds.
    static let reuse: TimeInterval = 10

    private struct Entry {
        let key: String
        let at: Date
        let task: Task<Data, Error>
        var taken = false
    }
    private var entries: [String: Entry] = [:]

    /// Starts GET `path` for each path unless this login already has one from the last `dedupe`
    /// seconds (taken or not). `key` names server + login (ResponseCache.key).
    func start(key: String, _ paths: [String], now: Date = Date(), get: @escaping @Sendable (String) async throws -> Data) {
        for path in paths {
            if let old = entries[path], old.key == key, now.timeIntervalSince(old.at) < LaunchFetch.dedupe { continue }
            entries[path] = Entry(key: key, at: now, task: Task { try await get(path) })
        }
    }

    /// The started request for `path`, once, when it is for this login and still fresh.
    func take(_ path: String, key: String, now: Date = Date()) -> Task<Data, Error>? {
        guard var entry = entries[path], entry.key == key, !entry.taken,
              now.timeIntervalSince(entry.at) < LaunchFetch.reuse else { return nil }
        entry.taken = true
        entries[path] = entry
        return entry.task
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func hit(_ path: String) { lock.lock(); counts[path, default: 0] += 1; lock.unlock() }
        func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    }

    /// One line per failure (empty = all pass).
    static func selfTest() async -> [String] {
        var failures: [String] = []
        let hits = Counter()
        let get: @Sendable (String) async throws -> Data = { hits.hit($0); return Data($0.utf8) }
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let paths = ["api/home", "api/prefs"]

        // The app opens: the start in AppState.init and the one on the first .active are one request.
        let f = LaunchFetch()
        f.start(key: "A", paths, now: t0, get: get)
        f.start(key: "A", paths, now: t0.addingTimeInterval(0.3), get: get)
        // The home screen's first load takes it (once); a second load asks for itself.
        let home = f.take("api/home", key: "A", now: t0.addingTimeInterval(0.4))
        if (try? await home?.value) != Data("api/home".utf8) { failures.append("take returns the started reply") }
        if f.take("api/home", key: "A", now: t0.addingTimeInterval(0.5)) != nil { failures.append("taken twice") }
        if f.take("api/prefs", key: "B", now: t0.addingTimeInterval(0.5)) != nil { failures.append("taken for another login") }
        // Taken, and a late .active start inside the window: still no second request.
        f.start(key: "A", paths, now: t0.addingTimeInterval(1), get: get)
        _ = try? await f.take("api/prefs", key: "A", now: t0.addingTimeInterval(1))?.value
        if hits.count("api/home") != 1 || hits.count("api/prefs") != 1 {
            failures.append("one launch is not one request each: home \(hits.count("api/home")), prefs \(hits.count("api/prefs"))")
        }

        // Back from the background later: a new request; one nobody took is too old to take.
        f.start(key: "A", paths, now: t0.addingTimeInterval(60), get: get)
        _ = try? await f.take("api/home", key: "A", now: t0.addingTimeInterval(61))?.value
        if f.take("api/prefs", key: "A", now: t0.addingTimeInterval(75)) != nil { failures.append("stale request taken") }
        f.start(key: "A", ["api/home"], now: t0.addingTimeInterval(120), get: get)
        _ = try? await f.take("api/home", key: "A", now: t0.addingTimeInterval(121))?.value
        if hits.count("api/home") != 3 { failures.append("a later activation does not request again: \(hits.count("api/home"))") }
        return failures
    }
}
