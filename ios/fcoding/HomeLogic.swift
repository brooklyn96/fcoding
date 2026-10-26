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

/// Box copy vs GitHub (git-sync state); every field nil when the box has no entry.
struct HomeGit: Decodable {
    var behind: Int?
    /// Commits only on the box, not pushed.
    var ahead: Int?
    var dirty: Bool?
    var error: String?

    private enum K: String, CodingKey { case behind, ahead, dirty, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        behind = c.value(.behind)
        ahead = c.value(.ahead)
        dirty = c.value(.dirty)
        error = c.value(.error)
    }
}

struct HomeProject: Decodable {
    var name: String
    var branch: String?
    /// nil = the server could not read them (gh failed).
    var prs: [HomePR]?
    var lastRun: HomeRun?
    /// nil on an older server.
    var git: HomeGit?
    /// Placeholder before the server's first gh read (not a failure).
    var loading = false

    private enum K: String, CodingKey { case name, branch, prs, lastRun, git, loading }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = c.value(.name) ?? ""
        branch = c.value(.branch)
        let list: [HomePR] = c.list(.prs)
        prs = c.contains(.prs) && !((try? c.decodeNil(forKey: .prs)) ?? true) ? list : nil
        lastRun = c.value(.lastRun)
        git = c.value(.git)
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

/// GET /api/projects/jobs/<id> (CONTRACT A11): one "Thêm dự án" job.
struct ProjectJob: Decodable, Equatable {
    /// "running" | "done" | "failed"
    var state: String
    var code: String?
    var name: String?
    var repo: String?
    /// Only for NEED_KEY / NEED_WRITE.
    var pubkey: String?
    var keyUrl: String?
    var detail: String?

    private enum K: String, CodingKey { case state, code, name, repo, pubkey, keyUrl, detail }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = c.value(.state) ?? ""
        code = c.value(.code)
        name = c.value(.name)
        repo = c.value(.repo)
        pubkey = c.value(.pubkey)
        keyUrl = c.value(.keyUrl)
        detail = c.value(.detail)
    }
}

/// GET /api/github/repos (contract v2): the repos the box's GitHub token can see, newest first.
struct GitHubRepos: Decodable {
    var repos: [GitHubRepo] = []
    /// "no_github_token": the box has no GitHub login, so the list is empty.
    var reason: String?

    private enum K: String, CodingKey { case repos, reason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let all: [GitHubRepo] = c.list(.repos)
        repos = all.filter { !$0.repo.isEmpty }
        reason = c.value(.reason)
    }
}

struct GitHubRepo: Decodable, Identifiable {
    var repo: String
    var isPrivate = false
    var archived = false
    var canPush = false
    var updatedAt: Date?
    /// The box project already cloned from this repo.
    var onBox: String?
    var id: String { repo }

    private enum K: String, CodingKey { case repo, isPrivate = "private", archived, canPush, updatedAt, onBox }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        repo = c.value(.repo) ?? ""
        isPrivate = c.value(.isPrivate) ?? false
        archived = c.value(.archived) ?? false
        canPush = c.value(.canPush) ?? false
        updatedAt = c.date(.updatedAt)
        onBox = c.value(.onBox)
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

    enum Tone { case ok, fail, pending, warn, none }

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

    /// Extra card line under the branch line: the box copy is behind GitHub or cannot sync.
    /// `label` (VoiceOver) spells out the short visible text when it differs.
    static func gitLine(_ git: HomeGit?) -> (text: String, tone: Tone, label: String?)? {
        if let n = git?.behind, n > 0 { return ("⚠ chậm \(n) commit", .warn, "chậm \(n) commit so với GitHub") }
        if git?.error != nil { return ("⚠ không đồng bộ được", .warn, nil) }
        if let n = git?.ahead, n > 0 { return ("↑ \(n) commit chưa đẩy", .warn, "\(n) commit chỉ có trên box, chưa đẩy lên GitHub") }
        if git?.dirty == true { return ("✎ có sửa chưa lưu", .warn, "có thay đổi chưa commit trên box") }
        return nil
    }

    /// First line of a project card (markdown bold for the count).
    static func prLine(_ p: HomeProject?) -> String {
        guard let p = p else { return "PR: chưa tải được" }
        if p.loading { return "đang đọc…" }
        guard let prs = p.prs else { return "chưa đọc được GitHub" }
        return prs.isEmpty ? "không có PR mở" : "**\(prs.count)** PR đang mở"
    }

