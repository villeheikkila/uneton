import AuthenticationServices
import ComposableArchitecture2
import SwiftUI
import UnetonTheme

struct OnboardingContent: View {
    @Environment(\.palette) private var palette
    @Bindable var store: StoreOf<Onboarding>
    let prepareAppleAuthorization: (ASAuthorizationAppleIDRequest) -> Void

    var body: some View {
        ZStack {
            SkyBackground()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(palette.accent.color)
                    .symbolEffect(.breathe)
                VStack(spacing: 8) {
                    Text("locUneton", comment: "Text in Setup: Uneton")
                        .font(.soft(52))
                        .foregroundStyle(palette.ink.color)
                    Text("locTrackYourBabySSleepGrowthAndTemperatureTogether", comment: "Text in Setup: Track your baby’s sleep, growth and temperature together.")
                        .font(.soft(19, weight: .bold))
                        .foregroundStyle(palette.inkSecondary.color)
                        .multilineTextAlignment(.center)
                }
                if !AppMode.isDemo {
                    SignInWithAppleButton(.continue) { request in
                        prepareAppleAuthorization(request)
                    } onCompletion: { result in
                        store.send(.appleAuthorizationCompleted(result))
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 52)
                    .disabled(store.signIn.isRunning)
                }

                HStack(spacing: 20) {
                    Link(LocalizedStringResource("locPrivacyPolicy", defaultValue: "Privacy Policy", comment: "Link title in Setup: Privacy Policy"), destination: LegalLinks.privacy)
                    Link(LocalizedStringResource("locTermsOfService", defaultValue: "Terms of Service", comment: "Link title in Setup: Terms of Service"), destination: LegalLinks.terms)
                }
                .font(.footnote)

                #if DEBUG
                if !AppMode.isDemo {
                    TextField(LocalizedStringResource("locLocalCaregiver", defaultValue: "Local caregiver", comment: "Text field placeholder in Setup: Local caregiver"), text: $store.caregiverName)
                        .textFieldStyle(.roundedBorder)
                }
                Button(AppMode.isDemo ? LocalizedStringResource("locExploreDemo", defaultValue: "Explore demo", comment: "Button title in Setup: Explore demo") : LocalizedStringResource("locUseLocalServer", defaultValue: "Use local server", comment: "Button title in Setup: Use local server")) {
                    store.send(.developmentSignInButtonTapped)
                }
                .buttonStyle(.glass)
                .disabled(store.caregiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.signIn.isRunning)
                #endif

                if store.signIn.isRunning { ProgressView() }
                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
    }
}
