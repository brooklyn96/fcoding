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
        Group {
            if app.token == nil {
                NavigationStack { PairView() }
            } else {
                // A new pairing (new token) starts the home screen afresh; a link while paired
                // opens PairView as a sheet, so Huỷ returns to where the user was.
                ProjectsView()
                    .id(app.token)
                    .sheet(isPresented: Binding(get: { app.pairLink != nil },
                                                set: { if !$0 { app.pairLink = nil } })) {
                        NavigationStack { PairView() }.environmentObject(app)
                    }
            }
        }
        .alert("Ghép máy", isPresented: Binding(get: { app.popup != nil },
                                               set: { if !$0 { app.popup = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.popup ?? "")
        }
    }
}
