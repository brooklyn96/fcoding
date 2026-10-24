import SwiftUI

@main
struct FcodingApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        if app.token == nil {
            NavigationStack { PairView() }
        } else {
            ProjectsView()
        }
    }
}
