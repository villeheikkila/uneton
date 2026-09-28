import AuthenticationServices
import ComposableArchitecture2
import SwiftUI

struct OnboardingView: View {
    @Bindable var store: StoreOf<Onboarding>
    let prepareAppleAuthorization: (ASAuthorizationAppleIDRequest) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.16), Color.cyan.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.indigo)
                    .symbolEffect(.breathe)
                VStack(spacing: 8) {
                    Text("Uneton")
                        .font(.largeTitle.bold())
                    Text("Track your baby’s sleep, growth and temperature together.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                SignInWithAppleButton(.continue) { request in
                    prepareAppleAuthorization(request)
                } onCompletion: { result in
                    store.send(.appleAuthorizationCompleted(result))
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .disabled(store.signIn.isRunning)

                HStack(spacing: 20) {
                    Link("Privacy Policy", destination: LegalLinks.privacy)
                    Link("Terms of Service", destination: LegalLinks.terms)
                }
                .font(.footnote)

                #if DEBUG
                TextField("Local caregiver", text: $store.caregiverName)
                    .textFieldStyle(.roundedBorder)
                Button("Use local server") {
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

#if DEBUG
#Preview("Onboarding") { ScreenFixtures.preview(.onboarding) }
#endif
