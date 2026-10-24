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

    init() {
        serverURL = UserDefaults.standard.string(forKey: AppState.serverKey) ?? ""
        token = serverURL.isEmpty ? nil : Keychain.get(AppState.tokenKey)
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
        Keychain.set(newToken, for: AppState.tokenKey) // if this fails the token lives in memory only
        notice = nil
        token = newToken
    }

    func logout(everywhere: Bool) async {
        if let api = api {
            let query = everywhere ? [URLQueryItem(name: "all", value: "1")] : []
            _ = try? await api.call("POST", "api/logout", query: query)
        }
        signOutLocally(notice: nil)
    }

    func signOutLocally(notice: String?) {
        Keychain.delete(AppState.tokenKey)
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
