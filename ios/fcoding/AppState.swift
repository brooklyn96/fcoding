import Foundation
import UIKit

/// Server address + device token from pairing. token == nil means "show the pairing screen".
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var serverURL: String
    @Published private(set) var token: String?
    @Published var notice: String?

    private static let serverKey = "serverURL"
    private static let tokenAccount = "deviceToken"

    init() {
        AppState.removeLegacyCredentials()
        serverURL = UserDefaults.standard.string(forKey: AppState.serverKey) ?? ""
        token = serverURL.isEmpty ? nil : Keychain.get(AppState.tokenAccount)
    }

    /// Password-login leftovers: the old token (Keychain account "token" or UserDefaults) and
    /// the cookie-mode flags. Idempotent, so it runs on every launch; the user re-pairs once.
    private static func removeLegacyCredentials() {
        let defaults = UserDefaults.standard
        for key in ["token", "password", "cookieMode", "cookieModeNoticeShown"] { defaults.removeObject(forKey: key) }
        Keychain.delete("token")
    }

    var api: API? {
        guard let token = token, !token.isEmpty, let url = URL(string: serverURL) else { return nil }
        return API(base: url, token: token)
    }

    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// POST /api/pair {code, name}; the token from the body goes to the Keychain.
    func pair(server: String, code: String) async throws {
        guard let base = AppState.normalize(server) else { throw APIError(status: 0, code: "bad_url") }
        let data = try await API(base: base, token: "")
            .call("POST", "api/pair", body: ["code": code, "name": UIDevice.current.name])
        let reply = try JSONDecoder().decode(PairResponse.self, from: data)
        guard let newToken = reply.token, !newToken.isEmpty else { throw APIError(status: 0, code: "bad_response") }
        guard Keychain.set(newToken, for: AppState.tokenAccount) else { throw APIError(status: 0, code: "keychain") }
        serverURL = base.absoluteString
        UserDefaults.standard.set(serverURL, forKey: AppState.serverKey)
        notice = nil
        token = newToken
    }

    /// "Gỡ iPhone này": POST /api/logout. The token is deleted here even if the request fails.
    /// Returns the task so a caller can await it (and show a spinner) or fire and forget.
    @discardableResult
    func logoutHere() -> Task<Void, Never> {
        Task { await unpair(query: []) }
    }

    /// "Gỡ mọi thiết bị": POST /api/logout?all=1. The token is deleted here even if the request fails.
    func logoutEverywhere() async {
        await unpair(query: [URLQueryItem(name: "all", value: "1")])
    }

    private func unpair(query: [URLQueryItem]) async {
        var failure: String?
        if let api = api {
            do {
                try await api.call("POST", "api/logout", query: query)
            } catch let e as APIError where e.status == 401 {
                // Already removed on the box: nothing left to undo there.
            } catch {
                failure = "Đã xoá ghép trên iPhone này, nhưng box chưa nhận lệnh gỡ (\(vietnameseMessage(error) ?? "lỗi"))."
            }
        }
        signOutLocally(notice: failure)
        AppState.removeDrafts()
    }

    /// Composer drafts ("draft.<session>") go only on an explicit unpair; a 401 keeps them.
    static func removeDrafts() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("draft.") {
            defaults.removeObject(forKey: key)
        }
    }

    func signOutLocally(notice: String?) {
        Keychain.delete(AppState.tokenAccount)
        if let url = URL(string: serverURL) {
            HTTPCookieStorage.shared.cookies(for: url)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        self.notice = notice
        token = nil
    }

    /// Message for the user; a 401 means this device was revoked: back to the pairing screen.
    func report(_ error: Error) -> String? {
        if let e = error as? APIError, e.status == 401 {
            if token != nil { signOutLocally(notice: unpairedNotice) }
            return unpairedNotice
        }
        return vietnameseMessage(error)
    }
}
