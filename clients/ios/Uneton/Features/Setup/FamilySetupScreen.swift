import ComposableArchitecture2
import SwiftUI

struct FamilySetupScreen: View {
    @Bindable var store: StoreOf<FamilySetup>

    var body: some View {
        NavigationStack {
            FamilySetupContent(store: store)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaBar(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        store.send(.scanInvitationButtonTapped)
                    } label: {
                        Label("Scan invite", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.glass)

                    Button {
                        store.send(.addBabyButtonTapped)
                    } label: {
                        Label("Add baby", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    .disabled(
                        store.childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.request.isRunning
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .sheet(isPresented: $store.isScanning) {
                InvitationScannerSheet { store.send(.invitationCodeScanned($0)) }
            }
        }
    }
}

#if DEBUG
#Preview("Family setup") { ScreenFixtures.preview(.familySetup) }
#Preview("Invitation scanner") { ScreenFixtures.preview(.invitationScannerSheet) }
#endif
