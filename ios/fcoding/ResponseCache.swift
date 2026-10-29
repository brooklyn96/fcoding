import Foundation
import CryptoKit

/// The last good GET /api/home and /api/overview bodies, kept in Caches so the home screen can
/// show them at launch while the first requests run. One file per endpoint, named for a hash of
/// server + token: a copy saved for another server or login is never read, and it is deleted
/// the next time this one loads. Reads, writes and deletes run in order on one serial queue.
enum ResponseCache {
    private static let queue = DispatchQueue(label: "fcode.response-cache", qos: .utility)

    private static var dir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("responses", isDirectory: true)
    }

    /// Hex SHA-256 of server + "\n" + token, so the token itself never reaches the disk.
    static func key(server: String, token: String) -> String {
        SHA256.hash(data: Data((server + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(_ name: String, key: String) -> String { "\(name).\(key).json" }

    /// The body decoded as T, or nil when it does not decode.
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    /// The saved body for `name` under `key` and when it was written, or nil. Synchronous (one
    /// small file, once per model) and after any write still queued. Copies of `name` saved
    /// under another key (other server or login) are deleted.
    static func load(_ name: String, key: String) -> (data: Data, savedAt: Date)? {
        #if DEBUG
        _ = checked
        #endif
        guard let dir = dir else { return nil }
        return queue.sync {
            let fm = FileManager.default
            let want = ResponseCache.fileName(name, key: key)
            for other in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where other.hasPrefix(name + ".") && other != want {
                try? fm.removeItem(at: dir.appendingPathComponent(other))
            }
            let url = dir.appendingPathComponent(want)
            guard let data = try? Data(contentsOf: url),
                  let savedAt = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            return (data, savedAt)
        }
    }

    /// Writes the body off the main thread; atomic, so a crash never leaves half a file.
    static func save(_ data: Data, _ name: String, key: String) {
        guard let dir = dir else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(ResponseCache.fileName(name, key: key)), options: .atomic)
        }
    }

    static func remove(_ name: String, key: String) {
        guard let dir = dir else { return }
        queue.async { try? FileManager.default.removeItem(at: dir.appendingPathComponent(ResponseCache.fileName(name, key: key))) }
    }

    /// Every saved body; for sign-out (AppState can call this when the login goes).
    static func clear() {
        guard let dir = dir else { return }
        queue.async { try? FileManager.default.removeItem(at: dir) }
    }

    #if DEBUG
    /// Runs `selfTest` once, on the first `load` of a Debug build.
    private static let checked: Void = {
        let failures = selfTest()
        assert(failures.isEmpty, "ResponseCache self-test: " + failures.joined(separator: "; "))
    }()
    #endif

    /// Key derivation and decode-or-nil; one line per failure (empty = all pass).
    static func selfTest() -> [String] {
        var failures: [String] = []
        let k = key(server: "https://a.example.com", token: "t1")
        if k.count != 64 || k.contains(where: { !"0123456789abcdef".contains($0) }) { failures.append("key not 64 hex: \(k)") }
        if k != key(server: "https://a.example.com", token: "t1") { failures.append("key not stable") }
        if k == key(server: "https://b.example.com", token: "t1") { failures.append("key same for another server") }
        if k == key(server: "https://a.example.com", token: "t2") { failures.append("key same for another token") }
        // The separator keeps "server + token" pairs apart that concatenate to the same text.
        if key(server: "https://a.example.com:1", token: "23") == key(server: "https://a.example.com:12", token: "3") {
            failures.append("key ambiguous")
        }
        if fileName("home", key: k).hasPrefix("overview.") { failures.append("file names overlap") }
        struct Probe: Decodable { let now: Double }
        if decode(Probe.self, Data("{\"now\":1}".utf8))?.now != 1 { failures.append("decode valid") }
        if decode(Probe.self, Data("{\"now\":".utf8)) != nil { failures.append("decode truncated") }
        if decode(Probe.self, Data()) != nil { failures.append("decode empty") }
        return failures
    }
}
