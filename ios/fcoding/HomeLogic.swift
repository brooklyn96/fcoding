import Foundation

// MARK: - GET /api/home (contract home v2), decoded leniently

/// Every field is optional or defaults to empty: a missing or malformed part of the reply gives
/// an empty or stale state, never a decoding failure of the whole screen.
struct HomeData: Decodable {
    var generatedAt: Date?
    var box: HomeBox?
    var accounts: [QuotaAccount] = []
    var totals: HomeTotals?
    var projects: [HomeProject] = []

    init() {}

    private enum K: String, CodingKey { case generatedAt, box, accounts, totals, projects }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        generatedAt = c.date(.generatedAt)
        box = c.value(.box)
        let all: [QuotaAccount] = c.list(.accounts)
        accounts = all.filter { !$0.harness.isEmpty }
        totals = c.value(.totals)
        projects = c.list(.projects)
    }
}

struct HomeBox: Decodable {
    var state: String?
    var sleepsAt: Date?
    var maxRunMinutes: Double?
    var idlePauseMinutes: Double?
    var cooldownMinutes: Double?

    init(state: String? = "running", sleepsAt: Date?, maxRunMinutes: Double? = 480,
         idlePauseMinutes: Double? = 30, cooldownMinutes: Double? = 10) {
        self.state = state
        self.sleepsAt = sleepsAt
        self.maxRunMinutes = maxRunMinutes
        self.idlePauseMinutes = idlePauseMinutes
        self.cooldownMinutes = cooldownMinutes
    }

    private enum K: String, CodingKey { case state, sleepsAt, maxRunMinutes, idlePauseMinutes, cooldownMinutes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = c.value(.state)
        sleepsAt = c.date(.sleepsAt)
        maxRunMinutes = c.value(.maxRunMinutes)
        idlePauseMinutes = c.value(.idlePauseMinutes)
        cooldownMinutes = c.value(.cooldownMinutes)
    }
}

struct QuotaWindow: Decodable {
    var key: String
    var label: String
    /// nil = "not reported": the window is hidden everywhere.
    var usedPercent: Double?
    var resetsAt: Date?
    var periodSeconds: Double?

    init(key: String = "", label: String, usedPercent: Double?, resetsAt: Date?, periodSeconds: Double?) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.periodSeconds = periodSeconds
    }

    private enum K: String, CodingKey { case key, label, usedPercent, resetsAt, periodSeconds }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        key = c.value(.key) ?? ""
        label = c.value(.label) ?? key
        usedPercent = c.value(.usedPercent)
        resetsAt = c.date(.resetsAt)
        periodSeconds = c.value(.periodSeconds)
    }
}

struct SpendAmount: Decodable {
    var usd: Double = 0
    var tokens: Double = 0

    init(usd: Double, tokens: Double) { self.usd = usd; self.tokens = tokens }

    private enum K: String, CodingKey { case usd, tokens }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        usd = c.value(.usd) ?? 0
        tokens = c.value(.tokens) ?? 0
    }
}

struct DailySpend: Decodable {
    var date: String
    var usd: Double
    var tokens: Double

    private enum K: String, CodingKey { case date, usd, tokens }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = c.value(.date) ?? ""
        usd = c.value(.usd) ?? 0
        tokens = c.value(.tokens) ?? 0
    }
}

struct Spend: Decodable {
    var today: SpendAmount?
    var yesterday: SpendAmount?
    var last30: SpendAmount?
    var weeklyEstimate: SpendAmount?
    /// Oldest first.
    var daily30: [DailySpend] = []

    private enum K: String, CodingKey { case today, yesterday, last30, weeklyEstimate, daily30 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        today = c.value(.today)
        yesterday = c.value(.yesterday)
        last30 = c.value(.last30)
        weeklyEstimate = c.value(.weeklyEstimate)
        let days: [DailySpend] = c.list(.daily30)
        daily30 = days.sorted { $0.date < $1.date }
    }
}

struct QuotaAccount: Decodable, Identifiable {
    var id: String
    var harness: String
    var email: String
    var org: String?
    var plan: String?
    var fetchedAt: Date?
    var stale = false
    var rateLimited = false
    var windows: [QuotaWindow] = []
    var resetsAvailable = 0
    /// `resets.target`: the omp reset target; null while the account has no listing match.
    var resetTarget: String?
    var spend: Spend?

    init(id: String, harness: String, email: String, plan: String?, windows: [QuotaWindow]) {
        self.id = id
        self.harness = harness
        self.email = email
        self.plan = plan
        self.windows = windows
    }

    private enum K: String, CodingKey { case id, harness, email, org, plan, fetchedAt, stale, rateLimited, windows, resets, spend }
    private enum R: String, CodingKey { case available, target }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        email = c.value(.email) ?? ""
        harness = (c.value(.harness) ?? "").lowercased()
        id = c.value(.id) ?? "\(harness)/\(email)"
        org = c.value(.org)
        plan = c.value(.plan)
        fetchedAt = c.date(.fetchedAt)
        stale = c.value(.stale) ?? false
        rateLimited = c.value(.rateLimited) ?? false
        windows = c.list(.windows)
        let resets = try? c.nestedContainer(keyedBy: R.self, forKey: .resets)
        resetsAvailable = resets.flatMap { r -> Int? in (try? r.decodeIfPresent(Int.self, forKey: .available)) ?? nil } ?? 0
        resetTarget = resets.flatMap { r -> String? in (try? r.decodeIfPresent(String.self, forKey: .target)) ?? nil }
        spend = c.value(.spend)
    }

    /// Windows with a value; "not reported" ones are hidden (never branch on plan).
    var shown: [QuotaWindow] { windows.filter { $0.usedPercent != nil } }
    /// Codex "Reset" is offered only with a reset target and a credit left.
    var canCodexReset: Bool { harness == "codex" && resetTarget != nil && resetsAvailable > 0 }
    /// A weekly-or-longer window exists, so the weekly estimate row is shown.
    var hasWeekly: Bool { shown.contains { ($0.periodSeconds ?? 0) >= 6 * 86400 } }
}

