import SwiftUI

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
        // A pairing link shows the pairing screen even while paired; PairView asks first.
        if app.token == nil || app.pairLink != nil {
            NavigationStack { PairView() }
        } else {
            ProjectsView()
        }
    }
}
