import ComposableArchitecture2
import SwiftUI
import UnetonTheme

struct FamilySetupContent: View {
    @Environment(\.palette) private var palette
    @Bindable var store: StoreOf<FamilySetup>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "figure.child")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(palette.accent.color)
                        .padding(.bottom, 4)
                    Text("locAddYourBaby", comment: "Text in Setup: Add your baby")
                        .font(.soft(34))
                        .foregroundStyle(palette.ink.color)
                    Text("locKeepSleepGrowthAndTemperatureInOneSharedPlaceHaveAnInvitationScanItBelow", comment: "Text in Setup: Keep sleep, growth and temperature in one shared place. Have an invitation? Scan it below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.pendingCommandCount > 0 {
                    Label(LocalizedStringResource("locUnsentChangesAreSavedOnThisDeviceScanANewInvitationFromThatFamilyToRestoreAccessAndSyncThem", defaultValue: "Unsent changes are saved on this device. Scan a new invitation from that family to restore access and sync them.", comment: "Label in Setup: Unsent changes are saved on this device. Scan a new invitation from that family to restore access and sync them."),
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("locBabySName", comment: "Text in Setup: Baby’s name")
                            .font(.subheadline.weight(.semibold))
                        TextField(LocalizedStringResource("locNameOrNickname", defaultValue: "Name or nickname", comment: "Text field placeholder in Setup: Name or nickname"), text: $store.childName)
                            .textContentType(.nickname)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                    }

                    DatePicker(LocalizedStringResource("locDateOfBirth", defaultValue: "Date of birth", comment: "Picker title in Setup: Date of birth"), selection: $store.birthDate, in: ...Date.now, displayedComponents: .date)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("locGrowthReference", comment: "Text in Setup: Growth reference")
                            .font(.subheadline.weight(.semibold))
                        Picker(LocalizedStringResource("locGrowthReference", defaultValue: "Growth reference", comment: "Picker title in Setup: Growth reference"), selection: $store.growthReference) {
                            Text("locNone", comment: "Text in Setup: None").tag("none")
                            Text("locGirl", comment: "Text in Setup: Girl").tag("girl")
                            Text("locBoy", comment: "Text in Setup: Boy").tag("boy")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("locOptionalFinnishGrowthChartYouCanChangeThisLater", comment: "Text in Setup: Optional Finnish growth chart. You can change this later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if store.request.isRunning { ProgressView() }
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }
}
