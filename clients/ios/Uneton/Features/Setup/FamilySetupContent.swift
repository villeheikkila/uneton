import ComposableArchitecture2
import SwiftUI

struct FamilySetupContent: View {
    @Bindable var store: StoreOf<FamilySetup>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "figure.child")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.indigo)
                        .padding(.bottom, 4)
                    Text("Add your baby")
                        .font(.largeTitle.bold())
                    Text("Keep sleep, growth and temperature in one shared place. Have an invitation? Scan it below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.pendingCommandCount > 0 {
                    Label("Unsent changes are saved on this device. Scan a new invitation from that family to restore access and sync them.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Baby’s name")
                            .font(.subheadline.weight(.semibold))
                        TextField("Name or nickname", text: $store.childName)
                            .textContentType(.nickname)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                    }

                    DatePicker("Date of birth", selection: $store.birthDate, in: ...Date.now, displayedComponents: .date)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Growth reference")
                            .font(.subheadline.weight(.semibold))
                        Picker("Growth reference", selection: $store.growthReference) {
                            Text("None").tag("none")
                            Text("Girl").tag("girl")
                            Text("Boy").tag("boy")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("Optional Finnish growth chart. You can change this later.")
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
