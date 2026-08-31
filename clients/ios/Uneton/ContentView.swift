import Dependencies
import UnetonCore
import SQLiteData
import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var session
    @FetchAll(Family.order { $0.updatedAt.desc() }) private var families
    @FetchAll(Child.order { $0.updatedAt.desc() }) private var children

    var body: some View {
        Group {
            if session.accessToken != nil,
               let family = families.first,
               let child = children.first(where: { $0.familyID == family.id }) {
                TimelineScreen(family: family, child: child)
            } else {
                OnboardingView()
            }
        }
        .onOpenURL { url in
            Task { await session.handle(url: url) }
        }
        .task { await session.validateAppleCredential() }
    }
}

#Preview {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase()
    }
    ContentView()
        .environment(SessionStore())
}
