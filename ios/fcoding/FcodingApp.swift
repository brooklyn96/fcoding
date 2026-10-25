import SwiftUI
import UIKit

@main
struct FcodingApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onOpenURL { app.open($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if app.token == nil {
                NavigationStack { PairView() }
            } else {
                // A new pairing (new token) starts the home screen afresh.
                ProjectsView().id(app.token)
            }
        }
        .onChange(of: app.pairLink) { _ in Overlay.shared.sync(app) }
        .onChange(of: app.popup) { _ in Overlay.shared.sync(app) }
        .onChange(of: app.token) { _ in Overlay.shared.sync(app) }
    }
}

/// The ONE presenter for pairing links and popups: its own window above the app's window, so
/// whatever the app has open (Cài đặt, "+", a dialog, a share sheet) can never hide or drop
/// them. The window exists only while it has something to show.
@MainActor
final class Overlay {
    static let shared = Overlay()
    private var window: UIWindow?

    /// While paired, a link opens the pair sheet here (unpaired, the root PairView takes it).
    static func wantsSheet(_ app: AppState) -> Bool { app.token != nil && app.pairLink != nil }

    func sync(_ app: AppState) {
        guard window == nil, Overlay.wantsSheet(app) || app.popup != nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert
        w.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: OverlayPresenter { [weak self] in self?.close(app) }
            .environmentObject(app))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
    }

    /// Called by the presenter once nothing is shown or animating; reopens at once if
    /// something new arrived in between.
    private func close(_ app: AppState) {
        guard let w = window else { return }
        w.isHidden = true
        window = nil
        w.windowScene?.windows.first { $0 !== w && $0.windowLevel == .normal }?.makeKey()
        sync(app)
    }
}

/// Root of the overlay window: the pair sheet, and the popup alert from wherever is on top
/// (inside the sheet while it is up, here otherwise, only after the sheet has fully closed).
private struct OverlayPresenter: View {
    @EnvironmentObject private var app: AppState
    /// The pair sheet is on screen or still animating out (cleared in onDismiss).
    @State private var sheetUp = false
    let done: () -> Void

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .sheet(isPresented: Binding(get: { Overlay.wantsSheet(app) },
                                        set: { if !$0 { app.pairLink = nil } }),
                   onDismiss: { sheetUp = false; finish() }) {
                NavigationStack { PairView() }
                    .environmentObject(app)
                    .preferredColorScheme(.dark)
                    .onAppear { sheetUp = true }
                    .popupAlert(app, when: Overlay.wantsSheet(app))
            }
            .popupAlert(app, when: !Overlay.wantsSheet(app) && !sheetUp, onClose: finish)
            .onAppear { finish() }
    }

    private func finish() {
        if !Overlay.wantsSheet(app) && !sheetUp && app.popup == nil { done() }
    }
}

private extension View {
    /// The "Ghép máy" alert for `app.popup`, shown only where `when` says it is on top.
    func popupAlert(_ app: AppState, when: Bool, onClose: @escaping () -> Void = {}) -> some View {
        alert("Ghép máy", isPresented: Binding(get: { when && app.popup != nil },
                                              set: { if !$0 { app.popup = nil; onClose() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.popup ?? "")
        }
    }
}
