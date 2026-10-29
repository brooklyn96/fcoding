import Foundation
import UIKit

/// Server address + device token from pairing. token == nil means "show the pairing screen".
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var serverURL: String
    @Published private(set) var token: String?
    @Published var notice: String?
    /// A `fcode://pair` link (server only) waiting for the typed code and the tap on "Ghép".
    @Published var pairLink: PairLink?
    /// One-off message shown as an alert over whatever screen is up (link and re-pair results).
    @Published var popup: String?
    /// Paired by an older build to an address this build rejects (shown escaped). While set,
    /// the app shows only the "pair again" card and sends that server nothing (`api` is nil).
    @Published private(set) var unsupportedServer: String?
    /// Where the card is (CardFlow); meaningful only while `unsupportedServer` is set.
    @Published private(set) var cardState: CardFlow.State = .card

    private static let serverKey = "serverURL"
    private static let tokenAccount = "deviceToken"

    init() {
        // Stored as an origin only (older builds could keep a path or query). An address this
        // build rejects is never kept in serverURL: it is shown only escaped, on the card.
        let stored = UserDefaults.standard.string(forKey: AppState.serverKey) ?? ""
        serverURL = PairLink.origin(stored)?.absoluteString ?? ""
        AppState.removeLegacyCredentials(server: stored)
        token = stored.isEmpty ? nil : Keychain.get(AppState.tokenAccount)
        if token != nil && !PairLink.isSupportedStored(stored) {
            unsupportedServer = PairLink.escapedAuthority(stored)
        }
        prefetch()
    }

    /// The first home and prefs requests of an activation (see LaunchFetch).
    let launch = LaunchFetch()

    private func loginKey(_ api: API) -> String { ResponseCache.key(server: api.base.absoluteString, token: api.token) }

    /// Called at launch and each time the app becomes active: opens the connection and gets the
    /// home and prefs replies before the home screen asks for them. Nothing while unpaired.
    func prefetch() {
        guard let api = api else { return }
        begin(api, ["api/home", "api/prefs"])
    }

    private func begin(_ api: API, _ paths: [String]) {
        launch.start(key: loginKey(api), paths) { try await api.call("GET", $0) }
    }

    /// GET `path` and when the reply arrived. Unless `reuse` is false (a caller that needs a reply
    /// from a request started after its call) or there is a query (?fresh=1), it starts the
    /// request itself when prefetch() has not (one per activation either way) and takes it, but
    /// only when it began at or after `since`. A prefetch that failed is not an error here: the
    /// caller's own request goes out.
    func get(_ api: API, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 20,
             reuse: Bool = true, since: Date = .distantPast) async throws -> (data: Data, at: Date) {
        if reuse && query.isEmpty {
            begin(api, [path])
            if let early = launch.take(path, key: loginKey(api), since: since), let reply = try? await early.value { return reply }
        }
        let data = try await api.call("GET", path, query: query, timeout: timeout)
        return (data, Date())
    }

    static func oldBoxLine(_ address: String) -> String {
        "Box cũ (\(address)) vẫn còn iPhone này trong danh sách thiết bị; gỡ nó trên box đó."
    }

    /// Every card event goes through CardFlow.step. Nothing local is deleted unless a pairing
    /// with a new server succeeds or "Đăng xuất" is confirmed; nothing is ever sent to the
    /// unsupported server.
    func card(_ event: CardFlow.Event) {
        guard unsupportedServer != nil else { return }
        let next = CardFlow.step(cardState, event)
        cardState = next.state
        if next.cleanup { leaveUnsupported(signingOut: event == .signOutConfirm) }
    }

    /// The ONE cleanup for leaving the card, reached only through `card(_:)`: drafts and read
    /// marks go; on sign-out also the stored server and the old login (a successful pairing
    /// has already replaced both). Then the old-box notice, once.
    private func leaveUnsupported(signingOut: Bool) {
        guard let old = unsupportedServer else { return }
        AppState.removeDrafts()
        AppState.removeSavedCopies()
        UserDefaults.standard.removeObject(forKey: "inbox.seen")
        if signingOut {
            UserDefaults.standard.removeObject(forKey: AppState.serverKey)
            serverURL = ""
            Keychain.delete(AppState.tokenAccount)
            token = nil
        }
        unsupportedServer = nil
        popup = AppState.oldBoxLine(old)
    }

    /// Closing the pairing screen without pairing (Huỷ, swipe down): back to where it was.
    func cancelPairing() {
        pairLink = nil
        card(.cancel)
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
        guard unsupportedServer == nil, let token = token, !token.isEmpty,
              let url = PairLink.origin(serverURL) else { return nil }
        return API(base: url, token: token)
    }

    /// The https origin (`https://host[:port]`) of what the user typed; nil if not https.
    nonisolated static func normalize(_ input: String) -> URL? { PairLink.origin(input) }

    /// `fcode://pair?server=<https origin>` (QR / share link). Only fills the server on the
    /// pairing screen; the user types the code and taps "Ghép".
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "fcode", url.host?.lowercased() == "pair" else { return }
        guard let link = PairLink(url) else {
            popup = "Link ghép không hợp lệ. Quét lại mã QR trên iPhone cũ."
            return
        }
        if token != nil && link.server == serverURL {
            popup = "iPhone này đã ghép với máy chủ \(PairLink.label(link.server)) rồi."
        } else {
            card(.link)   // from the card: only opens pairing, nothing is deleted
            pairLink = link
        }
    }

    /// POST /api/pair {code, name}; the token from the body goes to the Keychain. On a move to
    /// another box the old box's drafts and read marks go. A token held before is then logged
    /// out on ITS box (never sent to the new one); a failure is reported, naming that box.
    func pair(server: String, code: String) async throws {
        guard let base = AppState.normalize(server) else { throw APIError(status: 0, code: "bad_url") }
        let previous = api
        let data = try await API(base: base, token: "")
            .call("POST", "api/pair", body: ["code": code, "name": UIDevice.current.name])
        let reply = try JSONDecoder().decode(PairResponse.self, from: data)
        guard let newToken = reply.token, !newToken.isEmpty else { throw APIError(status: 0, code: "bad_response") }
        guard Keychain.set(newToken, for: AppState.tokenAccount) else { throw APIError(status: 0, code: "keychain") }
        if !serverURL.isEmpty && serverURL != base.absoluteString {
            AppState.removeDrafts()
            AppState.removeSavedCopies()
            UserDefaults.standard.removeObject(forKey: "inbox.seen")
        }
        serverURL = base.absoluteString
        UserDefaults.standard.set(serverURL, forKey: AppState.serverKey)
        notice = nil
        pairLink = nil
        token = newToken
        card(.pairSuccess)   // from the card: the one cleanup, then the old-box notice
        guard let previous = previous else { return }
        do {
            try await previous.call("POST", "api/logout")
        } catch let e as APIError where e.status == 401 {
            // Already gone on the old box.
        } catch {
            popup = "Chưa gỡ được iPhone này khỏi máy chủ cũ \(PairLink.label(previous.base.absoluteString)); vào máy chủ cũ để gỡ."
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

    /// The box's data saved on this phone: the home / overview replies (ResponseCache) and the
    /// project order + display names (PrefsModel's "projects.prefs"). Called in the same main
    /// actor turn as the token change, so the next ProjectsView (`.id(app.token)`) starts empty.
    static func removeSavedCopies() {
        ResponseCache.clear()
        UserDefaults.standard.removeObject(forKey: "projects.prefs")
    }

    func signOutLocally(notice: String?) {
        AppState.removeSavedCopies()
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
