import Foundation

/// HTTP error from the server ({error:"code"}), or a client-side problem (status 0).
struct APIError: Error {
    var status: Int
    var code: String
    var retryAfter: Int? = nil
}

struct LoginResponse: Decodable { let ok: Bool?; let token: String? }
struct Meta: Decodable { let projects: [String]; let harnesses: [String]? }
struct SessionsResponse: Decodable { let sessions: [SessionInfo] }
struct OpenResponse: Decodable { let name: String; let created: Bool? }
struct Screen: Decodable { let text: String; let rows: Int?; let cols: Int?; let hash: String? }

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
        try API.check(resp, data)
        return data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call("GET", path))
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError(status: 0, code: "bad_response") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let header = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw APIError(status: http.statusCode,
                           code: obj?["error"] as? String ?? "",
                           retryAfter: (obj?["retryAfter"] as? Int) ?? header)
        }
    }
}

/// Plain-Vietnamese text for any error the app can hit. Returns nil for cancellations.
func vietnameseMessage(_ error: Error, login: Bool = false) -> String? {
    if error is CancellationError { return nil }
    if let e = error as? APIError {
        switch e.status {
        case 0:
            return e.code == "bad_url" ? "Địa chỉ máy chủ phải có dạng https://…" : "Máy chủ trả lời không hợp lệ."
        case 400: return e.code == "bad_key" ? "Phím không hợp lệ." : "Dữ liệu gửi đi không hợp lệ."
        case 401: return login ? "Sai mật khẩu." : "Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại."
        case 403: return "Máy chủ từ chối yêu cầu."
        case 404: return "Không tìm thấy (phiên có thể đã đóng)."
        case 409: return "Phiên này đã tồn tại."
        case 413: return "Nội dung quá dài."
        case 429: return "Thử lại sau \(e.retryAfter ?? 60) giây."
        case 503: return e.code == "not_configured" ? "Máy chủ chưa đặt mật khẩu." : "Máy chủ đang bận, thử lại sau."
        case 500...: return "Máy chủ gặp lỗi (mã \(e.status))."
        default: return "Lỗi không rõ (mã \(e.status))."
        }
    }
    if let u = error as? URLError {
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
