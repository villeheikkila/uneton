import AuthenticationServices
import SwiftUI

struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @State private var caregiverName = "Caregiver"

    var body: some View {
        @Bindable var session = session
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
                    Text("A calmer way to keep track of sleep together.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                SignInWithAppleButton(.continue) { request in
                    session.prepareAppleAuthorization(request)
                } onCompletion: { result in
                    Task {
                        await session.completeAppleAuthorization(result)
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .disabled(session.isWorking)

                #if DEBUG
                TextField("Local caregiver", text: $caregiverName)
                    .textFieldStyle(.roundedBorder)
                Button("Use local server") {
                    Task {
                        await session.developmentAuthenticate(name: caregiverName)
                    }
                }
                .buttonStyle(.glass)
                .disabled(caregiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isWorking)
                #endif

                if session.isWorking { ProgressView() }
                if let error = session.errorMessage {
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
