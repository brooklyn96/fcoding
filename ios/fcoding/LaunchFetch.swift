import Foundation

/// The first requests of an activation (GET api/home, GET api/prefs), started the moment the app
/// opens or comes back to the foreground, before the home screen asks, so the connection is
/// already open when it does. The screen's load calls `start` too (a no-op when one is already
/// out), then `take`: whichever side runs first, one request per path per activation.
@MainActor
final class LaunchFetch {
    /// A reply and when it arrived (this phone's clock).
    typealias Reply = (data: Data, at: Date)

    /// A second `start` for the same login within this many seconds adds nothing, and a request
    /// older than that is never taken (the next `start` replaces it).
    static let dedupe: TimeInterval = 5

    private struct Entry {
        let key: String
        let at: Date
        let task: Task<Reply, Error>
        var taken = false
    }
    private var entries: [String: Entry] = [:]

    /// Starts GET `path` for each path unless this login already has one from the last `dedupe`
    /// seconds (taken or not). `key` names server + login (ResponseCache.key).
    func start(key: String, _ paths: [String], now: Date = Date(), get: @escaping @Sendable (String) async throws -> Data) {
        for path in paths {
            if let old = entries[path], old.key == key, now.timeIntervalSince(old.at) < LaunchFetch.dedupe { continue }
            let task = Task<Reply, Error> {
                let data = try await get(path)
                return (data: data, at: Date())
            }
            entries[path] = Entry(key: key, at: now, task: task)
        }
    }

    /// The started request for `path`, once, when it is for this login, began at or after `since`
    /// (a caller that changed something on the box passes that time: an older reply may predate it)
    /// and is still fresh. The task may have failed; the caller then asks for itself.
    func take(_ path: String, key: String, since: Date = .distantPast, now: Date = Date()) -> Task<Reply, Error>? {
        guard var entry = entries[path], entry.key == key, !entry.taken, entry.at >= since,
              now.timeIntervalSince(entry.at) < LaunchFetch.dedupe else { return nil }
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

    private struct Boom: Error {}

    /// One line per failure (empty = all pass).
    static func selfTest() async -> [String] {
        var failures: [String] = []
        let hits = Counter()
        let get: @Sendable (String) async throws -> Data = { hits.hit($0); return Data($0.utf8) }
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let paths = ["api/home", "api/prefs"]

        // The app opens: the start in AppState.init, the screen's own start and the one on a
        // return to the foreground are one request.
        let f = LaunchFetch()
        f.start(key: "A", paths, now: t0, get: get)
        f.start(key: "A", paths, now: t0.addingTimeInterval(0.3), get: get)
        // The screen's first load takes it (once); a second load asks for itself.
        let home = f.take("api/home", key: "A", now: t0.addingTimeInterval(0.4))
        if (try? await home?.value)?.data != Data("api/home".utf8) { failures.append("take returns the started reply") }
        if f.take("api/home", key: "A", now: t0.addingTimeInterval(0.5)) != nil { failures.append("taken twice") }
        if f.take("api/prefs", key: "B", now: t0.addingTimeInterval(0.5)) != nil { failures.append("taken for another login") }
        // Taken, and a late start inside the window: still no second request.
        f.start(key: "A", paths, now: t0.addingTimeInterval(1), get: get)
        _ = try? await f.take("api/prefs", key: "A", now: t0.addingTimeInterval(1))?.value
        if hits.count("api/home") != 1 || hits.count("api/prefs") != 1 {
            failures.append("one launch is not one request each: home \(hits.count("api/home")), prefs \(hits.count("api/prefs"))")
        }

        // Later activation: a new request; one that nobody took within the window is never taken.
        f.start(key: "A", paths, now: t0.addingTimeInterval(60), get: get)
        _ = try? await f.take("api/home", key: "A", now: t0.addingTimeInterval(61))?.value
        if f.take("api/prefs", key: "A", now: t0.addingTimeInterval(75)) != nil { failures.append("stale request taken") }
        f.start(key: "A", ["api/home"], now: t0.addingTimeInterval(120), get: get)
        _ = try? await f.take("api/home", key: "A", now: t0.addingTimeInterval(121))?.value
        if hits.count("api/home") != 3 { failures.append("a later activation does not request again: \(hits.count("api/home"))") }

        // Bypass: a request that began before a change on the box (`since`) is not taken, and the
        // refused take does not use it up.
        let g = LaunchFetch()
        g.start(key: "A", ["api/prefs"], now: t0, get: get)
        if g.take("api/prefs", key: "A", since: t0.addingTimeInterval(1), now: t0.addingTimeInterval(1)) != nil {
            failures.append("request older than the last change taken")
        }
        if g.take("api/prefs", key: "A", since: t0, now: t0.addingTimeInterval(1)) == nil {
            failures.append("a refused take used up the request")
        }

        // A failed request comes back as a failed task (AppState.get then asks for itself) and
        // is not started again inside the window.
        let boom = Counter()
        let h = LaunchFetch()
        h.start(key: "A", ["api/home"], now: t0, get: { boom.hit($0); throw Boom() })
        h.start(key: "A", ["api/home"], now: t0.addingTimeInterval(1), get: get)
        var threw = false
        do { _ = try await h.take("api/home", key: "A", now: t0.addingTimeInterval(1))?.value } catch { threw = true }
        if !threw || boom.count("api/home") != 1 { failures.append("failed request not reported as failed, or retried inside the window") }
        return failures
    }
}