struct HarnessSpend: Decodable {
    var harness: String
    var usd: Double

    private enum K: String, CodingKey { case harness, usd }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        harness = (c.value(.harness) ?? "").lowercased()
        usd = c.value(.usd) ?? 0
    }
}

struct HomeTotals: Decodable {
    var spend: Spend?
    var byHarness: [HarnessSpend] = []

    private enum K: String, CodingKey { case spend, byHarness }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        spend = c.value(.spend)
        byHarness = c.list(.byHarness)
    }
}

struct HomePR: Decodable {
    var number: Int
    var title: String
    /// "success" | "failure" | "pending" | "none"
    var checks: String

    private enum K: String, CodingKey { case number, title, checks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        number = c.value(.number) ?? 0
        title = c.value(.title) ?? ""
        checks = c.value(.checks) ?? "none"
    }
}

struct HomeRun: Decodable {
    var workflow: String
    /// "success" | "failure" | "in_progress"
    var status: String
    var at: Date?
    var url: String?

    init(status: String, at: Date?) { workflow = ""; self.status = status; self.at = at }

    private enum K: String, CodingKey { case workflow, status, at, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        workflow = c.value(.workflow) ?? ""
        status = c.value(.status) ?? ""
        at = c.date(.at)
        url = c.value(.url)
    }
}

struct HomeProject: Decodable {
    var name: String
    var branch: String?
    /// nil = the server could not read them (gh failed).
    var prs: [HomePR]?
    var lastRun: HomeRun?
    /// Placeholder before the server's first gh read (not a failure).
    var loading = false

    private enum K: String, CodingKey { case name, branch, prs, lastRun, loading }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = c.value(.name) ?? ""
        branch = c.value(.branch)
        let list: [HomePR] = c.list(.prs)
        prs = c.contains(.prs) && !((try? c.decodeNil(forKey: .prs)) ?? true) ? list : nil
        lastRun = c.value(.lastRun)
        loading = c.value(.loading) ?? false
    }
}

/// POST /api/codex-reset reply.
struct CodexResetReply: Decodable {
    var result: String
    var message: String?

    private enum K: String, CodingKey { case result, message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        result = c.value(.result) ?? "error"
        message = c.value(.message)
    }
}

