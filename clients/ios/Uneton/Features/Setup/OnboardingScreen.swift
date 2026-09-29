import AuthenticationServices
import ComposableArchitecture2
import SwiftUI

struct OnboardingScreen: View {
    @Bindable var store: StoreOf<Onboarding>
    let prepareAppleAuthorization: (ASAuthorizationAppleIDRequest) -> Void

    var body: some View {
        OnboardingContent(store: store, prepareAppleAuthorization: prepareAppleAuthorization)
    }
}

#if DEBUG
#Preview("Onboarding") { ScreenFixtures.preview(.onboarding) }
#endif
