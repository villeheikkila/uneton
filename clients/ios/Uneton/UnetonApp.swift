import ComposableArchitecture2
import Dependencies
import UnetonCore
import SwiftUI

@main
struct UnetonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @State private var store: StoreOf<AppRoot>

    init() {
        prepareDependencies {
            try! $0.bootstrapDatabase()
            #if DEBUG
            let debugBaseURL = ProcessInfo.processInfo.environment["UNETON_API_BASE_URL"]
                .flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8080")!
            $0.apiClient = .live(baseURL: debugBaseURL)
            #else
            $0.apiClient = .live(baseURL: URL(string: "https://api.uneton.app")!)
            #endif
        }
        let session = SessionStore()
        _session = State(initialValue: session)
        _store = State(initialValue: Store(initialState: AppRoot.State(
            isAuthenticated: session.isAuthenticated
        )) {
            AppRoot()
                .environment(\.sessionSync, .live(session: session))
                .environment(\.sessionAuth, .live(session: session))
                .environment(\.sessionFamily, .live(session: session))
                .environment(\.sessionDiary, .live(session: session))
                .environment(\.sessionSharing, .live(session: session))
        })
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environment(session)
        }
    }
}
