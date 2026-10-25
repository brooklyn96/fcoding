import Foundation
import UIKit

/// Server address + device token from pairing. token == nil means "show the pairing screen".
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var serverURL: String
    @Published private(set) var token: String?
    @Published var notice: String?
    /// A `fcode://pair` link waiting for the user's tap on "Ghép" (QR from another device).
    @Published var pairLink: PairLink?

    private static let serverKey = "serverURL"
    private static let tokenAccount = "deviceToken"

    init() {
        serverURL = UserDefaults.standard.string(forKey: AppState.serverKey) ?? ""
        AppState.removeLegacyCredentials(server: serverURL)
        token = serverURL.isEmpty ? nil : Keychain.get(AppState.tokenAccount)
    }

    /// Password-login leftovers: the old token (Keychain account "token" or UserDefaults), the
    /// cookie-mode flags and any pc_sid cookie for the stored server (requests no longer use
    /// the cookie jar). Idempotent, so it runs on every launch; the user re-pairs once.
    private static func removeLegacyCredentials(server: String) {
        let defaults = UserDefaults.standard
        for key in ["token", "password", "cookieMode", "cookieModeNoticeShown"] { defaults.removeObject(forKey: key) }
        Keychain.delete("token")
        if let url = URL(string: server) {
            HTTPCookieStorage.shared.cookies(for: url)?
                .filter { $0.name == "pc_sid" }
                .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }

    var api: API? {
        guard let token = token, !token.isEmpty, let url = URL(string: serverURL) else { return nil }
        return API(base: url, token: token)
    }

    nonisolated static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// `fcode://pair?server=<https origin>&code=<6 digits>&name=<optional>` (QR / share link).
    /// Only fills the pairing screen: pairing itself always waits for the user's tap.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "fcode", url.host?.lowercased() == "pair" else { return }
        if let link = PairLink(url) {
            pairLink = link
        } else if token == nil {
            notice = "Link ghép không hợp lệ. Quét lại mã QR mới."
        }
    }

    /// POST /api/pair {code, name}; the token from the body goes to the Keychain.
    /// A token this phone held before (re-pair from a link) is logged out on its box afterwards.
    func pair(server: String, code: String, name: String? = nil) async throws {
        guard let base = AppState.normalize(server) else { throw APIError(status: 0, code: "bad_url") }
        let previous = api
        let data = try await API(base: base, token: "")
            .call("POST", "api/pair", body: ["code": code, "name": name ?? UIDevice.current.name])
        let reply = try JSONDecoder().decode(PairResponse.self, from: data)
        guard let newToken = reply.token, !newToken.isEmpty else { throw APIError(status: 0, code: "bad_response") }
        guard Keychain.set(newToken, for: AppState.tokenAccount) else { throw APIError(status: 0, code: "keychain") }
        serverURL = base.absoluteString
        UserDefaults.standard.set(serverURL, forKey: AppState.serverKey)
        notice = nil
        pairLink = nil
        token = newToken
        if let previous = previous, previous.token != newToken {
            Task { try? await previous.call("POST", "api/logout") }
        }
    }

    /// "Gỡ iPhone này": POST /api/logout. The token is deleted here even if the request fails
    /// (unless a new pairing replaced it meanwhile).
    /// Returns the task so a caller can await it (and show a spinner) or fire and forget.
    @discardableResult
    func logoutHere() -> Task<Void, Never> {
        Task { await unpair(query: []) }
    }

    /// "Gỡ mọi thiết bị": POST /api/logout?all=1 (A3 semantics, Architect decision). The phone
    /// signs out only after a confirmed 2xx, or on a 401 (already gone). Any other failure keeps
    /// the token and returns the message for the inline error with "Thử lại"; nil means done.
    func logoutEverywhere() async -> String? {
        guard let api = api else { clearIfCurrent(nil, notice: nil); return nil }
        do {
            try await api.call("POST", "api/logout", query: [URLQueryItem(name: "all", value: "1")])
        } catch let e as APIError where e.status == 401 {
            // Already removed on the box: sign out below.
        } catch {
            let reason = (vietnameseMessage(error) ?? "lỗi").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "Box chưa gỡ được các thiết bị (\(reason)). Thử lại."
        }
        clearIfCurrent(api.token, notice: nil)
        return nil
    }

    /// "Gỡ iPhone này": always signs out here, with a notice when the box did not confirm.
    private func unpair(query: [URLQueryItem]) async {
        guard let api = api else { clearIfCurrent(nil, notice: nil); return }
        var failure: String?
        do {
            try await api.call("POST", "api/logout", query: query)
        } catch let e as APIError where e.status == 401 {
            // Already removed on the box: nothing left to undo there.
        } catch {
            // Fixed text: this phone has no token left, so there is nothing to retry here.
            failure = "Đã xoá ghép trên iPhone này, nhưng box chưa nhận lệnh gỡ (không kết nối được hoặc box báo lỗi)."
        }
        clearIfCurrent(api.token, notice: failure)
    }

    /// Clears credentials and drafts only if the token that started the request is still the
    /// current one: a logout finishing after a new pairing must not wipe that pairing.
    private func clearIfCurrent(_ started: String?, notice: String?) {
        guard started == nil || token == started else { return }
        signOutLocally(notice: notice)
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
        self.notice = notice
        token = nil
    }

    /// Message for the user; a 401 means this device was revoked: back to the pairing screen.
    /// A late 401 for a request sent with an older token (before a re-pair) is ignored.
    func report(_ error: Error) -> String? {
        if let e = error as? APIError, e.status == 401 {
            if let sent = e.token, sent != token { return nil }
            if token != nil { signOutLocally(notice: unpairedNotice) }
            return unpairedNotice
        }
        return vietnameseMessage(error)
    }
}

/// A validated pairing link: an https server origin and exactly six ASCII digits.
struct PairLink: Equatable {
    let server: String
    let code: String
    let name: String?

    init?(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let raw = value("server"), raw.lowercased().hasPrefix("https://"),
              let base = AppState.normalize(raw), base.user == nil, base.password == nil,
              let code = value("code"), code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        server = base.absoluteString
        self.code = code
        let label = String((value("name") ?? "").prefix(64))
        name = label.isEmpty ? nil : label
    }
}
