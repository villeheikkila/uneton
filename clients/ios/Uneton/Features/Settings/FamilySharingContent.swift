import ComposableArchitecture2
import SwiftUI

struct FamilySharingContent: View {
    @Bindable var store: StoreOf<FamilySharing>

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "gearshape")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.sleepBlue)
                Text("locDeviceAndAccount", comment: "Text in Settings: Device and account")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 14) {
                    Text("locThisDevice", comment: "Text in Settings: This device").font(.headline)
                    Toggle(LocalizedStringResource("locPushNotifications", defaultValue: "Push notifications", comment: "Text in Settings: Push notifications"), isOn: $store.notificationsEnabled)
                    Toggle(LocalizedStringResource("locLiveActivities", defaultValue: "Live Activities", comment: "Text in Settings: Live Activities"), isOn: $store.liveActivitiesEnabled)
                    Picker(LocalizedStringResource("locSleepReminder", defaultValue: "Sleep reminder", comment: "Picker title in Settings: Sleep reminder"), selection: $store.reminderLeadMinutes) {
                        Text("locAtPredictedTime", comment: "Text in Settings: At predicted time").tag(0)
                        Text(.loc15MinutesBefore).tag(15)
                        Text(.loc30MinutesBefore).tag(30)
                        Text(.loc1HourBefore).tag(60)
                    }
                }

                Divider()

                Button(LocalizedStringResource("locSignOut", defaultValue: "Sign out", comment: "Button title in Settings: Sign out"), systemImage: "rectangle.portrait.and.arrow.right") {
                    store.send(.signOutButtonTapped)
                }
                .buttonStyle(.bordered)
                .disabled(store.accountRequest.isRunning)

                Button(LocalizedStringResource("locDeleteAccount", defaultValue: "Delete account", comment: "Button title in Settings: Delete account"), systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                    store.send(.deleteAccountPromptButtonTapped)
                }
                .disabled(store.accountRequest.isRunning)

                HStack(spacing: 20) {
                    Link(LocalizedStringResource("locPrivacyPolicy", defaultValue: "Privacy Policy", comment: "Link title in Settings: Privacy Policy"), destination: LegalLinks.privacy)
                    Link(LocalizedStringResource("locTermsOfService", defaultValue: "Terms of Service", comment: "Link title in Settings: Terms of Service"), destination: LegalLinks.terms)
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
        .background(Color.sleepCanvas.ignoresSafeArea())
    }
}
