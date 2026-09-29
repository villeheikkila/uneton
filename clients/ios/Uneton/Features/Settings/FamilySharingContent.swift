import ComposableArchitecture2
import SwiftUI

struct FamilySharingContent: View {
    @Bindable var store: StoreOf<FamilySharing>

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "gearshape")
                    .font(.system(size: 48))
                    .foregroundStyle(.indigo)
                Text("Device and account")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 14) {
                    Text("This device").font(.headline)
                    Toggle("Push notifications", isOn: $store.notificationsEnabled)
                    Toggle("Live Activities", isOn: $store.liveActivitiesEnabled)
                    Picker("Sleep reminder", selection: $store.reminderLeadMinutes) {
                        Text("At predicted time").tag(0)
                        Text("15 minutes before").tag(15)
                        Text("30 minutes before").tag(30)
                        Text("1 hour before").tag(60)
                    }
                }

                Divider()

                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    store.send(.signOutButtonTapped)
                }
                .buttonStyle(.bordered)
                .disabled(store.accountRequest.isRunning)

                Button("Delete account", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                    store.send(.deleteAccountPromptButtonTapped)
                }
                .disabled(store.accountRequest.isRunning)

                HStack(spacing: 20) {
                    Link("Privacy Policy", destination: LegalLinks.privacy)
                    Link("Terms of Service", destination: LegalLinks.terms)
                }
                .font(.footnote)

                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
    }
}