    /// First line of the "Tất cả" card: the sum of the known PR counts, never a 0 that hides
    /// projects still being read (loading) or not readable (gh failed).
    static func allPrLine(_ projects: [HomeProject]?) -> String {
        guard let projects = projects else { return "PR: chưa tải được" }
        let known = projects.compactMap(\.prs)
        let reading = projects.contains { $0.loading }
        if known.isEmpty && !projects.isEmpty { return reading ? "đang đọc…" : "chưa đọc được GitHub" }
        let n = known.reduce(0) { $0 + $1.count }
        if known.count == projects.count { return "**\(n)** PR đang mở" }
        // Short enough for the card's 158 pt line at 12.5 pt.
        return "**\(n)** PR · " + (reading ? "đang đọc" : "thiếu \(projects.count - known.count) dự án")
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
        // Twice: the box's quota refresh after a reset may wait ~10 s for omp's listing.
        case "reset", "already": return CodexOutcome(done: true, text: msg ?? "Đã reset", reload: [0, 12])
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
            // The server also reserves <project>-shell; the app offers no shell harness.
            if h == "shell" { return "Tên này dành riêng cho máy chủ. Chọn tên khác." }
            return "Tên này dành cho phiên \(p) · \(h) mở từ dự án. Chọn tên khác."
        } }
        for h in harnesses where h != "shell" && name.hasSuffix("-" + h) && name.count > h.count + 1 {
            return "Tên này dành cho phiên \(name.dropLast(h.count + 1)) · \(h) mở từ dự án. Chọn tên khác."
        }
        return "Tên này dành cho một phiên mở từ dự án. Chọn tên khác."
    }

    /// Session names the server accepts (NAME_RE): lowercase letters, digits and "-", 1-32.
    static func validSessionName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    // MARK: Add project (CONTRACT A11: the same rules as `fcode add`)

    static let badRepoText = "Link repo chưa đúng: dán link GitHub, ví dụ https://github.com/ten-tai-khoan/ten-repo."
    static let badNameText = "Tên chưa đúng: chỉ chữ thường không dấu, số và . _ - (tối đa 64), không dùng “home”."

    /// A pasted GitHub link (https://[www.]github.com/o/r[/tree/…][?…][#…], github.com/o/r,
    /// git@github.com:o/r.git) or a plain o/r, reduced to o/r: spaces trimmed, a trailing ".git"
    /// (any case) dropped. Another host stays as typed, so validRepo refuses it.
    static func cleanRepo(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var link = false
        if let m = r.range(of: "^git@github\\.com:", options: [.regularExpression, .caseInsensitive]) {
            r.removeSubrange(m)
            link = true
        } else if let m = r.range(of: "^(https://)?(www\\.)?github\\.com/", options: [.regularExpression, .caseInsensitive]) {
            r.removeSubrange(m)
            link = true
        }
        if link {
            r = String(r.prefix { $0 != "?" && $0 != "#" })
            r = r.split(separator: "/", omittingEmptySubsequences: false).prefix(2).joined(separator: "/")
        }
        return r.replacingOccurrences(of: "\\.git$", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// owner/repo with A-Z a-z 0-9 _ . - only; neither part only dots.
    static func validRepo(_ r: String) -> Bool {
        r.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
            && r.range(of: "^\\.+/|/\\.+$", options: .regularExpression) == nil
    }

    /// The typed name lower-cased (a trailing ".git" dropped), else the repo part lower-cased.
    static func projectName(repo: String, typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t.lowercased().replacingOccurrences(of: "\\.git$", with: "", options: .regularExpression) }
        guard let slash = repo.firstIndex(of: "/") else { return "" }
        return repo[repo.index(after: slash)...].lowercased()
    }

    static func validProjectName(_ n: String) -> Bool {
        n != "home" && n.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    /// The server's detail keywords that addCodeMessage turns into text (and so need no detail line).
    private static let dirConflictDetails = ["exists", "unsafe"]
    private static let pushGuardText = "Box không cài được chốt chặn push lên main. Thử lại sau."
    private static let failDetailTexts = [
        "install": pushGuardText, "verify": pushGuardText,
        "rewrite": "Cấu hình git trên box đang đổi hướng địa chỉ GitHub. Nhờ người quản lý box gỡ cấu hình đó rồi thử lại.",
        "config": "Box không ghi được cấu hình đăng nhập GitHub cho repo này. Thử lại sau.",
    ]

    /// True when the message already says everything this detail says: DIR_CONFLICT with no detail,
    /// "exists" or "unsafe"; FAILED with "install", "verify", "rewrite" or "config". Any other detail
    /// (a path, owner/repo) stays.
    static func addDetailIsKeyword(_ code: String?, _ detail: String?) -> Bool {
        let d = detail ?? ""
        switch code {
        case "DIR_CONFLICT": return d.isEmpty || dirConflictDetails.contains(d)
        case "FAILED": return failDetailTexts[d] != nil
        default: return false
        }
    }

    /// One short line per failed job code. `detail` and `name` (the job's project name) refine
    /// DIR_CONFLICT ("exists" / "unsafe") and FAILED ("install" / "verify" / "rewrite" / "config").
    static func addCodeMessage(_ code: String?, detail: String? = nil, name: String = "") -> String {
        switch code {
        case "NET_FAIL": return "Box không kết nối được GitHub, thử lại sau."
        case "NAME_USED", "CFG_CONFLICT": return "Tên này đã dùng cho dự án khác, đặt tên khác."
        case "DIR_CONFLICT":
            let dir = name.isEmpty ? "này" : name
            return detail == "unsafe" ? "Thư mục \(dir) trên box không an toàn. Chọn tên khác."
                                      : "Thư mục \(dir) đã có trên box. Chọn tên khác."
        case "FAILED" where addDetailIsKeyword(code, detail):
            return failDetailTexts[detail ?? ""] ?? pushGuardText
        case "REPO_ARCHIVED": return "Repo đã lưu trữ (archived), không ghi được."
        case "WRITE_BLOCKED": return "GitHub chặn tạo nhánh box/*, xem lại luật bảo vệ nhánh."
        case "CFG_BROKEN": return "Cấu hình FCode trên box bị hỏng, nhờ người quản lý box kiểm tra."
        case "BAD_ARGS": return "Repo hoặc tên dự án không hợp lệ."
        case "CLONE_FAIL": return "Không tải được repo về box, thử lại sau ít phút."
        case "TIMEOUT": return "Quá 10 phút chưa xong, thử lại sau."
        case "NEED_KEY", "NEED_WRITE": return "Box chưa có quyền vào repo này trên GitHub, thử lại."
        default: return "Không thêm được dự án, thử lại sau."
        }
    }

    /// The key page, only on github.com.
    static func keyPage(_ s: String?) -> URL? {
        guard let s = s, s.hasPrefix("https://github.com/") else { return nil }
        return URL(string: s)
    }

    // MARK: Repo list ("Hoặc chọn repo")

    static let noTokenText = "Box chưa có khóa GitHub để liệt kê repo, dán link repo ở trên."
    static let repoListFailText = "Không tải được danh sách repo, thử lại."

    /// The repos whose owner/name contains every word of the search (any case).
    static func filterRepos(_ repos: [GitHubRepo], query: String) -> [GitHubRepo] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.isEmpty ? repos : repos.filter { r in words.allSatisfy { r.repo.lowercased().contains($0) } }
    }

    /// Greyed with a note when it cannot be picked: on the box already, or read only.
    static func repoRow(_ r: GitHubRepo) -> (pickable: Bool, note: String?) {
        if r.onBox != nil { return (false, "đã có trên box") }
        if r.archived || !r.canPush { return (false, "chỉ đọc") }
        return (true, nil)
    }

    /// "cập nhật 3 ngày trước" within 30 days, then "cập nhật 05/03/2025"; "" when unknown.
    static func repoUpdated(_ d: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let d = d else { return "" }
        if now.timeIntervalSince(d) < 30 * 86400 { return "cập nhật " + ago(now.timeIntervalSince(d)) }
        let c = calendar.dateComponents([.day, .month, .year], from: d)
        return "cập nhật \(pad2(c.day ?? 0))/\(pad2(c.month ?? 0))/\(c.year ?? 0)"
    }

    /// The line shown instead of the list: nil = show the list (or hide it quietly on a server
    /// without the route); `retry` = offer "Thử lại".
    static func repoListNote(reason: String?, status: Int?, text: String?) -> (text: String, retry: Bool)? {
        if let status = status {
            if [404, 405, 501].contains(status) { return nil }
            return (status == 502 ? repoListFailText : text ?? repoListFailText, true)
        }
        return reason == "no_github_token" ? (noTokenText, false) : nil
    }

    struct AddState: Equatable {
        enum Phase: Hashable { case form, posting, polling(String), needKey(write: Bool), failed, done }
        var phase: Phase = .form
        /// What is sent (cleaned): kept for "Thử lại".
        var repo = ""
        var name = ""
        /// The error line; once done, the toast text (or the cleanup notice's text).
        var message: String?
        /// Added, but the box could not delete its check branch on GitHub: shown as a notice
        /// that stays until closed (a retry answers CFG_EXISTS without it), not as a toast.
        struct Cleanup: Equatable, Identifiable {
            let branch: String
            /// The repo's branches page on GitHub.
            let url: URL
            var id: String { branch }
        }
        var cleanup: Cleanup?
        var detail: String?
        var pubkey: String?
        var keyUrl: URL?
        /// Polls in a row that failed (network); the 5th ends the wait.
        var pollErrors = 0

        var busy: Bool {
            switch phase {
            case .posting, .polling: return true
            default: return false
            }
        }
    }

    enum AddEvent {
        case submit(repo: String, name: String)
        /// The same POST again (after the key was added on GitHub).
        case retry
        case accepted(job: String)
        /// `text`: the app's generic message for the error.
        case postFailed(status: Int, code: String, text: String?)
        case polled(ProjectJob)
        case pollFailed(status: Int, code: String, text: String?)
    }

    /// The add sheet's state machine: form → posting → polling (every 2 s) → done / needKey / failed.
    static func addReduce(_ old: AddState, _ event: AddEvent) -> AddState {
        var s = old
        switch event {
        case let .submit(repo, name):
            guard !s.busy else { return s }
            let r = cleanRepo(repo), n = projectName(repo: r, typed: name)
            s = AddState(phase: .form, repo: r, name: n)
            if !validRepo(r) { s.message = badRepoText } else if !validProjectName(n) { s.message = badNameText } else { s.phase = .posting }
        case .retry:
            guard !s.busy, validRepo(s.repo), validProjectName(s.name) else { return s }
            s = AddState(phase: .posting, repo: s.repo, name: s.name)
        case let .accepted(job):
            guard s.phase == .posting else { return s }
            if job.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil {
                s.phase = .polling(job)
            } else {
                s.phase = .failed
                s.message = "Máy chủ trả lời không hợp lệ."
            }
        case let .postFailed(status, code, text):
            guard s.phase == .posting else { return s }
            s.phase = .failed
            if status == 400 && code == "bad_repo" { s.message = badRepoText }
            else if status == 400 && code == "bad_name" { s.message = badNameText }
            else if [404, 405, 501].contains(status) { s.message = "Máy chủ chưa hỗ trợ thêm dự án, cập nhật máy chủ trước." }
            else { s.message = text ?? "Không thêm được dự án, thử lại." }
        case let .polled(job):
            guard case .polling = s.phase else { return s }
            s.pollErrors = 0
            // The server reuses a running job for the same name: a job for another repo (or name) is
            // not ours, so neither its key nor its success is shown.
            guard job.name == s.name, job.repo?.lowercased() == s.repo.lowercased() else {
                s.phase = .failed
                s.message = "Tên này đang được dùng để thêm repo khác, đặt tên khác."
                return s
            }
            let detail = job.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch job.state {
            case "done":
                let name = job.name ?? s.name
                s.phase = .done
                if job.code == "ADDED_WARN" {
                    // Exit 30 covers every failed check; only CLEANUP_FAIL's detail is the check branch.
                    let d = detail ?? ""
                    if d.range(of: "^(refs/heads/)?box/fcode-add-check(-[a-z0-9-]+)?$", options: .regularExpression) != nil {
                        let branch = d.replacingOccurrences(of: "^refs/heads/", with: "", options: .regularExpression)
                        s.message = "Đã thêm dự án \(name), nhưng box chưa xoá được nhánh kiểm tra \(branch) trên GitHub. Hãy xoá nhánh này trên GitHub."
                        // s.repo passed validRepo (owner/repo), so the URL always parses.
                        s.cleanup = URL(string: "https://github.com/\(s.repo)/branches").map { AddState.Cleanup(branch: branch, url: $0) }
                    } else {
                        s.message = "Đã thêm dự án, nhưng box kiểm tra lại chưa đạt hết, xem lại trên box."
                    }
                } else {
                    s.message = "Đã thêm dự án \(name)"
                }
            case "failed":
                let key = job.pubkey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if ["NEED_KEY", "NEED_WRITE"].contains(job.code ?? ""), !key.isEmpty {
                    s.phase = .needKey(write: job.code == "NEED_WRITE")
                    s.pubkey = key
                    s.keyUrl = keyPage(job.keyUrl)
                } else {
                    s.phase = .failed
                    s.message = addCodeMessage(job.code, detail: detail, name: s.name)
                }
                s.detail = detail?.isEmpty == false ? detail : nil
                // The message already says it: do not show the bare keyword under it.
                if addDetailIsKeyword(job.code, detail) { s.detail = nil }
            default:
                break   // "running", or a state this app does not know: keep polling
            }
        case let .pollFailed(status, _, text):
            guard case .polling = s.phase else { return s }
            if status == 404 || status == 401 || s.pollErrors >= 4 {
                s.phase = .failed
                s.message = status == 404 ? "Máy chủ không còn giữ việc thêm này. Bấm Thêm để thử lại."
                                          : text ?? "Mất kết nối với box, thử lại."
            } else {
                s.pollErrors += 1
            }
        }
        return s
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
        func projects(_ json: String) -> [HomeProject] {
            (try? JSONDecoder().decode(HomeData.self, from: Data("{\"projects\":[\(json)]}".utf8)))?.projects ?? []
        }
        let ld = "{\"name\":\"a\",\"prs\":null,\"loading\":true}", fail = "{\"name\":\"b\",\"prs\":null}"
        let two = "{\"name\":\"c\",\"prs\":[{\"number\":1},{\"number\":2}]}", none = "{\"name\":\"d\",\"prs\":[]}"
        eq("all no data", allPrLine(nil), "PR: chưa tải được")
        eq("all loading", allPrLine(projects(ld + "," + ld)), "đang đọc…")
        eq("all failed", allPrLine(projects(fail + "," + fail)), "chưa đọc được GitHub")
        eq("all loading and failed", allPrLine(projects(ld + "," + fail)), "đang đọc…")
        eq("all known", allPrLine(projects(two + "," + none)), "**2** PR đang mở")
        eq("all part loading", allPrLine(projects(two + "," + ld + "," + fail)), "**2** PR · đang đọc")
        eq("all part failed", allPrLine(projects(two + "," + fail)), "**2** PR · thiếu 1 dự án")
        eq("all no projects", allPrLine([]), "**0** PR đang mở")
        eq("git old server", projects(none).first.map { $0.git == nil }, true)
        eq("git nil", gitLine(nil) == nil, true)
        eq("git null fields", gitLine(projects("{\"name\":\"e\",\"git\":{\"behind\":null,\"error\":null}}").first?.git) == nil, true)
        eq("git behind 0", gitLine(projects("{\"name\":\"e\",\"git\":{\"behind\":0,\"dirty\":false,\"error\":null}}").first?.git) == nil, true)
        let behind3 = gitLine(projects("{\"name\":\"e\",\"git\":{\"behind\":3,\"branch\":\"main\",\"error\":null}}").first?.git)
        eq("git behind 3", behind3?.text, "⚠ chậm 3 commit")
        eq("git behind tone", behind3?.tone, Tone.warn)
        eq("git behind label", behind3?.label, "chậm 3 commit so với GitHub")
        let gitErr = gitLine(projects("{\"name\":\"e\",\"git\":{\"behind\":null,\"error\":\"fetch failed\"}}").first?.git)
        eq("git error", gitErr?.text, "⚠ không đồng bộ được")
        eq("git error tone", gitErr?.tone, Tone.warn)
        eq("git error no label", gitErr.map { $0.label == nil }, true)
        func gl(_ git: String) -> (text: String, tone: Tone, label: String?)? {
            gitLine(projects("{\"name\":\"e\",\"git\":\(git)}").first?.git)
        }
        let ahead2 = gl("{\"behind\":0,\"ahead\":2,\"dirty\":false,\"error\":null}")
        eq("git ahead", ahead2?.text, "↑ 2 commit chưa đẩy")
        eq("git ahead tone", ahead2?.tone, Tone.warn)
        eq("git ahead label", ahead2?.label, "2 commit chỉ có trên box, chưa đẩy lên GitHub")
        let dirty = gl("{\"behind\":0,\"ahead\":0,\"dirty\":true,\"error\":null}")
        eq("git dirty", dirty?.text, "✎ có sửa chưa lưu")
        eq("git dirty tone", dirty?.tone, Tone.warn)
        eq("git dirty label", dirty?.label, "có thay đổi chưa commit trên box")
        eq("git behind wins", gl("{\"behind\":3,\"ahead\":2,\"dirty\":true}")?.text, "⚠ chậm 3 commit")
        eq("git error over ahead", gl("{\"ahead\":2,\"dirty\":true,\"error\":\"x\"}")?.text, "⚠ không đồng bộ được")
        eq("git ahead over dirty", gl("{\"ahead\":2,\"dirty\":true}")?.text, "↑ 2 commit chưa đẩy")
        eq("git clean", gl("{\"behind\":0,\"ahead\":0,\"dirty\":false,\"error\":null}") == nil, true)
        eq("git lenient types", gl("{\"ahead\":\"2\",\"dirty\":\"yes\"}") == nil, true)
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
        eq("codex done reloads", codexOutcome(reply("reset")).reload, [0, 12])
        eq("codex already reloads", codexOutcome(reply("already")).reload, [0, 12])
        eq("codex final no reload", codexOutcome(reply("nothing_to_reset")).reload, [])
        eq("codex 409 in_progress final", codexFailure(status: 409, code: "in_progress", timedOut: false),
           CodexOutcome(text: "Một lượt reset khác đang chạy cho tài khoản này. Xem lại Hạn mức sau ít giây.", reload: [0], info: true))
        eq("codex timeout final", codexFailure(status: 0, code: "timeout", timedOut: true),
           CodexOutcome(text: "Chưa nhận được kết quả. Xem lại Hạn mức sau ít giây.", reload: [0], info: true))
        eq("codex error is not info", codexOutcome(reply("error")).info, false)
        eq("reserved name", reservedNameMessage("deal-sync-codex", projects: ["deal", "deal-sync"]),
           "Tên này dành cho phiên deal-sync · codex mở từ dự án. Chọn tên khác.")
        eq("reserved name unknown project", reservedNameMessage("web-omp", projects: []),
           "Tên này dành cho phiên web · omp mở từ dự án. Chọn tên khác.")
        eq("reserved shell", reservedNameMessage("web-shell", projects: ["web"]), "Tên này dành riêng cho máy chủ. Chọn tên khác.")
        eq("reserved shell unknown", reservedNameMessage("web-shell", projects: []),
           "Tên này dành cho một phiên mở từ dự án. Chọn tên khác.")
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

        // Add project: validation (Invoke-Add rules)
        eq("repo clean .git", cleanRepo("  Me/My.Repo.GIT \n"), "Me/My.Repo")
        eq("link https", cleanRepo("https://github.com/Me/Web"), "Me/Web")
        eq("link www", cleanRepo("https://www.github.com/Me/Web"), "Me/Web")
        eq("link slash", cleanRepo("https://github.com/Me/Web/"), "Me/Web")
        eq("link .git", cleanRepo("https://github.com/Me/Web.git"), "Me/Web")
        eq("link query", cleanRepo("https://github.com/Me/Web?tab=readme"), "Me/Web")
        eq("link fragment", cleanRepo("https://github.com/Me/Web#readme"), "Me/Web")
        eq("link tree", cleanRepo("https://github.com/Me/Web/tree/main/src"), "Me/Web")
        eq("link no scheme", cleanRepo("github.com/Me/Web"), "Me/Web")
        eq("link upper host", cleanRepo("HTTPS://GitHub.com/Me/Web"), "Me/Web")
        eq("link ssh", cleanRepo("git@github.com:Me/Web.git"), "Me/Web")
        eq("link plain", cleanRepo("Me/Web"), "Me/Web")
        eq("link pasted newline", cleanRepo("https://github.com/Me/Web\n"), "Me/Web")
        eq("link pasted crlf tabs", cleanRepo("\t https://github.com/Me/Web.git\r\n"), "Me/Web")
        let pasted = addReduce(AddState(), .submit(repo: " https://github.com/Me/Web\n", name: "\tSite\n"))
        eq("pasted link posts", pasted.phase, .posting)
        eq("pasted link sent trimmed", pasted.repo, "Me/Web")
        eq("pasted name sent trimmed", pasted.name, "site")
        eq("link owner only", validRepo(cleanRepo("https://github.com/Me")), false)
        eq("link other host", validRepo(cleanRepo("https://gitlab.com/Me/Web")), false)
        eq("link other host bare", validRepo(cleanRepo("gitlab.com/Me/Web")), false)
        eq("link http", validRepo(cleanRepo("http://github.com/Me/Web")), false)
        eq("link other ssh", validRepo(cleanRepo("git@gitlab.com:Me/Web.git")), false)
        eq("link look-alike", validRepo(cleanRepo("https://github.com.evil.io/Me/Web")), false)
        eq("link plain extra path", validRepo(cleanRepo("Me/Web/tree/main")), false)
        eq("repo ok", validRepo("ten-tai-khoan/ten_repo.v2"), true)
        eq("repo no slash", validRepo("repo"), false)
        eq("repo two slashes", validRepo("a/b/c"), false)
        eq("repo dots owner", validRepo("../x"), false)
        eq("repo dots name", validRepo("me/.."), false)
        eq("repo dot inside", validRepo("me/.x"), true)
        eq("repo space", validRepo("me/my repo"), false)
        eq("repo url", validRepo("https://github.com/me/x"), false)
        eq("repo control", validRepo("me/x\u{7}"), false)
        eq("repo empty", validRepo(""), false)
        eq("default name", projectName(repo: "Me/My.Repo", typed: ""), "my.repo")
        eq("default name spaces", projectName(repo: "me/x", typed: "   "), "x")
        eq("typed name lower", projectName(repo: "me/x", typed: " Web.git "), "web")
        eq("name ok", validProjectName("my.repo_2-x"), true)
        eq("name home", validProjectName("home"), false)
        eq("name lead dot", validProjectName(".x"), false)
        eq("name lead underscore", validProjectName("_x"), false)
        eq("name 64", validProjectName(String(repeating: "a", count: 64)), true)
        eq("name 65", validProjectName(String(repeating: "a", count: 65)), false)
        eq("name accent", validProjectName("dự-án"), false)
        eq("name empty", validProjectName(""), false)

        // Add project: the repo list
        let list = try? JSONDecoder().decode(GitHubRepos.self, from: Data("""
        {"repos":[{"repo":"me/web","private":true,"archived":false,"canPush":true,"updatedAt":"2027-01-14T08:00:00Z","onBox":null},
                  {"repo":"me/deal-sync","private":false,"archived":false,"canPush":true,"updatedAt":"2026-12-01T00:00:00Z","onBox":"deal-sync"},
                  {"repo":"Org/Old-App","private":false,"archived":true,"canPush":true,"updatedAt":null,"onBox":null},
                  {"repo":"org/docs","private":false,"archived":false,"canPush":false},
                  {"private":true}, 7]}
        """.utf8))
        let repos = list?.repos ?? []
        eq("repos decode", repos.map(\.repo), ["me/web", "me/deal-sync", "Org/Old-App", "org/docs"])
        eq("repos private", repos.first?.isPrivate, true)
        eq("repos reason none", list.map { $0.reason == nil }, true)
        eq("repos no token", (try? JSONDecoder().decode(GitHubRepos.self, from: Data("{\"repos\":[],\"reason\":\"no_github_token\"}".utf8)))?.reason,
           "no_github_token")
        eq("filter empty", filterRepos(repos, query: "  ").count, 4)
        eq("filter case", filterRepos(repos, query: "OLD").map(\.repo), ["Org/Old-App"])
        eq("filter words", filterRepos(repos, query: "org doc").map(\.repo), ["org/docs"])
        eq("filter owner", filterRepos(repos, query: "me/").map(\.repo), ["me/web", "me/deal-sync"])
        eq("filter none", filterRepos(repos, query: "zzz").count, 0)
        eq("row pickable", repoRow(repos[0]).pickable, true)
        eq("row pickable no note", repoRow(repos[0]).note == nil, true)
        eq("row on box", repoRow(repos[1]).note, "đã có trên box")
        eq("row on box greyed", repoRow(repos[1]).pickable, false)
        eq("row archived", repoRow(repos[2]).note, "chỉ đọc")
        eq("row no push", repoRow(repos[3]).note, "chỉ đọc")
        eq("row no push greyed", repoRow(repos[3]).pickable, false)
        eq("updated recent", repoUpdated(repos[0].updatedAt, now: now, calendar: cal), "cập nhật 1 ngày trước")
        eq("updated old", repoUpdated(repos[1].updatedAt, now: now, calendar: cal), "cập nhật 01/12/2026")
        eq("updated unknown", repoUpdated(nil, now: now), "")
        eq("list no token", repoListNote(reason: "no_github_token", status: nil, text: nil)?.text, noTokenText)
        eq("list no token no retry", repoListNote(reason: "no_github_token", status: nil, text: nil)?.retry, false)
        eq("list ok", repoListNote(reason: nil, status: nil, text: nil) == nil, true)
        eq("list 502", repoListNote(reason: nil, status: 502, text: "x")?.text, repoListFailText)
        eq("list 502 retry", repoListNote(reason: nil, status: 502, text: "x")?.retry, true)
        eq("list network", repoListNote(reason: nil, status: 0, text: "Mất kết nối mạng.")?.text, "Mất kết nối mạng.")
        eq("list old server hidden", repoListNote(reason: nil, status: 404, text: "x") == nil, true)

        // Add project: code messages
        eq("msg net", addCodeMessage("NET_FAIL"), "Box không kết nối được GitHub, thử lại sau.")
        for c in ["NAME_USED", "CFG_CONFLICT"] {
            eq("msg \(c)", addCodeMessage(c), "Tên này đã dùng cho dự án khác, đặt tên khác.")
        }
        eq("msg dir exists", addCodeMessage("DIR_CONFLICT", detail: "exists", name: "web"), "Thư mục web đã có trên box. Chọn tên khác.")
        eq("msg dir no detail", addCodeMessage("DIR_CONFLICT", detail: nil, name: "web"), "Thư mục web đã có trên box. Chọn tên khác.")
        eq("msg dir unsafe", addCodeMessage("DIR_CONFLICT", detail: "unsafe", name: "web"), "Thư mục web trên box không an toàn. Chọn tên khác.")
        eq("msg dir no name", addCodeMessage("DIR_CONFLICT"), "Thư mục này đã có trên box. Chọn tên khác.")
        for d in ["install", "verify"] {
            eq("msg hook \(d)", addCodeMessage("FAILED", detail: d), "Box không cài được chốt chặn push lên main. Thử lại sau.")
        }
        eq("msg failed other detail", addCodeMessage("FAILED", detail: "x"), "Không thêm được dự án, thử lại sau.")
        eq("msg hook detail other code", addCodeMessage("CLONE_FAIL", detail: "install"), "Không tải được repo về box, thử lại sau ít phút.")
        eq("msg archived", addCodeMessage("REPO_ARCHIVED"), "Repo đã lưu trữ (archived), không ghi được.")
        eq("msg blocked", addCodeMessage("WRITE_BLOCKED"), "GitHub chặn tạo nhánh box/*, xem lại luật bảo vệ nhánh.")
        eq("msg timeout", addCodeMessage("TIMEOUT"), "Quá 10 phút chưa xong, thử lại sau.")
        eq("msg unknown", addCodeMessage("XYZ"), "Không thêm được dự án, thử lại sau.")
        eq("msg nil", addCodeMessage(nil), "Không thêm được dự án, thử lại sau.")
        for c in ["CFG_BROKEN", "BAD_ARGS", "CLONE_FAIL", "FAILED"] {
            eq("msg \(c) one line", addCodeMessage(c).contains("\n"), false)
        }
        eq("key page github", keyPage("https://github.com/me/x/settings/keys/new")?.absoluteString,
           "https://github.com/me/x/settings/keys/new")
        eq("key page other host", keyPage("https://evil.example/x") == nil, true)
        eq("key page nil", keyPage(nil) == nil, true)

        // Add project: the poll state machine
        /// A job reply; name "web" and repo "Me/Web" (what `a` submits) unless the JSON sets them.
        func job(_ json: String) -> ProjectJob {
            var j = json
            if !j.contains("\"name\"") { j = "{\"name\":\"web\"," + j.dropFirst() }
            if !j.contains("\"repo\"") { j = "{\"repo\":\"Me/Web\"," + j.dropFirst() }
            return try! JSONDecoder().decode(ProjectJob.self, from: Data(j.utf8))
        }
        var a = addReduce(AddState(), .submit(repo: "me/x", name: "home"))
        eq("submit bad name", a.phase, .form)
        eq("submit bad name text", a.message, badNameText)
        a = addReduce(AddState(), .submit(repo: "x", name: ""))
        eq("submit bad repo text", a.message, badRepoText)
        a = addReduce(AddState(), .submit(repo: " Me/Web.git ", name: ""))
        eq("submit posts", a.phase, .posting)
        eq("submit repo", a.repo, "Me/Web")
        eq("submit name", a.name, "web")
        eq("busy posting", a.busy, true)
        eq("submit while busy ignored", addReduce(a, .submit(repo: "o/p", name: "")).repo, "Me/Web")
        eq("bad job id", addReduce(a, .accepted(job: "../x")).phase, .failed)
        a = addReduce(a, .accepted(job: "j1"))
        eq("accepted polls", a.phase, .polling("j1"))
        a = addReduce(a, .polled(job("{\"state\":\"running\",\"code\":null}")))
        eq("running keeps polling", a.phase, .polling("j1"))
        a = addReduce(a, .polled(job("{\"state\":\"queued\"}")))
        eq("unknown state keeps polling", a.phase, .polling("j1"))
        var net = a
        for _ in 0..<4 { net = addReduce(net, .pollFailed(status: 0, code: "", text: "Mất kết nối mạng.")) }
        eq("4 poll errors keep polling", net.phase, .polling("j1"))
        eq("poll error count", net.pollErrors, 4)
        eq("poll ok resets count", addReduce(net, .polled(job("{\"state\":\"running\"}"))).pollErrors, 0)
        net = addReduce(net, .pollFailed(status: 0, code: "", text: "Mất kết nối mạng."))
        eq("5th poll error fails", net.phase, .failed)
        eq("5th poll error text", net.message, "Mất kết nối mạng.")
        let gone = addReduce(a, .pollFailed(status: 404, code: "no_job", text: nil))
        eq("no_job fails", gone.phase, .failed)
        eq("no_job text", gone.message, "Máy chủ không còn giữ việc thêm này. Bấm Thêm để thử lại.")
        let need = addReduce(a, .polled(job("""
        {"state":"failed","code":"NEED_KEY","name":"web","repo":"Me/Web","pubkey":"ssh-ed25519 AAAA fcode","keyUrl":"https://github.com/Me/Web/settings/keys/new","detail":null}
        """)))
        eq("need key", need.phase, .needKey(write: false))
        eq("need key pubkey", need.pubkey, "ssh-ed25519 AAAA fcode")
        eq("need key url", need.keyUrl?.absoluteString, "https://github.com/Me/Web/settings/keys/new")
        eq("need key not busy", need.busy, false)
        let again = addReduce(need, .retry)
        eq("retry posts again", again.phase, .posting)
        eq("retry same repo", again.repo, "Me/Web")
        eq("retry same name", again.name, "web")
        eq("retry clears key", again.pubkey == nil, true)
        let write = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"NEED_WRITE\",\"pubkey\":\"ssh-ed25519 B\",\"keyUrl\":\"http://x\"}")))
        eq("need write", write.phase, .needKey(write: true))
        eq("need write bad url dropped", write.keyUrl == nil, true)
        let nokey = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"NEED_KEY\"}")))
        eq("need key without pubkey fails", nokey.phase, .failed)
        let arch = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"REPO_ARCHIVED\",\"detail\":\"  archived  \"}")))
        eq("failed code", arch.phase, .failed)
        eq("failed message", arch.message, "Repo đã lưu trữ (archived), không ghi được.")
        eq("failed detail", arch.detail, "archived")
        let dirEx = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"DIR_CONFLICT\",\"detail\":\"exists\"}")))
        eq("dir exists message", dirEx.message, "Thư mục web đã có trên box. Chọn tên khác.")
        eq("dir exists no bare detail", dirEx.detail == nil, true)
        eq("dir unsafe message", addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"DIR_CONFLICT\",\"detail\":\"unsafe\"}"))).message,
           "Thư mục web trên box không an toàn. Chọn tên khác.")
        eq("dir no detail message", addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"DIR_CONFLICT\"}"))).message,
           "Thư mục web đã có trên box. Chọn tên khác.")
        let hook = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"FAILED\",\"detail\":\"verify\"}")))
        eq("hook message", hook.message, "Box không cài được chốt chặn push lên main. Thử lại sau.")
        eq("hook no bare detail", hook.detail == nil, true)
        eq("hook install no bare detail", addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"FAILED\",\"detail\":\"install\"}"))).detail == nil, true)
        eq("dir unsafe no bare detail", addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"DIR_CONFLICT\",\"detail\":\"unsafe\"}"))).detail == nil, true)
        let dirOther = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"DIR_CONFLICT\",\"detail\":\"/data/workspace/web\"}")))
        eq("dir unknown detail kept", dirOther.detail, "/data/workspace/web")
        eq("dir unknown detail message", dirOther.message, "Thư mục web đã có trên box. Chọn tên khác.")
        let rewrite = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"FAILED\",\"detail\":\"rewrite\"}")))
        eq("rewrite message", rewrite.message, "Cấu hình git trên box đang đổi hướng địa chỉ GitHub. Nhờ người quản lý box gỡ cấu hình đó rồi thử lại.")
        eq("rewrite no bare detail", rewrite.detail == nil, true)
        let cred = addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"FAILED\",\"detail\":\"config\"}")))
        eq("config message", cred.message, "Box không ghi được cấu hình đăng nhập GitHub cho repo này. Thử lại sau.")
        eq("config no bare detail", cred.detail == nil, true)
        eq("failed other detail kept", addReduce(a, .polled(job("{\"state\":\"failed\",\"code\":\"FAILED\",\"detail\":\"boom\"}"))).detail, "boom")
        eq("resubmit after failure", addReduce(arch, .submit(repo: "Me/Web", name: "web2")).phase, .posting)
        let done = addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED\",\"name\":\"web\"}")))
        eq("done", done.phase, .done)
        eq("done toast", done.message, "Đã thêm dự án web")
        eq("done no cleanup notice", done.cleanup == nil, true)
        let addedWarn = addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"refs/heads/box/fcode-add-check\"}")))
        eq("done warn", addedWarn.phase, .done)
        func cleanupText(_ branch: String) -> String {
            "Đã thêm dự án web, nhưng box chưa xoá được nhánh kiểm tra \(branch) trên GitHub. Hãy xoá nhánh này trên GitHub."
        }
        eq("done warn cleanup notice", addedWarn.cleanup,
           AddState.Cleanup(branch: "box/fcode-add-check", url: URL(string: "https://github.com/Me/Web/branches")!))
        eq("done warn cleanup text", addedWarn.message, cleanupText("box/fcode-add-check"))
        let generic = "Đã thêm dự án, nhưng box kiểm tra lại chưa đạt hết, xem lại trên box."
        eq("done warn no detail", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\"}"))).message, generic)
        eq("done warn no detail toast", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\"}"))).cleanup == nil, true)
        eq("done warn other detail", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"refs/heads/box/x\"}"))).message,
           generic)
        eq("done warn cfg detail", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"pr list failed\"}"))).message,
           generic)
        eq("done warn bare branch", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\" box/fcode-add-check \"}"))).message,
           cleanupText("box/fcode-add-check"))
        let suffixed = addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"refs/heads/box/fcode-add-check-k3x9-2\"}")))
        eq("done warn suffixed ref", suffixed.message, cleanupText("box/fcode-add-check-k3x9-2"))
        eq("done warn suffixed branch", suffixed.cleanup?.branch, "box/fcode-add-check-k3x9-2")
        eq("done warn suffixed bare", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"box/fcode-add-check-ab12\"}"))).message,
           cleanupText("box/fcode-add-check-ab12"))
        let badSuffix = addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"box/fcode-add-check-AB_1\"}")))
        eq("done warn bad suffix", badSuffix.message, generic)
        eq("done warn bad suffix toast", badSuffix.cleanup == nil, true)
        eq("done warn empty suffix", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"box/fcode-add-check-\"}"))).message,
           generic)
        eq("done warn suffix then path", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED_WARN\",\"detail\":\"box/fcode-add-check-x/y\"}"))).message,
           generic)
        // Another sheet's job (the server dedupes by name): never its key or its success.
        let conflict = "Tên này đang được dùng để thêm repo khác, đặt tên khác."
        let alice = addReduce(a, .polled(job("""
        {"state":"failed","code":"NEED_KEY","name":"web","repo":"alice/web","pubkey":"ssh-ed25519 ALICE","keyUrl":"https://github.com/alice/web/settings/keys/new"}
        """)))
        eq("other repo job fails", alice.phase, .failed)
        eq("other repo job message", alice.message, conflict)
        eq("other repo job no key", alice.pubkey == nil, true)
        eq("other repo done not ours", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED\",\"repo\":\"alice/web\"}"))).phase, .failed)
        eq("other repo running stops", addReduce(a, .polled(job("{\"state\":\"running\",\"repo\":\"alice/web\"}"))).phase, .failed)
        eq("other name job", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED\",\"name\":\"web2\"}"))).message, conflict)
        eq("job without repo not ours", addReduce(a, .polled(job("{\"state\":\"done\",\"repo\":null}"))).phase, .failed)
        eq("repo case ignored", addReduce(a, .polled(job("{\"state\":\"done\",\"code\":\"ADDED\",\"repo\":\"ME/WEB\"}"))).phase, .done)
        // A picked repo leaves the name empty: the default follows the link sent, never an older one.
        let picked = addReduce(AddState(), .submit(repo: "https://github.com/me/old-app", name: ""))
        eq("picked default name", picked.name, "old-app")
        let changed = addReduce(addReduce(picked, .postFailed(status: 503, code: "", text: nil)),
                                .submit(repo: "https://github.com/me/New-App/tree/main", name: ""))
        eq("link change new default", changed.name, "new-app")
        eq("link change repo", changed.repo, "me/New-App")
        eq("typed name kept over link", addReduce(AddState(), .submit(repo: "me/x", name: "mine")).name, "mine")
        eq("late poll after done ignored", addReduce(done, .polled(job("{\"state\":\"failed\",\"code\":\"NET_FAIL\"}"))).phase, .done)
        eq("late poll error after done ignored", addReduce(done, .pollFailed(status: 404, code: "no_job", text: nil)).phase, .done)
        let posting = addReduce(AddState(), .submit(repo: "me/x", name: ""))
        eq("post bad_repo", addReduce(posting, .postFailed(status: 400, code: "bad_repo", text: "x")).message, badRepoText)
        eq("post bad_name", addReduce(posting, .postFailed(status: 400, code: "bad_name", text: "x")).message, badNameText)
        eq("post old server", addReduce(posting, .postFailed(status: 404, code: "not_found", text: "x")).message,
           "Máy chủ chưa hỗ trợ thêm dự án, cập nhật máy chủ trước.")
        eq("post other", addReduce(posting, .postFailed(status: 503, code: "", text: "Box đang bận, thử lại sau.")).message,
           "Box đang bận, thử lại sau.")
        return failures
    }
}
