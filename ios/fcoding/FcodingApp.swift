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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let old = app.unsupportedServer {
                UnsupportedServerView(address: old)
            } else if app.token == nil {
                NavigationStack { PairView() }
            } else {
                // A new pairing (new token) starts the home screen afresh.
                ProjectsView().id(app.token)
            }
        }
        // Every change of what the overlay shows goes through its one sync().
        .onChange(of: app.pairLink) { _ in Overlay.shared.sync(app) }
        .onChange(of: app.popup) { _ in Overlay.shared.sync(app) }
        .onChange(of: app.token) { _ in Overlay.shared.sync(app) }
        .onChange(of: app.cardState) { _ in Overlay.shared.sync(app) }
        .onChange(of: app.unsupportedServer) { _ in Overlay.shared.sync(app) }
        .onChange(of: scenePhase) { _ in Overlay.shared.sync(app) }
    }
}

/// The ONE presenter for pairing links and popups: its own window above the app's window, so
/// whatever the app has open (Cài đặt, "+", a dialog, a share sheet) can never hide or drop
/// them. The window exists only while it has something to show, and it lets every touch
/// through except on what it shows, so a missed exit path can never freeze the app.
@MainActor
final class Overlay: ObservableObject {
    static let shared = Overlay()
    /// The pair sheet is on screen or still animating out (set by its content, cleared in onDismiss).
    @Published var sheetUp = false
    private var window: UIWindow?

    /// While paired, a link opens the pair sheet here (unpaired, the root PairView takes it).
    /// From the unsupported-server card, "Ghép lại" opens it too (CardFlow state .pairing).
    static func wantsSheet(_ app: AppState) -> Bool {
        app.token != nil && (app.pairLink != nil || (app.unsupportedServer != nil && app.cardState == .pairing))
    }

    private func needed(_ app: AppState) -> Bool { Overlay.wantsSheet(app) || app.popup != nil || sheetUp }

    /// The single place that creates and removes the window; called on every state change.
    func sync(_ app: AppState) {
        if needed(app) {
            guard window == nil,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }
            let w = PassThroughWindow(windowScene: scene)
            w.windowLevel = .alert
            w.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: OverlayPresenter().environmentObject(app))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            w.makeKeyAndVisible()
            window = w
        } else if window != nil {
            // Let a closing alert finish its fade; touches already pass through meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let w = self.window, !self.needed(app) else { return }
                w.isHidden = true
                self.window = nil
                w.windowScene?.windows.first { $0 !== w && $0.windowLevel == .normal }?.makeKey()
            }
        }
    }
}

/// Hit-tests only what the overlay shows (sheet, alert); its own empty root lets touches through.
private final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view ? nil : hit
    }
}

/// Root of the overlay window: the pair sheet, and the popup alert from wherever is on top
/// (inside the sheet while it is up, here otherwise, only after the sheet has fully closed).
private struct OverlayPresenter: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var overlay = Overlay.shared
    /// Presentations start once this view is in its window, not on a fresh host's first render.
    @State private var armed = false

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .sheet(isPresented: Binding(get: { armed && Overlay.wantsSheet(app) },
                                        set: { if !$0 { app.cancelPairing() } }),
                   onDismiss: { overlay.sheetUp = false; overlay.sync(app) }) {
                NavigationStack { PairView() }
                    .environmentObject(app)
                    .preferredColorScheme(.dark)
                    .onAppear { overlay.sheetUp = true }
                    .popupAlert(app, when: Overlay.wantsSheet(app))
            }
            .popupAlert(app, when: armed && !Overlay.wantsSheet(app) && !overlay.sheetUp)
            .onAppear { armed = true }
    }
}

private extension View {
    /// The "Ghép máy" alert for `app.popup`, shown only where `when` says it is on top.
    /// Closing it clears `popup`, and RootView's onChange then syncs the overlay.
    func popupAlert(_ app: AppState, when: Bool) -> some View {
        alert("Ghép máy", isPresented: Binding(get: { when && app.popup != nil },
                                              set: { if !$0 { app.popup = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.popup ?? "")
        }
    }
}

