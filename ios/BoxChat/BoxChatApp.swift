import SwiftUI

@main
struct BoxChatApp: App {
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
            NavigationStack { LoginView() }
        } else {
            ProjectsView()
        }
    }
}
