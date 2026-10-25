import Foundation

/// HTTP error from the server ({error:"code"}), or a client-side problem (status 0).
/// `token` is the Bearer token the failing request carried (nil when unknown).
struct APIError: Error {
    var status: Int
    var code: String
    var retryAfter: Int? = nil
    var token: String? = nil
}

struct PairResponse: Decodable { let ok: Bool?; let token: String? }
struct Meta: Decodable { let projects: [String]; let harnesses: [String]? }
struct SessionsResponse: Decodable { let sessions: [SessionInfo] }
struct OpenResponse: Decodable { let name: String; let created: Bool? }
struct Screen: Decodable { let text: String; let rows: Int?; let cols: Int?; let hash: String? }

/// GET /api/overview (CONTRACT A5). Per-item failures arrive as nulls, so most fields are optional.
struct Overview: Decodable {
    let now: Double
    let projects: [ProjectInfo]
    let sessions: [OverviewSession]
}

struct ProjectInfo: Decodable, Hashable {
    let name: String
    let branch: String?
    let ahead: Int?
    let diff: DiffStat?
}

struct DiffStat: Decodable, Hashable { let files: Int; let add: Int; let del: Int }

struct OverviewSession: Decodable, Identifiable, Hashable {
    let name: String
    let project: String?
    let harness: String?
    let created: Double?
    let activity: Double?
    let attached: Bool?
    /// "running" | "waiting" | "idle" (anything else is shown as idle).
    let state: String?
    let preview: String?
    /// A numbered choice menu is on screen (A5 update 6); y/n pills are then hidden.
    let menu: Bool?
    var id: String { name }
}

/// POST /api/pair-code: a one-time code for another device, with its QR / share links.
struct PairCodeResponse: Decodable {
    let code: String
    let expiresAt: Date
    let appLink: String
    let shareLink: String

    private enum Key: String, CodingKey { case code, expiresAt, appLink, shareLink }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        code = try c.decode(String.self, forKey: .code)
        appLink = try c.decode(String.self, forKey: .appLink)
        shareLink = try c.decode(String.self, forKey: .shareLink)
        let raw = try c.decode(String.self, forKey: .expiresAt)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: c, debugDescription: "expiresAt")
        }
        expiresAt = date
    }
}

extension API {
    func pairCode() async throws -> PairCodeResponse {
        let data = try await call("POST", "api/pair-code", body: [:])
        return try JSONDecoder().decode(PairCodeResponse.self, from: data)
    }

    func overview() async throws -> Overview { try await get("api/overview", as: Overview.self) }

    /// POST /api/open with fresh:true: always a new session (CONTRACT A5 update 4).
    func openFresh(project: String, harness: String) async throws -> OpenResponse {
        let data = try await call("POST", "api/open", body: ["project": project, "harness": harness, "fresh": true])
        return try JSONDecoder().decode(OpenResponse.self, from: data)
    }
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let name: String
    let project: String?
    let harness: String?
    let attached: Bool?
    var id: String { name }

    var subtitle: String {
        var parts = [project, harness].compactMap { $0 }.filter { !$0.isEmpty }
        if attached == true { parts.append("đang mở ở nơi khác") }
        return parts.joined(separator: " · ")
    }
}

/// One server + token. Every request carries X-PC: 1 and, when a token exists, a Bearer header.
struct API {
    let base: URL
    let token: String

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                 body: [String: Any]? = nil, timeout: TimeInterval = 20) throws -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw APIError(status: 0, code: "bad_url") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "X-PC")
        req.setValue("ios", forHTTPHeaderField: "X-PC-Client")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Bearer only: keep the pc_sid Set-Cookie from /api/pair out of HTTPCookieStorage (on disk).
        req.httpShouldHandleCookies = false
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    @discardableResult
    func call(_ method: String, _ path: String, query: [URLQueryItem] = [],
              body: [String: Any]? = nil) async throws -> Data {
        let req = try request(method, path, query: query, body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try API.check(resp, data, token: token)
        return data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call("GET", path))
    }

    static func check(_ resp: URLResponse, _ data: Data, token: String? = nil) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError(status: 0, code: "bad_response", token: token) }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let header = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw APIError(status: http.statusCode,
                           code: obj?["error"] as? String ?? "",
                           retryAfter: header ?? (obj?["retryAfter"] as? Int),
                           token: token)
        }
    }
}

/// Shown after any 401 or SSE gone {"reason":"auth"}: the box no longer knows this device.
let unpairedNotice = "iPhone này đã bị gỡ khỏi box, hãy ghép lại."

/// Plain-Vietnamese text for any error the app can hit. Returns nil for cancellations.
/// `pairing` selects the wording for POST /api/pair.
func vietnameseMessage(_ error: Error, pairing: Bool = false) -> String? {
    if error is CancellationError { return nil }
    if let e = error as? APIError {
        switch e.status {
        case 0:
            switch e.code {
            case "bad_url": return "Địa chỉ máy chủ phải có dạng https://…"
            case "keychain": return "Không lưu được mã ghép vào Keychain của iPhone, thử lại."
            default: return "Máy chủ trả lời không hợp lệ."
            }
        case 400: return e.code == "bad_key" ? "Phím không hợp lệ." : "Dữ liệu gửi đi không hợp lệ."
        case 401:
            return pairing ? "Mã sai hoặc đã hết hạn. Gõ lại fcode-pair trên box để lấy mã mới."
                           : unpairedNotice
        case 403: return "Máy chủ từ chối yêu cầu."
        case 404: return "Không tìm thấy (phiên có thể đã đóng)."
        case 409: return "Phiên này đã tồn tại."
        case 413: return "Nội dung quá dài."
        case 429:
            return pairing ? "Thử quá nhiều lần, đợi \(e.retryAfter ?? 60) giây."
                           : "Thử lại sau \(e.retryAfter ?? 60) giây."
        case 503: return "Box đang bận, thử lại sau."
        case 500 where e.code == "storage": return "Máy chủ không lưu được, thử lại."
        case 500...: return "Máy chủ gặp lỗi (mã \(e.status))."
        default: return "Lỗi không rõ (mã \(e.status))."
        }
    }
    if let u = error as? URLError {
        if pairing { return u.code == .cancelled ? nil : "Không kết nối được máy chủ." }
        switch u.code {
        case .cancelled: return nil
        case .notConnectedToInternet, .networkConnectionLost: return "Mất kết nối mạng."
        case .timedOut: return "Máy chủ không phản hồi (hết thời gian chờ)."
        case .cannotFindHost, .dnsLookupFailed: return "Không tìm thấy máy chủ. Kiểm tra lại địa chỉ."
        case .appTransportSecurityRequiresSecureConnection: return "Chỉ hỗ trợ địa chỉ https://"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "Kết nối an toàn tới máy chủ bị lỗi."
        default: return "Không kết nối được máy chủ."
        }
    }
    if error is DecodingError { return "Máy chủ trả lời không hợp lệ." }
    return "Đã xảy ra lỗi."
}
