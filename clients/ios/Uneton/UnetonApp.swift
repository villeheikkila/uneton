import Dependencies
import UnetonCore
import SwiftUI

@main
struct UnetonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: SessionStore

    init() {
        prepareDependencies {
            try! $0.bootstrapDatabase()
            #if DEBUG
            $0.apiClient = .live(baseURL: URL(string: "http://127.0.0.1:8080")!)
            #else
            $0.apiClient = .live(baseURL: URL(string: "https://api.uneton.app")!)
            #endif
        }
        _session = State(initialValue: SessionStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
    }
}
