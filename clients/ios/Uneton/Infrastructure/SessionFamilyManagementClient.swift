import ComposableArchitecture2
import Foundation
import UnetonCore

struct SessionFamilyManagementClient: Sendable {
    var load: @MainActor @Sendable (Family.ID) async throws -> FamilyManagementSnapshot
    var updateProfile: @MainActor @Sendable (String) async throws -> Void
    var renameFamily: @MainActor @Sendable (Family.ID, String) async throws -> Void
    var removeMember: @MainActor @Sendable (Family.ID, UserID) async throws -> Void
    var transferOwnership: @MainActor @Sendable (Family.ID, UserID) async throws -> Void
    var revokeInvite: @MainActor @Sendable (Family.ID, FamilyInviteID) async throws -> Void
    var leaveFamily: @MainActor @Sendable (Family.ID) async throws -> Void
    var deleteFamily: @MainActor @Sendable (Family.ID) async throws -> Void
    var invite: @MainActor @Sendable (Family.ID) async throws -> URL
    var addChild: @MainActor @Sendable (Family.ID, String, Date, String) async throws -> Void
    var createFamily: @MainActor @Sendable (Family.ID, String) async throws -> Void
    var updateChild: @MainActor @Sendable (Child) async throws -> Void
    var deleteChild: @MainActor @Sendable (Child) async throws -> Void

    @MainActor
    static func live(session: SessionStore) -> Self {
        Self(
            load: { try await session.managementSnapshot(familyID: $0) },
            updateProfile: { try await session.updateProfile($0) },
            renameFamily: { try await session.renameFamily($0, name: $1) },
            removeMember: { try await session.removeFamilyMember($0, userID: $1) },
            transferOwnership: { try await session.transferFamilyOwnership($0, userID: $1) },
            revokeInvite: { try await session.revokeInvite($0, inviteID: $1) },
            leaveFamily: { try await session.leaveFamily($0) },
            deleteFamily: { try await session.deleteFamily($0) },
            invite: { familyID in
                guard let url = await session.createInvite(familyID: familyID) else {
                    throw FamilyManagementError.invitationFailed
                }
                return url
            },
            addChild: { try await session.addChild($0, name: $1, birthDate: $2, reference: $3) },
            createFamily: { try await session.createFamily($0, name: $1) },
            updateChild: { try await session.updateChild($0) },
            deleteChild: { try await session.deleteChild($0) }
        )
    }

    static let unimplemented = Self(
        load: { _ in fatalError("Family management is not configured") },
        updateProfile: { _ in fatalError("Family management is not configured") },
        renameFamily: { _, _ in fatalError("Family management is not configured") },
        removeMember: { _, _ in fatalError("Family management is not configured") },
        transferOwnership: { _, _ in fatalError("Family management is not configured") },
        revokeInvite: { _, _ in fatalError("Family management is not configured") },
        leaveFamily: { _ in fatalError("Family management is not configured") },
        deleteFamily: { _ in fatalError("Family management is not configured") },
        invite: { _ in fatalError("Family management is not configured") },
        addChild: { _, _, _, _ in fatalError("Family management is not configured") },
        createFamily: { _, _ in fatalError("Family management is not configured") },
        updateChild: { _ in fatalError("Family management is not configured") },
        deleteChild: { _ in fatalError("Family management is not configured") }
    )
}

private enum FamilyManagementError: LocalizedError {
    case invitationFailed
    var errorDescription: String? { "Could not create an invitation." }
}

nonisolated extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: SessionFamilyManagementClient.unimplemented,
        previewValue: SessionFamilyManagementClient.unimplemented
    )
    var sessionFamilyManagement = SessionFamilyManagementClient.unimplemented
}