/// One element that may fail to decode on its own.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
    func list<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent([Failable<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
    func date(_ key: Key) -> Date? { value(key).flatMap(HomeLogic.parseDate) }
}

// MARK: - Pure rules (Pane spec, mockup home.html)

enum HomeLogic {
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Numbers

    /// 1.5K / 227.9M / 5.6B; below 1000 the rounded number.
    static func compact(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.1fK", n / 1e3) }
        return String(Int(n.rounded()))
    }

    /// Pane fmtMoney: "$105.81" below $1000, else "$2.5K".
    static func usd(_ n: Double) -> String { n < 1000 ? String(format: "$%.2f", n) : String(format: "$%.1fK", n / 1000) }
    /// Pane fmtEstMoney: whole dollars from $100 ("$218"), for estimates.
    static func estUsd(_ n: Double) -> String { n >= 100 && n < 1000 ? String(format: "$%.0f", n) : usd(n) }
    static func tokens(_ n: Double) -> String { compact(n) + " tokens" }
    /// Pane spend row: "$105.81 · 227.9M tokens" ("≈ " first for the weekly estimate).
    static func spendLine(_ a: SpendAmount, approx: Bool = false) -> String {
        (approx ? "≈ " + estUsd(a.usd) : usd(a.usd)) + " · " + tokens(a.tokens)
    }

    static func clampPercent(_ n: Double?) -> Double { max(0, min(100, n ?? 0)) }

    // MARK: Time

    private static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Pane fmtDuration: rounded minutes, at least 1: "2d 10h" / "3h 05m" / "50m".
    static func duration(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((max(0, seconds) / 60).rounded())), d = m / 1440, h = m % 1440 / 60, mm = m % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(pad2(mm))m" }
        return "\(mm)m"
    }

    /// "hôm nay lúc 14:30" / "ngày mai lúc 09:05" / "28/10 lúc 07:00".
    static func exactAt(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let k = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let c = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        let day = k == 0 ? "hôm nay" : k == 1 ? "ngày mai" : "\(pad2(c.day ?? 0))/\(pad2(c.month ?? 0))"
        return "\(day) lúc \(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
    }

    /// "HH:MM" for the ring (hours may pass 99 only in theory; then they are just longer).
    static func hhmm(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(pad2(s / 3600)):\(pad2(s % 3600 / 60))"
    }

    static func hms(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(pad2(s / 3600)):\(pad2(s % 3600 / 60)):\(pad2(s % 60))"
    }

    /// Wall clock "9:41".
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return "\(c.hour ?? 0):\(pad2(c.minute ?? 0))"
    }

    /// "vừa xong" / "N phút trước" / "N giờ trước" / "N ngày trước".
    static func ago(_ seconds: TimeInterval) -> String {
        let m = Int(max(0, seconds) / 60)
        if m < 1 { return "vừa xong" }
        if m < 60 { return "\(m) phút trước" }
        if m < 1440 { return "\(m / 60) giờ trước" }
        return "\(m / 1440) ngày trước"
    }

    // MARK: Pace (Pane computePace)

    enum Level: Int, Comparable {
        case normal = 0, warn, low
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Pace: Equatable {
        var level: Level = .normal
        var note = ""
        var title = ""
        /// Even-pace mark in percent of the bar; shown only when 1 < tick < 99.
        var tick: Double = 0
        var flame = false
    }

    static func pace(_ w: QuotaWindow, now: Date) -> Pace {
        let used = clampPercent(w.usedPercent), left = 100 - used
        var r = Pace()
        func byLevel() -> Pace {
            r.level = left <= 10 ? .low : used >= 80 ? .warn : .normal
            return r
        }
        if left < 0.5 {
            r.level = .low
            r.note = "Đã chạm giới hạn"
            r.flame = true
            return r
        }
        guard let period = w.periodSeconds, period > 0, let resetsAt = w.resetsAt else { return byLevel() }
        let remain = max(0, resetsAt.timeIntervalSince(now)), elapsed = period - remain, frac = elapsed / period
        if frac < 0.05 || elapsed < 300 || used < 5 { return byLevel() }
        let projected = used / frac
        r.tick = max(0, min(100, frac * 100))
        if projected >= 100 {
            r.level = .low
            r.flame = true
            let out = left * elapsed / used
            if out < remain - 60 {
                r.note = "Chạm giới hạn sau " + duration(out)
                r.title = "~\(Int((projected - 100).rounded()))% vượt giới hạn lúc reset"
            } else {
                r.title = "~100% đã dùng lúc reset"
            }
            return r
        }
        if projected >= 90 {
            r.level = .warn
            r.note = "~\(max(1, Int((100 - projected).rounded())))% dư"
            r.title = "~\(Int(projected.rounded()))% đã dùng lúc reset"
            return r
        }
        r.tick = 0
        return r
    }

    /// "Còn 52%" (default) or "Đã dùng 48%".
    static func headline(_ w: QuotaWindow, showUsed: Bool) -> String {
        let u = Int(clampPercent(w.usedPercent).rounded())
        return showUsed ? "Đã dùng \(u)%" : "Còn \(100 - u)%"
    }

    /// "Reset sau 3h 10m", "Sắp reset", "Reset hôm nay lúc 12:51", "Chưa bắt đầu"; "" when the
    /// reset time is unknown.
    static func resetText(_ w: QuotaWindow, now: Date, exact: Bool, calendar: Calendar = .current) -> String {
        guard let at = w.resetsAt else { return "" }
        let remain = at.timeIntervalSince(now)
        // Pane: a rolling window (period <= 6 h) still at full length has not begun; grace
        // max(60 s, period / 100), only while the reset is ahead.
        if let period = w.periodSeconds, period <= 6 * 3600, clampPercent(w.usedPercent) <= 1, remain > 0,
           remain >= period - max(60, period / 100) {
            return "Chưa bắt đầu"
        }
        if exact { return "Reset " + exactAt(at, now: now, calendar: calendar) }
        return remain < 60 ? "Sắp reset" : "Reset sau " + duration(remain)
    }

    /// The tile shows the window in the worst state: pace colour first, then the least left.
    static func worst(_ windows: [QuotaWindow], now: Date) -> QuotaWindow? {
        windows.reduce(nil) { m, w in
            guard let m = m else { return w }
            let a = pace(w, now: now).level, b = pace(m, now: now).level
            return a > b || (a == b && clampPercent(w.usedPercent) > clampPercent(m.usedPercent)) ? w : m
        }
    }

    /// "data.int@x.vn" stays; a local part over 7 characters becomes its first 6 + "…".
    static func shortMail(_ e: String) -> String {
        guard let at = e.firstIndex(of: "@") else { return e }
        let user = e[..<at]
        return (user.count > 7 ? String(user.prefix(6)) + "…" : String(user)) + String(e[at...])
    }

    // MARK: Box ring

    enum RingMode: Hashable { case run, warn, paused, unknown }

    struct Ring: Equatable {
        var mode: RingMode
        /// Seconds to the next change (sleep, or wake while paused).
        var seconds: Int
        /// Arc length, 0...1.
        var fraction: Double
        var changeAt: Date?
    }

    /// Derived from `sleepsAt` alone (the server only sends state "running"). Before it: counts
    /// down to sleep (warn under 10 min). After it (the box is asleep and cannot answer): counts
    /// down to the estimated wake, sleepsAt + cooldown. `now` is the server clock.
    static func ring(_ box: HomeBox?, now: Date) -> Ring {
        guard let box = box, let sleeps = box.sleepsAt else { return Ring(mode: .unknown, seconds: 0, fraction: 0) }
        let maxRun = max(60, (box.maxRunMinutes ?? 480) * 60), cooldown = max(60, (box.cooldownMinutes ?? 10) * 60)
        let left = sleeps.timeIntervalSince(now)
        if left > 0 {
            let s = Int(left.rounded(.up))
            return Ring(mode: s < 600 ? .warn : .run, seconds: s, fraction: max(0, min(1, left / maxRun)), changeAt: sleeps)
        }
        let wake = sleeps.addingTimeInterval(cooldown)
        let rest = wake.timeIntervalSince(now)
        guard rest > 0 else { return Ring(mode: .unknown, seconds: 0, fraction: 0) }
        return Ring(mode: .paused, seconds: Int(rest.rounded(.up)), fraction: max(0, min(1, rest / cooldown)), changeAt: wake)
    }

    // MARK: Projects

    enum Tone { case ok, fail, pending, none }

    /// Third line of a project card.
    static func deployLine(_ run: HomeRun?, now: Date) -> (text: String, tone: Tone) {
        guard let run = run else { return ("deploy: chưa có", .none) }
        let when = run.at.map { ago(now.timeIntervalSince($0)) }
        switch run.status {
        case "success": return ("✓ deploy " + (when ?? ""), .ok)
        case "failure": return ("✗ deploy lỗi" + (when.map { " · " + $0 } ?? ""), .fail)
        case "in_progress", "queued", "pending": return ("◷ đang deploy", .pending)
        default: return ("deploy: \(run.status)", .none)
        }
    }

    /// First line of a project card (markdown bold for the count).
    static func prLine(_ p: HomeProject?) -> String {
        guard let p = p else { return "PR: chưa tải được" }
        if p.loading { return "đang đọc…" }
        guard let prs = p.prs else { return "chưa đọc được GitHub" }
        return prs.isEmpty ? "không có PR mở" : "**\(prs.count)** PR đang mở"
    }

    /// Second line of a project card: the worst PR checks result.
    static func checksLine(_ prs: [HomePR]?, branch: String?) -> (text: String, tone: Tone) {
        let checks = (prs ?? []).map(\.checks)
        if checks.contains("failure") { return ("✗ checks PR lỗi", .fail) }
        if checks.contains("pending") { return ("◷ checks PR đang chạy", .pending) }
        if checks.contains("success") { return ("✓ checks PR đạt", .ok) }
        return (branch.map { "nhánh " + $0 } ?? "", .none)
    }

    // MARK: Spend donut

    struct Wedge: Equatable {
        var key: String
        var name: String
        var usd: Double
        /// Angles in radians, clockwise from 12 o'clock, gap included.
        var start: Double
        var end: Double
        var parts: String = ""
    }

    /// Pane donutEntries: spenders over $0.005, biggest first. Those under `fold` dollars fold
    /// into one "Khác" wedge, even a lone one, unless every spender is under it.
    static func donutEntries(_ input: [(key: String, name: String, usd: Double)], fold: Double = 10) -> [(key: String, name: String, usd: Double, parts: String)] {
        let sorted: [(key: String, name: String, usd: Double)] = input.filter { $0.usd > 0.005 }.sorted { $0.usd > $1.usd }
        let all: [(key: String, name: String, usd: Double, parts: String)] = sorted.map { (key: $0.key, name: $0.name, usd: $0.usd, parts: "") }
        let small = all.filter { $0.usd < fold }
        if small.isEmpty || small.count == all.count { return all }
        let names: [String] = small.map { "\($0.name) \(usd($0.usd))" }
        let other: (key: String, name: String, usd: Double, parts: String) =
            (key: "other", name: "Khác", usd: small.reduce(0) { $0 + $1.usd }, parts: names.joined(separator: ", "))
        let big = all.filter { $0.usd >= fold }
        return (big + [other]).sorted { $0.usd > $1.usd }
    }

    /// Pane donutGeometry: spans share the circle less a 2.2/37 rad gap per wedge; a span under
    /// 0.07 rad grows to 0.07 and the excess comes off the biggest one; the first starts at gap/2.
    static func donut(_ input: [(key: String, name: String, usd: Double)], fold: Double = 10) -> [Wedge] {
        let parts = donutEntries(input, fold: fold)
        let total = parts.reduce(0) { $0 + $1.usd }
        guard total > 0, !parts.isEmpty else { return [] }
        if parts.count == 1 {
            return [Wedge(key: parts[0].key, name: parts[0].name, usd: parts[0].usd, start: 0, end: 2 * .pi, parts: parts[0].parts)]
        }
        let pad = 2.2 / 37, minSpan = 0.07
        let avail = 2 * Double.pi - Double(parts.count) * pad
        var spans: [Double] = parts.map { $0.usd / total * avail }
        var excess = 0.0
        for i in spans.indices where spans[i] < minSpan {
            excess += minSpan - spans[i]
            spans[i] = minSpan
        }
        if excess > 0, let big = spans.indices.max(by: { spans[$0] < spans[$1] }) {
            spans[big] = max(minSpan, spans[big] - excess)
        }
        var wedges: [Wedge] = []
        var a = pad / 2
        for (i, p) in parts.enumerated() {
            wedges.append(Wedge(key: p.key, name: p.name, usd: p.usd, start: a, end: a + spans[i], parts: p.parts))
            a += spans[i] + pad
        }
        return wedges
    }

    // MARK: Server clock

    /// Server clock minus phone clock. The server stamps `generatedAt` just before it sends (after
    /// its slow parts resolved), so it is compared with the moment the reply arrived.
    static func clockOffset(generatedAt: Date?, received: Date) -> TimeInterval {
        guard let g = generatedAt else { return 0 }
        return g.timeIntervalSince(received)
    }

    // MARK: Codex reset reply

    /// done = the reset happened (or had already); canRetry = "Thử lại" may help (only when the
    /// server says nothing ran, so a retry cannot spend a second credit); reload = seconds after
    /// which GET /api/home is fetched again to show the real count.
    struct CodexOutcome: Equatable {
        var done = false
        var canRetry = false
        var text: String
        var reload: [Double] = []
        /// Status, not an error (the reset may be running): shown in the secondary colour.
        var info = false
    }

    static func codexOutcome(_ reply: CodexResetReply) -> CodexOutcome {
        let msg = reply.message?.trimmingCharacters(in: .whitespaces).isEmpty == false ? reply.message! : nil
        switch reply.result {
        case "reset", "already": return CodexOutcome(done: true, text: msg ?? "Đã reset")
        case "pending": return CodexOutcome(text: "Đang reset… kết quả sẽ hiện trong Hạn mức.", reload: [5, 20, 35, 50], info: true)
        case "nothing_to_reset": return CodexOutcome(text: msg ?? "Chưa cần reset: hạn mức vẫn còn")
        case "no_credit": return CodexOutcome(text: msg ?? "Không reset được: chưa có lượt reset")
        default: return CodexOutcome(canRetry: true, text: msg ?? "Không reset được, thử lại")
        }
    }

    /// Final outcomes of a failed POST /api/codex-reset; nil = an ordinary error that may be retried.
    static func codexFailure(status: Int, code: String?, timedOut: Bool) -> CodexOutcome? {
        // The reset may still be running on the box: never offer a retry (a new run spends a credit).
        if timedOut { return CodexOutcome(text: "Chưa nhận được kết quả. Xem lại Hạn mức sau ít giây.", reload: [0], info: true) }
        if status == 409 && code == "in_progress" {
            return CodexOutcome(text: "Một lượt reset khác đang chạy cho tài khoản này. Xem lại Hạn mức sau ít giây.", reload: [0],
                                info: true)
        }
        if status == 400 && code == "not_allowed" { return CodexOutcome(text: "Tài khoản này không reset được trong app.") }
        if status == 409 && code == "no_target" { return CodexOutcome(text: "Tài khoản này không có lượt reset.", reload: [0]) }
        if status == 503 && code == "unavailable" {
            return CodexOutcome(canRetry: true, text: "omp chưa sẵn sàng trên box. Thử lại sau ít phút.")
        }
        // A server that lists accounts has the route: this 404 means the account changed.
        if status == 404 && code == "unknown_account" {
            return CodexOutcome(text: "Không tìm thấy tài khoản này. Kéo xuống để tải lại.", reload: [0])
        }
        if [404, 405, 501].contains(status) { return CodexOutcome(text: "Máy chủ chưa hỗ trợ, cập nhật máy chủ trước.") }
        return nil
    }

    /// Rename refused with 409 reserved_name (CONTRACT A8): the new name is `<project>-<harness>`,
    /// the name a project's "open" reuses.
    /// The server's openName(project, harness), exactly: lowercased, every run of other
    /// characters than a-z 0-9 "-" made one "-", leading "-" removed, cut to 32.
    static func openName(_ project: String, _ harness: String) -> String {
        let s = (project + "-" + harness).lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+", with: "", options: .regularExpression)
        return String(s.prefix(32))
    }

    static func reservedNameMessage(_ name: String, projects: [String],
                                    harnesses: [String] = ["omp", "claude", "codex", "shell"]) -> String {
        for p in projects { for h in harnesses where name == openName(p, h) {
            return "Tên này dành cho phiên \(p) · \(h) mở từ dự án. Chọn tên khác."
        } }
        for h in harnesses where name.hasSuffix("-" + h) && name.count > h.count + 1 {
            return "Tên này dành cho phiên \(name.dropLast(h.count + 1)) · \(h) mở từ dự án. Chọn tên khác."
        }
        return "Tên này dành cho một phiên mở từ dự án. Chọn tên khác."
    }

    /// Session names the server accepts (NAME_RE): lowercase letters, digits and "-", 1-32.
    static func validSessionName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    // MARK: - Self-test

    /// Fixed cases; one line per failure (empty = all pass). Run by the CI self-test step.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got != want { failures.append("\(name): got \(got), want \(want)") }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hr = 3600.0, day = 86400.0
        func win(_ used: Double?, rem: Double?, per: Double?) -> QuotaWindow {
            QuotaWindow(label: "w", usedPercent: used, resetsAt: rem.map { now.addingTimeInterval($0) }, periodSeconds: per)
        }

        // Numbers
        eq("compact 999", compact(999), "999")
        eq("compact K", compact(1500), "1.5K")
        eq("compact M", compact(227.9e6), "227.9M")
        eq("compact B", compact(5.6e9), "5.6B")
        eq("usd small", usd(105.81), "$105.81")
        eq("usd zero", usd(0), "$0.00")
        eq("usd big", usd(2480), "$2.5K")
        eq("spend", spendLine(SpendAmount(usd: 3.1, tokens: 8.2e6)), "$3.10 · 8.2M tokens")
        eq("spend approx", spendLine(SpendAmount(usd: 4900, tokens: 12.1e9), approx: true), "≈ $4.9K · 12.1B tokens")

        // Durations and reset text
        eq("dur days", duration(2 * day + 10 * hr), "2d 10h")
        eq("dur hours", duration(3 * hr + 5 * 60), "3h 05m")
        eq("dur mins", duration(49 * 60 + 30), "50m")
        eq("dur round", duration(3 * hr + 10 * 60 + 40), "3h 11m")
        eq("dur min 1", duration(20), "1m")
        eq("est whole", spendLine(SpendAmount(usd: 218.4, tokens: 1e6), approx: true), "≈ $218 · 1.0M tokens")
        eq("est small", estUsd(58.4), "$58.40")
        eq("usd million", usd(1.2e6), "$1200.0K")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        eq("reset countdown", resetText(win(48, rem: 3 * hr + 600, per: 5 * hr), now: now, exact: false), "Reset sau 3h 10m")
        eq("reset soon", resetText(win(48, rem: 30, per: 5 * hr), now: now, exact: false), "Sắp reset")
        eq("not started", resetText(win(0, rem: 5 * hr, per: 5 * hr), now: now, exact: false), "Chưa bắt đầu")
        eq("grace ends", resetText(win(0, rem: 4 * hr + 55 * 60, per: 5 * hr), now: now, exact: false), "Reset sau 4h 55m")
        eq("grace 1%", resetText(win(1, rem: 4 * hr + 57 * 60, per: 5 * hr), now: now, exact: false), "Chưa bắt đầu")
        eq("weekly 0% starts", resetText(win(0, rem: 7 * day, per: 7 * day), now: now, exact: false), "Reset sau 7d 0h")
        eq("no reset time", resetText(win(10, rem: nil, per: 5 * hr), now: now, exact: false), "")
        // 1_800_000_000 = 2027-01-15 08:00 UTC
        eq("exact today", resetText(win(10, rem: 2 * hr, per: 5 * hr), now: now, exact: true, calendar: cal), "Reset hôm nay lúc 10:00")
        eq("exact tomorrow", resetText(win(10, rem: 20 * hr, per: 7 * day), now: now, exact: true, calendar: cal), "Reset ngày mai lúc 04:00")
        eq("exact date", resetText(win(10, rem: 3 * day, per: 7 * day), now: now, exact: true, calendar: cal), "Reset 18/01 lúc 08:00")

        // Pace
        eq("pace normal", pace(win(20, rem: 3 * hr, per: 5 * hr), now: now).level, .normal)
        eq("pace normal no tick", pace(win(20, rem: 3 * hr, per: 5 * hr), now: now).tick, 0)
        let warn = pace(win(72, rem: hr + 300, per: 5 * hr), now: now)   // frac 0.78, projected 92
        eq("pace warn", warn.level, .warn)
        eq("pace warn note", warn.note, "~8% dư")
        let low = pace(win(82, rem: 19 * hr + 600, per: 7 * day), now: now)   // frac ~0.887, projected ~92
        eq("pace weekly warn", low.level, .warn)
        let over = pace(win(60, rem: 4 * hr, per: 5 * hr), now: now)   // frac 0.2, projected 300
        eq("pace over", over.level, .low)
        eq("pace over flame", over.flame, true)
        eq("pace over note", over.note, "Chạm giới hạn sau 40m")
        eq("pace limit", pace(win(99.6, rem: hr, per: 5 * hr), now: now).note, "Đã chạm giới hạn")
        eq("fallback low", pace(win(91, rem: nil, per: nil), now: now).level, .low)
        eq("fallback warn", pace(win(80, rem: nil, per: nil), now: now).level, .warn)
        eq("early gate", pace(win(30, rem: 4.9 * hr, per: 5 * hr), now: now).level, .normal)
        eq("headline left", headline(win(48.4, rem: nil, per: nil), showUsed: false), "Còn 52%")
        eq("headline used", headline(win(48.6, rem: nil, per: nil), showUsed: true), "Đã dùng 49%")
        eq("worst", worst([win(20, rem: 3 * hr, per: 5 * hr), win(72, rem: hr + 300, per: 5 * hr)], now: now)?.usedPercent, 72)
        eq("worst empty", worst([], now: now)?.usedPercent, nil)

        // Window hiding
        let acc = QuotaAccount(id: "a", harness: "claude", email: "data.int@example.vn", plan: "Team",
                               windows: [win(7, rem: hr, per: 5 * hr), win(nil, rem: nil, per: 7 * day), win(44, rem: day, per: 7 * day)])
        eq("hide null window", acc.shown.count, 2)
        eq("has weekly", acc.hasWeekly, true)
        eq("short mail", shortMail("an.nguyen.dev@gmail.com"), "an.ngu…@gmail.com")
        eq("short mail cut 8", shortMail("data.int@example.vn"), "data.i…@example.vn")
        eq("short mail keep", shortMail("box@x.vn"), "box@x.vn")

        // Ring
        let r1 = ring(HomeBox(sleepsAt: now.addingTimeInterval(2 * hr + 14 * 60 + 5)), now: now)
        eq("ring run", r1.mode, .run)
        eq("ring hhmm", hhmm(r1.seconds), "02:14")
        eq("ring warn", ring(HomeBox(sleepsAt: now.addingTimeInterval(7 * 60)), now: now).mode, .warn)
        let r3 = ring(HomeBox(sleepsAt: now.addingTimeInterval(-50)), now: now)
        eq("ring paused", r3.mode, .paused)
        eq("ring paused secs", r3.seconds, 550)
        let paused = HomeBox(state: "paused", sleepsAt: now.addingTimeInterval(-100))
        eq("ring paused counts", ring(paused, now: now).seconds - ring(paused, now: now.addingTimeInterval(30)).seconds, 30)
        eq("ring ignores state", ring(HomeBox(state: "paused", sleepsAt: now.addingTimeInterval(hr)), now: now).mode, .run)
        // Phone 4 min fast: the server clock (phone + offset) still sees 2 h before sleep.
        let phone = now.addingTimeInterval(240)
        let off = clockOffset(generatedAt: now, received: phone)
        eq("clock offset", off, -240)
        // A slow reply (the server waited on a refresh) does not shift the offset.
        eq("clock slow reply", clockOffset(generatedAt: now.addingTimeInterval(30), received: now.addingTimeInterval(30)), 0)
        eq("ring skew", ring(HomeBox(sleepsAt: now.addingTimeInterval(2 * hr)), now: phone.addingTimeInterval(off)).seconds, 7200)
        eq("clock no date", clockOffset(generatedAt: nil, received: now), 0)
        eq("ring woke", ring(HomeBox(sleepsAt: now.addingTimeInterval(-700)), now: now).mode, .unknown)
        eq("ring no data", ring(nil, now: now).mode, .unknown)
        eq("hms", hms(9 * 60 + 12), "00:09:12")

        // Projects
        eq("deploy ok", deployLine(HomeRun(status: "success", at: now.addingTimeInterval(-3 * hr)), now: now).text, "✓ deploy 3 giờ trước")
        eq("deploy none", deployLine(nil, now: now).text, "deploy: chưa có")
        eq("ago", ago(55 * 60), "55 phút trước")

        // Donut
        let pad = 2.2 / 37
        let d = donut([("codex", "Codex", 58.4), ("claude", "Claude", 6242)])
        eq("donut count", d.count, 2)
        eq("donut sorted", d.map(\.key), ["claude", "codex"])
        eq("donut start", abs(d[0].start - pad / 2) < 1e-9, true)
        eq("donut 58.4 is 0.07 rad", abs((d[1].end - d[1].start) - 0.07) < 1e-9, true)
        let mid = donut([("claude", "Claude", 600), ("codex", "Codex", 200)])
        eq("donut real share", abs((mid[1].end - mid[1].start) - 0.25 * (2 * Double.pi - 2 * pad)) < 1e-9, true)
        let tiny = donut([("claude", "Claude", 6242), ("codex", "Codex", 10.5)])
        eq("donut min span", abs((tiny[1].end - tiny[1].start) - 0.07) < 1e-9, true)
        eq("donut excess off big", abs((tiny[0].end - tiny[0].start) - (2 * Double.pi - 2 * pad - 0.07)) < 1e-9, true)
        eq("donut closes", abs(tiny[1].end + pad / 2 - 2 * Double.pi) < 1e-9, true)
        eq("donut fold", donut([("a", "A", 3), ("b", "B", 4), ("c", "C", 50)]).map(\.name), ["C", "Khác"])
        eq("donut fold lone", donut([("a", "A", 3), ("c", "C", 50)]).map(\.name), ["C", "Khác"])
        eq("donut all small", donut([("a", "A", 3), ("b", "B", 4)]).map(\.name), ["B", "A"])
        eq("donut floor", donut([("a", "A", 0.004), ("c", "C", 50)]).map(\.name), ["C"])
        eq("donut one", donut([("a", "A", 3)]).first?.end, Double.pi * 2)
        eq("donut empty", donut([("a", "A", 0)]).count, 0)

        // Lenient decoding
        let json = """
        {"box":{"state":"running","sleepsAt":"2027-01-15T10:00:00.000Z","maxRunMinutes":480},
         "accounts":[{"id":"x","harness":"Codex","email":"e@x","windows":[{"key":"5h","label":"5 giờ","usedPercent":18,"resetsAt":"2027-01-15T09:00:00Z","periodSeconds":18000},{"key":"7d","label":"7 ngày","usedPercent":null}],"resets":{"available":1,"target":"openai-codex/4"},"spend":{"today":{"usd":3.1,"tokens":8200000},"daily30":[{"date":"2027-01-02","usd":1,"tokens":2},{"date":"2027-01-01","usd":1,"tokens":1}]}},
                     {"harness":5}],
         "projects":[{"name":"deal-sync","prs":null,"lastRun":null},{"name":"c","repo":null,"branch":null,"prs":null,"lastRun":null,"loading":true},{"name":"b","prs":[{"number":6,"checks":"failure"}]}],
         "totals":"broken"}
        """
        if let h = try? JSONDecoder().decode(HomeData.self, from: Data(json.utf8)) {
            eq("decode accounts", h.accounts.count, 1)
            eq("decode harness", h.accounts.first?.harness, "codex")
            eq("decode shown", h.accounts.first?.shown.count, 1)
            eq("decode resets", h.accounts.first?.resetsAvailable, 1)
            eq("decode reset target", h.accounts.first?.resetTarget, "openai-codex/4")
            eq("codex reset offered", h.accounts.first?.canCodexReset, true)
            eq("decode daily sorted", h.accounts.first?.spend?.daily30.map(\.tokens), [1, 2])
            eq("decode bad totals", h.totals == nil, true)
            eq("decode prs null", h.projects.first?.prs == nil, true)
            eq("pr line failed", prLine(h.projects.first), "chưa đọc được GitHub")
            eq("pr line count", prLine(h.projects.last), "**1** PR đang mở")
            eq("pr line loading", prLine(h.projects.dropFirst().first), "đang đọc…")
            eq("decode checks", checksLine(h.projects.last?.prs, branch: nil).text, "✗ checks PR lỗi")
            eq("decode sleeps", h.box?.sleepsAt, now.addingTimeInterval(2 * hr))
        } else {
            failures.append("decode: lenient JSON failed")
        }
        let noTarget = """
        {"accounts":[{"id":"openai-codex/~1a2b3c4d","harness":"codex","email":"e@x","resets":{"available":2,"target":null}},
                     {"id":"openai-codex/4","harness":"codex","email":"f@x","resets":{"available":0,"target":"openai-codex/4"}}]}
        """
        let nt = try? JSONDecoder().decode(HomeData.self, from: Data(noTarget.utf8))
        eq("no target no reset", nt?.accounts.first?.canCodexReset, false)
        eq("no target nil", nt?.accounts.first?.resetTarget == nil, true)
        eq("no credit no reset", nt?.accounts.last?.canCodexReset, false)
        eq("decode empty", (try? JSONDecoder().decode(HomeData.self, from: Data("{}".utf8)))?.accounts.count, 0)

        // Codex reset replies
        func reply(_ r: String, _ m: String? = nil) -> CodexResetReply {
            let body = m.map { "{\"result\":\"\(r)\",\"message\":\"\($0)\"}" } ?? "{\"result\":\"\(r)\"}"
            return try! JSONDecoder().decode(CodexResetReply.self, from: Data(body.utf8))
        }
        eq("codex reset", codexOutcome(reply("reset")).done, true)
        eq("codex already", codexOutcome(reply("already")).done, true)
        eq("codex no credit final", codexOutcome(reply("no_credit")).canRetry, false)
        eq("codex error retry", codexOutcome(reply("error")).canRetry, true)
        eq("codex message", codexOutcome(reply("error", "Mở codex trên box")).text, "Mở codex trên box")
        eq("codex pending", codexOutcome(reply("pending")),
           CodexOutcome(text: "Đang reset… kết quả sẽ hiện trong Hạn mức.", reload: [5, 20, 35, 50], info: true))
        eq("codex done no reload", codexOutcome(reply("reset")).reload, [])
        eq("codex 409 in_progress final", codexFailure(status: 409, code: "in_progress", timedOut: false),
           CodexOutcome(text: "Một lượt reset khác đang chạy cho tài khoản này. Xem lại Hạn mức sau ít giây.", reload: [0], info: true))
        eq("codex timeout final", codexFailure(status: 0, code: "timeout", timedOut: true),
           CodexOutcome(text: "Chưa nhận được kết quả. Xem lại Hạn mức sau ít giây.", reload: [0], info: true))
        eq("codex error is not info", codexOutcome(reply("error")).info, false)
        eq("reserved name", reservedNameMessage("deal-sync-codex", projects: ["deal", "deal-sync"]),
           "Tên này dành cho phiên deal-sync · codex mở từ dự án. Chọn tên khác.")
        eq("reserved name unknown project", reservedNameMessage("web-omp", projects: []),
           "Tên này dành cho phiên web · omp mở từ dự án. Chọn tên khác.")
        eq("reserved name no harness", reservedNameMessage("x", projects: []),
           "Tên này dành cho một phiên mở từ dự án. Chọn tên khác.")
        eq("open name", openName("My_App", "codex"), "my-app-codex")
        eq("open name lead", openName("__x  y", "omp"), "x-y-omp")
        eq("open name cut", openName(String(repeating: "a", count: 30), "claude"), String(repeating: "a", count: 30) + "-c")
        eq("reserved My_App", reservedNameMessage("my-app-codex", projects: ["My_App"]),
           "Tên này dành cho phiên My_App · codex mở từ dự án. Chọn tên khác.")
        eq("codex no_target", codexFailure(status: 409, code: "no_target", timedOut: false),
           CodexOutcome(text: "Tài khoản này không có lượt reset.", reload: [0]))
        eq("codex unavailable", codexFailure(status: 503, code: "unavailable", timedOut: false),
           CodexOutcome(canRetry: true, text: "omp chưa sẵn sàng trên box. Thử lại sau ít phút."))
        eq("codex unknown_account", codexFailure(status: 404, code: "unknown_account", timedOut: false),
           CodexOutcome(text: "Không tìm thấy tài khoản này. Kéo xuống để tải lại.", reload: [0]))
        eq("codex 404 not_found old server", codexFailure(status: 404, code: "not_found", timedOut: false)?.text,
           "Máy chủ chưa hỗ trợ, cập nhật máy chủ trước.")
        eq("codex not allowed", codexFailure(status: 400, code: "not_allowed", timedOut: false)?.canRetry, false)
        eq("codex old server", codexFailure(status: 405, code: "method", timedOut: false)?.canRetry, false)
        eq("codex other 409 retry", codexFailure(status: 409, code: "exists", timedOut: false) == nil, true)
        eq("codex 500 retry", codexFailure(status: 500, code: "error", timedOut: false) == nil, true)
        eq("name ok", validSessionName("deal-sync-omp-2"), true)
        eq("name upper", validSessionName("Deal"), false)
        eq("name dash first", validSessionName("-a"), false)
        return failures
    }
}
