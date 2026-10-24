import Foundation

/// Server address + login token. token == nil means "show the login screen";
/// an empty token means the server gave no token and the session cookie is used.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var serverURL: String
    @Published private(set) var token: String?
    @Published var notice: String?

    private static let serverKey = "serverURL"
    private static let tokenKey = "token"
    /// Set when the Keychain refused the token (e.g. LiveContainer entitlements): the app then
    /// relies on the persistent pc_sid cookie in HTTPCookieStorage (token "").
    private static let cookieModeKey = "cookieMode"
    private static let cookieNoticeShownKey = "cookieModeNoticeShown"

    init() {
        serverURL = UserDefaults.standard.string(forKey: AppState.serverKey) ?? ""
        if serverURL.isEmpty {
            token = nil
        } else {
            token = Keychain.get(AppState.tokenKey)
                ?? (UserDefaults.standard.bool(forKey: AppState.cookieModeKey) ? "" : nil)
        }
    }

    var api: API? {
        guard let token = token, let url = URL(string: serverURL) else { return nil }
        return API(base: url, token: token)
    }

    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    func login(server: String, password: String) async throws {
        guard let base = AppState.normalize(server) else { throw APIError(status: 0, code: "bad_url") }
        let data = try await API(base: base, token: "").call("POST", "api/login", body: ["password": password])
        let reply = try JSONDecoder().decode(LoginResponse.self, from: data)
        let newToken = reply.token ?? ""
        serverURL = base.absoluteString
        UserDefaults.standard.set(serverURL, forKey: AppState.serverKey)
        let defaults = UserDefaults.standard
        if Keychain.set(newToken, for: AppState.tokenKey) {
            defaults.removeObject(forKey: AppState.cookieModeKey)
            notice = nil
            token = newToken
        } else {
            // Cookie mode: survives a cold start through the persistent session cookie.
            defaults.set(true, forKey: AppState.cookieModeKey)
            if defaults.bool(forKey: AppState.cookieNoticeShownKey) {
                notice = nil
            } else {
                defaults.set(true, forKey: AppState.cookieNoticeShownKey)
                notice = "Không lưu được mật khẩu đăng nhập an toàn; app sẽ dùng cookie."
            }
            token = ""
        }
    }

    /// "Đăng xuất trên máy này": forget the credentials on this phone only.
    func logoutHere() {
        signOutLocally(notice: nil)
        AppState.removeDrafts()
    }

    /// "Đăng xuất mọi nơi": the server revokes every device first; local credentials are
    /// cleared only after a 2xx. Any failure is thrown so the caller can show it and retry.
    func logoutEverywhere() async throws {
        guard let api = api else { signOutLocally(notice: nil); return AppState.removeDrafts() }
        try await api.call("POST", "api/logout", query: [URLQueryItem(name: "all", value: "1")])
        signOutLocally(notice: nil)
        AppState.removeDrafts()
    }

    /// Composer drafts ("draft.<session>") go only on an explicit logout; a 401 keeps them.
    static func removeDrafts() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("draft.") {
            defaults.removeObject(forKey: key)
        }
    }

    func signOutLocally(notice: String?) {
        Keychain.delete(AppState.tokenKey)
        UserDefaults.standard.removeObject(forKey: AppState.cookieModeKey)
        if let url = URL(string: serverURL) {
            HTTPCookieStorage.shared.cookies(for: url)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        self.notice = notice
        token = nil
    }

    /// Message for the user; a 401 also sends the app back to the login screen.
    func report(_ error: Error) -> String? {
        let message = vietnameseMessage(error)
        if let e = error as? APIError, e.status == 401, token != nil { signOutLocally(notice: message) }
        return message
    }
}
