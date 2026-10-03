import ActivityKit
import AuthenticationServices
import CryptoKit
import Dependencies
import Foundation
import Observation
import OSLog
import SQLiteData
import Tagged
import UnetonActivity
import UnetonCore

@MainActor
@Observable
final class SessionStore {
    @ObservationIgnored @Dependency(\.apiClient) private var apiClient
    @ObservationIgnored @Dependency(\.defaultDatabase) private var database
    @ObservationIgnored @Dependency(\.date.now) private var now
    @ObservationIgnored @Dependency(\.continuousClock) private var clock
    @ObservationIgnored @Dependency(\.uuid) private var uuid

    private enum Key {
        static let accessToken = "session.accessToken"
        static let refreshToken = "session.refreshToken"
        static let deviceID = "session.deviceID"
        static let appleUserID = "session.appleUserID"
        static let notificationsEnabled = "push.notificationsEnabled"
        static let liveActivitiesEnabled = "push.liveActivitiesEnabled"
        static let reminderLeadMinutes = "push.reminderLeadMinutes"
        static let tokenRegistrations = "push.tokenRegistrations"
        static let remoteReminderUntil = "push.remoteReminderUntil"
        static let pendingInitialFamilyID = "session.pendingInitialFamilyID"
        static let watchSnapshotVersion = "watch.snapshotVersion"
    }

    private let credentials = CredentialStore()
    private let appleCredentialMonitor = AppleCredentialMonitor()
    private let liveActivities = LiveActivityController()
    private let reminders = ReminderController()

    var isWorking = false
    private(set) var isAuthenticated = false
    private(set) var memberships: [AuthenticatedFamily]?
    var errorMessage: String?
    var forecast: SleepForecast?
    var prediction: SleepPrediction? { forecast?.nextSleepEstimate }
    var pendingInviteURL: URL?
    var notificationsEnabled: Bool
    var liveActivitiesEnabled: Bool
    var reminderLeadMinutes: Int

    private(set) var deviceID: DeviceID
    private var coordinator: SyncCoordinator
    private var refreshTask: Task<AuthenticationResponse, Error>?
    private var pendingAppleNonce: String?
    @ObservationIgnored private var watchBridge: PhoneWatchBridge!
    @ObservationIgnored private var credentialRevocationTask: Task<Void, Never>?
    @ObservationIgnored private var apnsTokenTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityTokenTask: Task<Void, Never>?
    @ObservationIgnored private var tokenRegistrations = PushTokenRegistrations()
    @ObservationIgnored private var pushRetryGeneration = 0
    @ObservationIgnored private var pushRetryTask: Task<Void, Never>?
    @ObservationIgnored private var isUploadingActivityTokens = false
    private let pushLogger = Logger(subsystem: "solutions.bytesized.uneton", category: "push-registration")
    private let sessionLogger = Logger(subsystem: "solutions.bytesized.uneton", category: "session")
    private var apnsToken: String? { tokenRegistrations.apnsToken }
    private var pushToStartToken: String? { tokenRegistrations.pushToStartToken }
    @ObservationIgnored private var reminderOwnership = SleepReminderOwnership()
    @ObservationIgnored private var isUploadingPushSettings = false
    @ObservationIgnored private var needsPushSettingsUpload = false
    @ObservationIgnored private var pushSettingsFailed = false

    init(demo: Bool = false) {
        if demo {
            let demoDeviceID = DeviceID()
            self.deviceID = demoDeviceID
            self.notificationsEnabled = false
            self.liveActivitiesEnabled = false
            self.reminderLeadMinutes = 15
            self.coordinator = SyncCoordinator(deviceID: demoDeviceID, accessToken: { nil })
            return
        }
        let defaults = UserDefaults.standard
        let deviceID: DeviceID
        if let stored = defaults.string(forKey: Key.deviceID).flatMap(DeviceID.init(uuidString:)) {
            deviceID = stored
        } else {
            deviceID = DeviceID()
            defaults.set(deviceID.uuidString, forKey: Key.deviceID)
        }
        self.deviceID = deviceID
        self.notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        self.liveActivitiesEnabled = defaults.object(forKey: Key.liveActivitiesEnabled) as? Bool ?? true
        self.reminderLeadMinutes = defaults.object(forKey: Key.reminderLeadMinutes) as? Int ?? 15
        self.reminderOwnership = SleepReminderOwnership(remoteUntil: defaults.object(forKey: Key.remoteReminderUntil) as? Date)
        self.coordinator = SyncCoordinator(
            deviceID: deviceID,
            accessToken: { CredentialStore().value(for: Key.accessToken) }
        )
        self.watchBridge = PhoneWatchBridge(store: self)
        if let stored = credentials.value(for: Key.tokenRegistrations),
           let data = stored.data(using: .utf8),
           let restored = try? JSONDecoder().decode(PushTokenRegistrations.self, from: data) {
            tokenRegistrations = restored
        }
        self.isAuthenticated = accessToken != nil
        self.credentialRevocationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            ) {
                guard !Task.isCancelled else { return }
                await self?.validateAppleCredential(force: true)
            }
        }
        let tokenUpdates = NotificationCenter.default.notifications(named: .unetonAPNSTokenChanged)
        self.apnsTokenTask = Task { [weak self] in
            if let token = PushRegistrationController.latestToken {
                await self?.receivedAPNSToken(token.hexadecimalString)
            }
            for await notification in tokenUpdates {
                guard let data = notification.object as? Data else { continue }
                await self?.receivedAPNSToken(data.hexadecimalString)
            }
        }
        self.liveActivityTokenTask = Task { [weak self] in
            await self?.liveActivities.observeTokens(
                pushToStart: { [weak self] token in await self?.receivedPushToStartToken(token) },
                activity: { [weak self] sessionID, token in await self?.receivedActivityToken(sessionID: sessionID, token: token) }
            )
        }
        PushRegistrationController.installBackgroundRefresh(
            family: { [weak self] familyID in
                await self?.synchronizeInBackground(familyID: familyID) ?? false
            },
            all: { [weak self] in
                await self?.synchronizeAllInBackground() ?? false
            }
        )
    }

    var accessToken: String? {
        credentials.value(for: Key.accessToken)
    }

    func demoAuthenticate() { isAuthenticated = true }
    func demoSignOut() {
        forecast = nil
        isAuthenticated = false
    }

    func managementSnapshot(familyID: Family.ID) async throws -> FamilyManagementSnapshot {
        guard let accessToken else { throw SessionError.notAuthenticated }
        let snapshot: FamilyManagementSnapshot
        do {
            snapshot = try await apiClient.getFamilyManagement(familyID, accessToken)
        } catch {
            if isPermissionDeniedAPIError(error) { try? await refreshAuthentication() }
            throw error
        }
        let updatedAt = now
        try await database.write { db in
            try Family.upsert {
                Family(id: familyID, name: snapshot.familyName, role: snapshot.myRole, updatedAt: updatedAt)
            }.execute(db)
        }
        return snapshot
    }

    func updateProfile(_ name: String) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        _ = try await apiClient.updateProfile(name, accessToken)
    }

    func renameFamily(_ familyID: Family.ID, name: String) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        let saved: String
        do {
            saved = try await apiClient.renameFamily(familyID, name, accessToken)
        } catch {
            guard let snapshot = try? await managementSnapshot(familyID: familyID),
                  snapshot.familyName == name else { throw error }
            saved = snapshot.familyName
        }
        let updatedAt = now
        try await database.write { db in
            if var family = try Family.find(familyID).fetchOne(db) {
                family.name = saved
                family.updatedAt = updatedAt
                try Family.upsert { family }.execute(db)
            }
        }
        do { try await refreshAuthentication() }
        catch {
            if let index = memberships?.firstIndex(where: { $0.id == familyID }) {
                memberships?[index].name = saved
            }
        }
    }

    func removeFamilyMember(_ familyID: Family.ID, userID: UserID) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        do {
            try await apiClient.removeFamilyMember(familyID, userID, accessToken)
        } catch {
            guard let snapshot = try? await managementSnapshot(familyID: familyID),
                  !snapshot.members.contains(where: { $0.id == userID }) else { throw error }
        }
    }

    func transferFamilyOwnership(_ familyID: Family.ID, userID: UserID) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        do {
            try await apiClient.transferFamilyOwnership(familyID, userID, accessToken)
        } catch {
            guard let snapshot = try? await managementSnapshot(familyID: familyID),
                  snapshot.myRole == "caregiver",
                  snapshot.members.contains(where: { $0.id == userID && $0.role == "owner" }) else { throw error }
        }
        do { try await refreshAuthentication() }
        catch {
            if let index = memberships?.firstIndex(where: { $0.id == familyID }) {
                memberships?[index].role = "caregiver"
            }
            let updatedAt = now
            try? await database.write { db in
                if var family = try Family.find(familyID).fetchOne(db) {
                    family.role = "caregiver"
                    family.updatedAt = updatedAt
                    try Family.upsert { family }.execute(db)
                }
            }
        }
    }

    func revokeInvite(_ familyID: Family.ID, inviteID: FamilyInviteID) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        do {
            try await apiClient.revokeInvite(familyID, inviteID, accessToken)
        } catch {
            guard let snapshot = try? await managementSnapshot(familyID: familyID),
                  !snapshot.pendingInvites.contains(where: { $0.id == inviteID }) else { throw error }
        }
    }

    func leaveFamily(_ familyID: Family.ID) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        do {
            _ = try await synchronizeWithRefresh(familyID: familyID)
        } catch {
            if await membershipWasRemoved(familyID) { return }
            throw error
        }
        guard !(await hasUnresolvedSyncState(familyID: familyID)) else { throw SessionError.unsyncedChanges }
        do {
            try await apiClient.leaveFamily(familyID, accessToken)
        } catch {
            if !(await membershipWasRemoved(familyID)) { throw error }
        }
        do { try await refreshAuthentication() }
        catch { memberships?.removeAll { $0.id == familyID } }
        await watchBridge.publishSnapshot()
    }

    func deleteFamily(_ familyID: Family.ID) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        do {
            _ = try await synchronizeWithRefresh(familyID: familyID)
        } catch {
            if await membershipWasRemoved(familyID) { return }
            throw error
        }
        guard !(await hasUnresolvedSyncState(familyID: familyID)) else { throw SessionError.unsyncedChanges }
        do {
            try await apiClient.deleteFamily(familyID, accessToken)
        } catch {
            if !(await membershipWasRemoved(familyID)) { throw error }
        }
        do { try await refreshAuthentication() }
        catch { memberships?.removeAll { $0.id == familyID } }
        await watchBridge.publishSnapshot()
    }

    private func membershipWasRemoved(_ familyID: Family.ID) async -> Bool {
        do { try await refreshAuthentication() } catch { return false }
        return memberships?.contains(where: { $0.id == familyID }) == false
    }

    func addChild(_ familyID: Family.ID, name: String, birthDate: Date, reference: String) async throws {
        _ = try await coordinator.createChild(familyID: familyID, nickname: name, birthDate: birthDate,
            growthReference: reference)
        if let prediction = try? await synchronizeWithRefresh(familyID: familyID) {
            await setPrediction(prediction)
        }
    }

    func createFamily(_ familyID: Family.ID, name: String) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        try await apiClient.createFamily(familyID, name, accessToken)
        let family = Family(id: familyID, name: name, role: "owner", updatedAt: now)
        try await database.write { db in try Family.upsert { family }.execute(db) }
        try await refreshAuthentication()
    }

    func updateChild(_ child: Child) async throws {
        try await coordinator.updateChild(familyID: child.familyID, childID: child.id,
            nickname: child.nickname, birthDate: child.birthDate, predictionMode: child.predictionMode,
            manualIntervalMinutes: child.manualIntervalMinutes, quietHoursStartMinutes: child.quietHoursStartMinutes,
            quietHoursEndMinutes: child.quietHoursEndMinutes, timeZone: child.timeZone,
            growthReference: child.growthReference)
        if let prediction = try? await synchronizeWithRefresh(familyID: child.familyID) {
            await setPrediction(prediction)
        }
    }

    func deleteChild(_ child: Child) async throws {
        let hasActiveSleep = try await database.read { db in
            try SleepSession.where {
                $0.childID.eq(child.id) && $0.endedAt.is(nil)
                    && $0.deletedAt.is(nil) && $0.supersededByID.is(nil)
            }
                .fetchCount(db) > 0
        }
        guard !hasActiveSleep else { throw SessionError.activeSleep }
        try await coordinator.deleteChild(familyID: child.familyID, childID: child.id)
        if let prediction = try? await synchronizeWithRefresh(familyID: child.familyID) {
            await setPrediction(prediction)
        }
    }

    func developmentAuthenticate(name: String) async {
        await perform {
            let authentication = try await apiClient.developmentAuth(name, deviceID)
            save(authentication)
            await configurePushRegistration()
            if let familyID = try await restoreAuthenticatedFamily(authentication) {
                await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
            }
            await acceptPendingInviteIfPossible()
        }
    }

    func completeAppleAuthorization(
        _ result: Result<ASAuthorization, any Error>
    ) async {
        await perform {
            guard let nonce = pendingAppleNonce else { throw SessionError.missingAppleNonce }
            pendingAppleNonce = nil
            let authorization = try result.get()
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let codeData = credential.authorizationCode,
                let code = String(data: codeData, encoding: .utf8)
            else { throw SessionError.invalidAppleCredential }
            let components = [credential.fullName?.givenName, credential.fullName?.familyName].compactMap { $0 }
            let authentication = try await apiClient.appleAuth(code, nonce, components.joined(separator: " "), deviceID)
            credentials.set(credential.user, for: Key.appleUserID)
            save(authentication)
            await configurePushRegistration()
            if let familyID = try await restoreAuthenticatedFamily(authentication) {
                await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
            }
            await acceptPendingInviteIfPossible()
        }
    }

    func prepareAppleAuthorization(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try randomNonce()
            pendingAppleNonce = nonce
            request.requestedScopes = [.fullName]
            request.nonce = hashedNonce(nonce)
        } catch {
            pendingAppleNonce = nil
            errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
        }
    }

    func validateAppleCredential(force: Bool = false) async {
        guard accessToken != nil, let appleUserID = credentials.value(for: Key.appleUserID) else { return }
        if await appleCredentialMonitor.check(userID: appleUserID, force: force, now: now) == .revoked {
            await signOut()
        }
    }

    @discardableResult
    func signOut() async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        guard await synchronizeAllInBackground() else {
            errorMessage = String(localized: LocalizedStringResource("locUnetonCouldNotSyncYourChangesConnectToTheInternetAndTryAgainBeforeSigningOut", defaultValue: "Uneton could not sync your changes. Connect to the internet and try again before signing out.", comment: "Message in SessionStore: Uneton could not sync your changes. Connect to the internet and try again before signing out."))
            return false
        }
        guard !(await hasUnresolvedSyncState()) else {
            errorMessage = String(localized: LocalizedStringResource("locResolveOrDiscardSyncConflictsBeforeSigningOut", defaultValue: "Resolve or discard sync conflicts before signing out.", comment: "Message in SessionStore: Resolve or discard sync conflicts before signing out."))
            return false
        }
        guard let accessToken else {
            await clearLocalSession()
            return true
        }
        do {
            try await apiClient.signOut(accessToken)
        } catch where isUnauthenticatedAPIError(error) {
            // A prior sign-out may have succeeded after its response was lost.
        } catch {
            errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
            return false
        }
        await clearLocalSession()
        return true
    }

    func deleteAccount() async -> Bool {
        guard let accessToken else { return false }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        if await hasUnresolvedSyncState() { _ = await synchronizeAllInBackground() }
        guard !(await hasUnresolvedSyncState()) else {
            errorMessage = String(localized: LocalizedStringResource("locSyncOrResolvePendingChangesBeforeDeletingYourAccount", defaultValue: "Sync or resolve pending changes before deleting your account.", comment: "Message in SessionStore: Sync or resolve pending changes before deleting your account."))
            return false
        }
        do {
            try await apiClient.deleteAccount(accessToken)
            await clearLocalSession()
            return true
        } catch {
            errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
            return false
        }
    }

    func startSleep(familyID: Family.ID, childID: Child.ID, childName: String = String(localized: LocalizedStringResource("locChild", defaultValue: "Child", comment: "Message in SessionStore: Child")), startedAt: Date? = nil, sessionID: SleepSession.ID? = nil, commandID: PendingCommand.ID? = nil) async {
        let startedAt = startedAt ?? now
        await perform {
            let sessionID = try await coordinator.startSleep(familyID: familyID, childID: childID, sessionID: sessionID, commandID: commandID, startedAt: startedAt)
            await reminders.schedule(fireDate: nil)
            if liveActivitiesEnabled { await liveActivities.start(
                familyID: familyID,
                childID: childID,
                sessionID: sessionID,
                childName: childName,
                startedAt: startedAt
            ) }
            await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
        }
    }

    func endSleep(familyID: Family.ID, sessionID: SleepSession.ID, endedAt: Date? = nil) async {
        let endedAt = endedAt ?? now
        await perform {
            try await coordinator.endSleep(familyID: familyID, sessionID: sessionID, endedAt: endedAt)
            await liveActivities.end(sessionID: sessionID, endedAt: endedAt)
            await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
        }
    }

    func logSleep(
        familyID: Family.ID,
        childID: Child.ID,
        sessionID: SleepSession.ID? = nil,
        startedAt: Date,
        endedAt: Date?
    ) async {
        await perform {
            try await coordinator.upsertSleep(
                familyID: familyID,
                childID: childID,
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: endedAt
            )
            await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
        }
    }

    func logGrowthMeasurement(
        familyID: Family.ID,
        childID: Child.ID,
        measurementID: GrowthMeasurement.ID? = nil,
        measuredAt: Date,
        weightGrams: Int?,
        heightMillimeters: Int?,
        note: String = ""
    ) async {
        await perform {
            try await coordinator.upsertGrowthMeasurement(
                familyID: familyID, childID: childID, measurementID: measurementID,
                measuredAt: measuredAt, weightGrams: weightGrams,
                heightMillimeters: heightMillimeters, note: note
            )
            _ = try await synchronizeWithRefresh(familyID: familyID)
        }
    }

    func deleteGrowthMeasurement(familyID: Family.ID, measurementID: GrowthMeasurement.ID) async {
        await perform {
            try await coordinator.deleteGrowthMeasurement(familyID: familyID, measurementID: measurementID)
            _ = try await synchronizeWithRefresh(familyID: familyID)
        }
    }

    func logTemperatureReading(familyID: Family.ID, childID: Child.ID, readingID: TemperatureReading.ID? = nil,
                               measuredAt: Date, centiCelsius: Int, note: String = "",
                               expectedRevision: Int? = nil) async {
        await perform {
            try await coordinator.upsertTemperatureReading(familyID: familyID, childID: childID,
                readingID: readingID, measuredAt: measuredAt, centiCelsius: centiCelsius,
                note: note, expectedRevision: expectedRevision)
            _ = try await synchronizeWithRefresh(familyID: familyID)
        }
    }

    func deleteTemperatureReading(familyID: Family.ID, readingID: TemperatureReading.ID,
                                  expectedRevision: Int? = nil) async {
        await perform {
            try await coordinator.deleteTemperatureReading(familyID: familyID, readingID: readingID,
                expectedRevision: expectedRevision)
            _ = try await synchronizeWithRefresh(familyID: familyID)
        }
    }

    func setGrowthReference(familyID: Family.ID, childID: Child.ID, growthReference: String) async {
        await perform {
            try await coordinator.updateGrowthReference(
                familyID: familyID, childID: childID, growthReference: growthReference
            )
            _ = try await synchronizeWithRefresh(familyID: familyID)
        }
    }

    func synchronize(familyID: Family.ID) async {
        guard accessToken != nil else { return }
        await perform {
            await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
        }
    }

    func observeChanges(familyID: Family.ID) async {
        var retryDelay = 1
        try? await refreshAuthentication()
        while !Task.isCancelled {
            if let memberships, !memberships.contains(where: { $0.id == familyID }) { return }
            do {
                await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
                let cursor = try await coordinator.cursor(familyID: familyID)
                let generation = try await coordinator.generation(familyID: familyID)
                guard let accessToken else { return }
                retryDelay = 1
                try await apiClient.waitForChange(familyID, cursor, generation, accessToken)
            } catch is CancellationError {
                return
            } catch {
                if isPermissionDeniedAPIError(error) {
                    try? await refreshAuthentication()
                    return
                }
                try? await clock.sleep(for: .seconds(retryDelay))
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    func handle(url: URL) async {
        if let token = FamilyInvitationLink.token(from: url) {
            guard let accessToken else {
                pendingInviteURL = url
                return
            }
            await perform {
                let accepted = try await apiClient.acceptInvite(token, accessToken)
                let acceptedAt = now
                try await database.write { database in
                    try Family.upsert {
                        Family(id: accepted.familyID, name: String(localized: LocalizedStringResource("locSharedFamily", defaultValue: "Shared family", comment: "Message in SessionStore: Shared family")), role: accepted.role, updatedAt: acceptedAt)
                    }.execute(database)
                }
                // Refresh after the placeholder row so the server's family name wins
                // and the joined family enters the membership list.
                try await refreshAuthentication()
                await setPrediction(try await synchronizeWithRefresh(familyID: accepted.familyID))
            }
            return
        }
        guard url.scheme == "uneton", url.host == "sleep", url.path == "/end",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let familyValue = components.queryItems?.first(where: { $0.name == "familyID" })?.value,
              let sessionValue = components.queryItems?.first(where: { $0.name == "sessionID" })?.value,
              let familyID = Family.ID(uuidString: familyValue),
              let sessionID = SleepSession.ID(uuidString: sessionValue)
        else { return }
        await endSleep(familyID: familyID, sessionID: sessionID)
    }

    func acceptPendingInviteIfPossible() async {
        guard let pendingInviteURL else { return }
        self.pendingInviteURL = nil
        await handle(url: pendingInviteURL)
    }

    func createChildFamily(childName: String, birthDate: Date, growthReference: String) async {
        await perform {
            try await createInitialFamily(
                childName: childName,
                birthDate: birthDate,
                growthReference: growthReference
            )
        }
    }

    func createInvite(familyID: Family.ID) async -> URL? {
        guard let accessToken else { return nil }
        do {
            let invite = try await apiClient.createInvite(familyID, accessToken)
            return FamilyInvitationLink.url(token: invite.token)
        } catch {
            errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
            return nil
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.notificationsEnabled)
        if enabled { await PushRegistrationController.requestAuthorization() }
        await uploadPushSettings()
    }

    func setLiveActivitiesEnabled(_ enabled: Bool) async {
        liveActivitiesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.liveActivitiesEnabled)
        if !enabled {
            for activity in Activity<SleepActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        await uploadPushSettings()
    }

    func setReminderLeadMinutes(_ minutes: Int) async {
        reminderLeadMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: Key.reminderLeadMinutes)
        await scheduleLocalReminder()
        await uploadPushSettings()
    }

    func resolveConflict(
        _ conflictID: SyncConflict.ID,
        familyID: Family.ID,
        resolution: SyncConflictResolution
    ) async {
        await perform {
            try await coordinator.resolveConflict(conflictID, resolution: resolution)
            await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
        }
    }

    func watchDiarySnapshot() async throws -> WatchDiarySnapshot {
        let defaults = UserDefaults.standard
        let version = max(defaults.integer(forKey: Key.watchSnapshotVersion) + 1,
            Int(now.timeIntervalSince1970 * 1_000))
        defaults.set(version, forKey: Key.watchSnapshotVersion)
        guard isAuthenticated else { return WatchDiarySnapshot(version: version) }
        let allowedFamilyIDs = memberships.map { Set($0.map(\.id)) }
        return try await database.read { database in
            let families = try Family.order { $0.updatedAt.desc() }.fetchAll(database)
                .filter { allowedFamilyIDs?.contains($0.id) ?? true }
            let children = try Child.fetchAll(database)
            let sessions = try SleepSession.fetchAll(database)
            let readings = try TemperatureReading.order { $0.measuredAt.desc() }.fetchAll(database)
            return WatchDiarySnapshot(version: version, children: families.flatMap { family in
                children.filter { $0.familyID == family.id }.map { child in
                    let active = sessions.first {
                        $0.childID == child.id && $0.endedAt == nil && $0.deletedAt == nil && $0.supersededByID == nil
                    }
                    let recent = readings.filter { $0.childID == child.id && $0.deletedAt == nil }
                        .prefix(10).map { reading in
                            WatchDiaryReading(id: reading.id, measuredAt: reading.measuredAt,
                                centiCelsius: reading.centiCelsius, note: reading.note,
                                revision: reading.revision, isPending: reading.pendingCommandID != nil)
                        }
                    return WatchDiaryChild(id: child.id, familyID: family.id, familyName: family.name,
                        nickname: child.nickname, activeSleepID: active?.id, activeSleepStartedAt: active?.startedAt,
                        readings: recent)
                }
            })
        }
    }

    func handleWatchRequest(_ request: WatchDiaryRequest) async -> WatchDiaryResponse {
        do {
            let before = try await watchDiarySnapshot()
            guard request.isWellFormed else {
                return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locInvalidWatchRequest", defaultValue: "Invalid Watch request", comment: "Message in SessionStore: Invalid Watch request")))
            }
            if request.action == .status {
                Task { [weak self] in _ = await self?.synchronizeAllInBackground() }
                return WatchDiaryResponse(snapshot: before)
            }
            guard let familyID = request.familyID, let childID = request.childID,
                  let child = before.children.first(where: { $0.familyID == familyID && $0.id == childID }) else {
                return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locSelectAChildOnIPhoneFirst", defaultValue: "Select a child on iPhone first", comment: "Message in SessionStore: Select a child on iPhone first")))
            }
            let readingID = request.readingID
            if let readingID {
                let existing = try await database.read { try TemperatureReading.find(readingID).fetchOne($0) }
                if request.action == .upsertTemperature && request.isNewReading {
                    if let existing {
                        let same = existing.familyID == familyID && existing.childID == childID
                            && existing.deletedAt == nil && existing.measuredAt == request.measuredAt
                            && existing.centiCelsius == request.centiCelsius && existing.note == request.note
                        return WatchDiaryResponse(snapshot: before,
                            errorMessage: same ? nil : String(localized: LocalizedStringResource("locReadingAlreadyExists", defaultValue: "Reading already exists", comment: "Message in SessionStore: Reading already exists")))
                    }
                } else if request.action == .upsertTemperature || request.action == .deleteTemperature {
                    if request.action == .deleteTemperature && existing == nil {
                        return WatchDiaryResponse(snapshot: before)
                    }
                    guard let existing, existing.familyID == familyID, existing.childID == childID,
                          existing.deletedAt == nil else {
                        return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locReadingIsNoLongerAvailable", defaultValue: "Reading is no longer available", comment: "Message in SessionStore: Reading is no longer available")))
                    }
                    if existing.revision != request.expectedRevision {
                        let sameEdit = request.action == .upsertTemperature
                            && existing.measuredAt == request.measuredAt
                            && existing.centiCelsius == request.centiCelsius && existing.note == request.note
                        return WatchDiaryResponse(snapshot: before,
                            errorMessage: sameEdit ? nil : String(localized: LocalizedStringResource("locReadingChangedOnIPhoneRefreshAndTryAgain", defaultValue: "Reading changed on iPhone. Refresh and try again.", comment: "Message in SessionStore: Reading changed on iPhone. Refresh and try again.")))
                    }
                }
            }
            switch request.action {
            case .status:
                break
            case .startSleep:
                let sessionID = request.sessionID!
                let commandID = PendingCommand.ID(rawValue: sessionID.rawValue)
                let prior = try await database.read { database in
                    (try PendingCommand.find(commandID).fetchOne(database),
                     try AcknowledgedCommand.find(commandID).fetchOne(database))
                }
                if let pending = prior.0 {
                    guard pending.familyID == familyID && pending.kind == "startSleep" else {
                        return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locInvalidWatchRequest", defaultValue: "Invalid Watch request", comment: "Message in SessionStore: Invalid Watch request")))
                    }
                    return WatchDiaryResponse(snapshot: before)
                }
                if let acknowledged = prior.1 {
                    guard acknowledged.familyID == familyID && acknowledged.kind == "startSleep" else {
                        return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locInvalidWatchRequest", defaultValue: "Invalid Watch request", comment: "Message in SessionStore: Invalid Watch request")))
                    }
                    return WatchDiaryResponse(snapshot: before)
                }
                if let existing = try await database.read({ database in
                    try SleepSession.find(sessionID).fetchOne(database)
                }) {
                    guard existing.familyID == familyID && existing.childID == childID else {
                        return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locInvalidWatchRequest", defaultValue: "Invalid Watch request", comment: "Message in SessionStore: Invalid Watch request")))
                    }
                    return WatchDiaryResponse(snapshot: before)
                }
                guard child.activeSleepStartedAt == nil else { return WatchDiaryResponse(snapshot: before) }
                await startSleep(familyID: familyID, childID: childID, childName: child.nickname,
                    sessionID: sessionID, commandID: commandID)
            case .endSleep:
                let requestedID = request.sessionID!
                let session = try await database.read { try SleepSession.find(requestedID).fetchOne($0) }
                guard let session, session.familyID == familyID, session.childID == childID else {
                    return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locInvalidWatchRequest", defaultValue: "Invalid Watch request", comment: "Message in SessionStore: Invalid Watch request")))
                }
                guard session.endedAt == nil else { return WatchDiaryResponse(snapshot: before) }
                guard request.targetsActiveSleep(of: child) else {
                    return WatchDiaryResponse(snapshot: before, errorMessage: String(localized: LocalizedStringResource("locSleepChangedOnIPhoneRefreshAndTryAgain", defaultValue: "Sleep changed on iPhone. Refresh and try again.", comment: "Watch wake action was based on a sleep session that is no longer active; ask the caregiver to refresh.")))
                }
                await endSleep(familyID: familyID, sessionID: requestedID)
            case .upsertTemperature:
                await logTemperatureReading(familyID: familyID, childID: childID, readingID: readingID,
                    measuredAt: request.measuredAt!, centiCelsius: request.centiCelsius!,
                    note: request.note, expectedRevision: request.expectedRevision)
            case .deleteTemperature:
                await deleteTemperatureReading(familyID: familyID, readingID: request.readingID!,
                    expectedRevision: request.expectedRevision)
            }
            let after = try await watchDiarySnapshot()
            let accepted: Bool
            switch request.action {
            case .status: accepted = true
            case .startSleep:
                let saved = try await database.read { try SleepSession.find(request.sessionID!).fetchOne($0) }
                accepted = saved?.familyID == familyID && saved?.childID == childID
            case .endSleep:
                let saved = try await database.read { try SleepSession.find(request.sessionID!).fetchOne($0) }
                accepted = saved?.familyID == familyID && saved?.childID == childID && saved?.endedAt != nil
            case .upsertTemperature:
                let saved = try await database.read { try TemperatureReading.find(readingID!).fetchOne($0) }
                accepted = saved?.familyID == familyID && saved?.childID == childID
                    && saved?.deletedAt == nil && saved?.measuredAt == request.measuredAt
                    && saved?.centiCelsius == request.centiCelsius && saved?.note == request.note
            case .deleteTemperature:
                let saved = try await database.read { try TemperatureReading.find(readingID!).fetchOne($0) }
                accepted = saved == nil || saved?.deletedAt != nil
            }
            if !accepted {
                return WatchDiaryResponse(snapshot: after, errorMessage: errorMessage ?? String(localized: LocalizedStringResource("locCouldNotSaveOnIPhone", defaultValue: "Could not save on iPhone", comment: "Message in SessionStore: Could not save on iPhone")), retryable: true)
            }
            return WatchDiaryResponse(snapshot: after,
                notice: errorMessage == nil ? nil : String(localized: LocalizedStringResource("locSavedOnIPhoneSyncWillRetryWhenOnline", defaultValue: "Saved on iPhone. Sync will retry when online.", comment: "Message in SessionStore: Saved on iPhone. Sync will retry when online.")))
        } catch {
            return WatchDiaryResponse(snapshot: (try? await watchDiarySnapshot()) ?? WatchDiarySnapshot(),
                errorMessage: String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")), retryable: true)
        }
    }

    private func createInitialFamily(
        childName: String,
        birthDate: Date,
        growthReference: String
    ) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        let familyID = UserDefaults.standard.string(forKey: Key.pendingInitialFamilyID)
            .flatMap(Family.ID.init(uuidString:)) ?? Family.ID(rawValue: uuid())
        UserDefaults.standard.set(familyID.uuidString, forKey: Key.pendingInitialFamilyID)
        let family = Family(id: familyID, name: String(localized: LocalizedStringResource("locOurFamily", defaultValue: "Our family", comment: "Message in SessionStore: Our family")), role: "owner", updatedAt: now)
        try await database.write { database in
            try Family.upsert { family }.execute(database)
        }
        // Persist the client-generated identity before the network request. If the
        // response is lost, onboarding retries the same idempotent server operation.
        try await apiClient.createFamily(familyID, String(localized: LocalizedStringResource("locOurFamily", defaultValue: "Our family", comment: "Message in SessionStore: Our family")), accessToken)
        // Memberships gate which families the app shows and syncs; take the
        // server's updated list so the new family becomes visible.
        try await refreshAuthentication()
        _ = try await coordinator.createChild(
            familyID: familyID,
            nickname: childName,
            birthDate: birthDate,
            growthReference: growthReference
        )
        await reminders.requestAuthorization()
        await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
        UserDefaults.standard.removeObject(forKey: Key.pendingInitialFamilyID)
    }

    private func save(_ authentication: AuthenticationResponse) {
        tokenRegistrations.bind(to: authentication.userID)
        persistTokenRegistrations()
        credentials.set(authentication.accessToken, for: Key.accessToken)
        credentials.set(authentication.refreshToken, for: Key.refreshToken)
        UserDefaults.standard.set(authentication.deviceID.uuidString, forKey: Key.deviceID)
        isAuthenticated = true
        memberships = authentication.families
    }

    private func configurePushRegistration() async {
        if notificationsEnabled { await PushRegistrationController.requestAuthorization() }
        else { PushRegistrationController.register() }
        await uploadPushSettings()
        await uploadActivityTokens()
    }

    private func receivedAPNSToken(_ token: String) async {
        tokenRegistrations.apnsToken = token
        persistTokenRegistrations()
        await uploadPushSettings()
    }

    private func receivedPushToStartToken(_ token: String) async {
        tokenRegistrations.pushToStartToken = token
        persistTokenRegistrations()
        await uploadPushSettings()
    }

    private func receivedActivityToken(sessionID: SleepSession.ID, token: String) async {
        guard accessToken != nil else { return }
        tokenRegistrations.record(sessionID: sessionID, token: token, now: now)
        persistTokenRegistrations()
        await uploadActivityTokens()
    }

    private func uploadPushSettings() async {
        // Serialize control-plane updates so older acknowledgements cannot undo
        // a newer notification switch or ownership period.
        needsPushSettingsUpload = true
        guard !isUploadingPushSettings else { return }
        isUploadingPushSettings = true
        defer { isUploadingPushSettings = false }
        repeat {
            needsPushSettingsUpload = false
            guard let accessToken else { return }
            let registrationRevision = tokenRegistrations.reserveRevision()
            guard persistTokenRegistrations() else {
                pushSettingsFailed = true
                schedulePushRetry()
                return
            }
            let until: Date?
            if notificationsEnabled {
                if apnsToken != nil {
                    reminderOwnership.reserve(until: now.addingTimeInterval(SleepReminderOwnership.duration))
                }
                until = reminderOwnership.remoteUntil
            } else {
                until = nil
            }
            // Cancel conflicting local requests before a potentially lost response.
            UserDefaults.standard.set(reminderOwnership.remoteUntil, forKey: Key.remoteReminderUntil)
            await scheduleLocalReminder()
            let settings = DevicePushSettings(notificationsEnabled: notificationsEnabled,
                liveActivitiesEnabled: liveActivitiesEnabled, reminderLeadMinutes: reminderLeadMinutes,
                remoteRemindersUntil: until,
                notificationLanguage: Bundle.main.preferredLocalizations.first == "fi" ? "fi" : "en",
                registrationRevision: registrationRevision)
            do {
                let acknowledged = try await apiClient.updateDevicePushSettings(apnsToken, pushToStartToken,
                    PushRegistrationController.environment, settings, accessToken)
                pushSettingsFailed = false
                // Sign-out may have completed while the request was in flight.
                if self.accessToken == accessToken {
                    reminderOwnership.remoteUntil = acknowledged.remoteRemindersUntil
                    UserDefaults.standard.set(reminderOwnership.remoteUntil, forKey: Key.remoteReminderUntil)
                    await scheduleLocalReminder()
                }
            } catch {
                pushSettingsFailed = true
                pushLogger.warning("Device token registration failed; retry scheduled")
                schedulePushRetry()
                // Keep the reserved period after an ambiguous response. Re-enabling
                // a local request here could duplicate an already-owned remote alert.
            }
        } while needsPushSettingsUpload
    }

    private func scheduleLocalReminder() async {
        if let childID = forecast?.childID {
            // Optimistic sleeping state must suppress even a cached awake estimate.
            let familyIDs = memberships.map { Set($0.map(\.id)) }
            let canRemind = (try? await database.read { db in
                guard let child = try Child.find(childID).fetchOne(db),
                      familyIDs?.contains(child.familyID) ?? true else { return false }
                return try SleepSession.where {
                    $0.childID.eq(childID) && $0.endedAt.is(nil)
                        && $0.deletedAt.is(nil) && $0.supersededByID.is(nil)
                }.fetchCount(db) == 0
            }) ?? false
            if !canRemind { await reminders.schedule(fireDate: nil); return }
        }
        await reminders.schedule(fireDate: reminderOwnership.localFireDate(forecast: forecast,
            notificationsEnabled: notificationsEnabled, leadMinutes: reminderLeadMinutes, now: now))
    }

    @discardableResult
    private func persistTokenRegistrations() -> Bool {
        guard let data = try? JSONEncoder().encode(tokenRegistrations),
              let value = String(data: data, encoding: .utf8) else { return false }
        credentials.set(value, for: Key.tokenRegistrations)
        let saved = credentials.value(for: Key.tokenRegistrations) == value
        if !saved { pushLogger.error("Could not persist token registration work") }
        return saved
    }

    private func uploadActivityTokens() async {
        guard !isUploadingActivityTokens, let accessToken else { return }
        guard persistTokenRegistrations() else { schedulePushRetry(); return }
        isUploadingActivityTokens = true
        defer {
            isUploadingActivityTokens = false
            if !tokenRegistrations.activities.isEmpty { schedulePushRetry() }
        }
        let registrations = tokenRegistrations
        for (sessionID, token) in registrations.activities {
            guard let revision = registrations.activityRevisions[sessionID] else { continue }
            guard self.accessToken == accessToken else { return }
            do {
                try await apiClient.registerLiveActivity(sessionID, token,
                    PushRegistrationController.environment, revision, accessToken)
                guard self.accessToken == accessToken else { return }
                tokenRegistrations.acknowledge(sessionID: sessionID, token: token, revision: revision)
                persistTokenRegistrations()
            } catch {
                pushLogger.warning("Activity token registration failed; retry scheduled")
                schedulePushRetry()
            }
        }
        if !tokenRegistrations.activities.isEmpty {
            let count = tokenRegistrations.activities.count
            let age = Int(now.timeIntervalSince(tokenRegistrations.pendingSince.values.min() ?? now))
            pushLogger.notice("Pending activity registrations: \(count), oldest age seconds: \(age)")
            schedulePushRetry()
        }
    }

    private func schedulePushRetry() {
        guard pushRetryTask == nil, accessToken != nil else { return }
        pushRetryGeneration += 1
        let generation = pushRetryGeneration
        pushRetryTask = Task { [weak self] in
            var delay = 2
            while let self, !Task.isCancelled, self.accessToken != nil,
                  self.pushRetryGeneration == generation {
                do { try await self.clock.sleep(for: .seconds(delay)) } catch { break }
                // Refresh authentication through its usual path before retrying.
                try? await self.refreshAuthentication()
                await self.uploadPushSettings()
                await self.uploadActivityTokens()
                delay = min(delay * 2, 300)
                if self.tokenRegistrations.activities.isEmpty && !self.pushSettingsFailed { break }
            }
            if self?.pushRetryGeneration == generation { self?.pushRetryTask = nil }
        }
    }

    private func reconcileLiveActivities() async {
        let familyIDs = Set(memberships?.map(\.id) ?? [])
        guard let sessions = try? await database.read({ db in
            try SleepSession.fetchAll(db)
        }) else { return }
        let visible = sessions.filter { familyIDs.contains($0.familyID) && $0.deletedAt == nil && $0.supersededByID == nil }
        let active = Dictionary(uniqueKeysWithValues: visible.filter { $0.endedAt == nil }.map { ($0.id, $0) })
        var seen = Set<SleepSession.ID>()
        for activity in Activity<SleepActivityAttributes>.activities {
            let id = activity.attributes.sessionID
            if !liveActivitiesEnabled || active[id] == nil || !seen.insert(id).inserted {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        // Keep ended sessions until registration acknowledges: the server must
        // know a late token so it can send the corresponding remote end.
        tokenRegistrations.retainActivities(Set(visible.map(\.id)))
        persistTokenRegistrations()
    }

    private func clearLocalSession() async {
        for activity in Activity<SleepActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        pushRetryGeneration += 1
        pushRetryTask?.cancel()
        pushRetryTask = nil
        tokenRegistrations = PushTokenRegistrations()
        credentials.removeValue(for: Key.tokenRegistrations)
        credentials.removeValue(for: Key.accessToken)
        credentials.removeValue(for: Key.refreshToken)
        credentials.removeValue(for: Key.appleUserID)
        UserDefaults.standard.removeObject(forKey: Key.pendingInitialFamilyID)
        forecast = nil
        await reminders.schedule(fireDate: nil)
        reminderOwnership = SleepReminderOwnership()
        UserDefaults.standard.removeObject(forKey: Key.remoteReminderUntil)
        try? await database.write { database in
            try SyncConflict.delete().execute(database)
            try PendingCommand.delete().execute(database)
            try AuthoritativeRecord.delete().execute(database)
            try SleepSession.delete().execute(database)
            try GrowthMeasurement.delete().execute(database)
            try TemperatureReading.delete().execute(database)
            try Child.delete().execute(database)
            try FamilyMember.delete().execute(database)
            try SyncState.delete().execute(database)
            try Family.delete().execute(database)
        }
        isAuthenticated = false
        memberships = nil
        await watchBridge.publishSnapshot()
    }

    private func randomNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SessionError.couldNotCreateNonce
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hashedNonce(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func restoreAuthenticatedFamily(_ authentication: AuthenticationResponse) async throws -> Family.ID? {
        let updatedAt = now
        try await database.write { database in
            for membership in authentication.families {
                let family = Family(id: membership.id, name: membership.name, role: membership.role, updatedAt: updatedAt)
                try Family.upsert { family }.execute(database)
            }
        }
        return authentication.families.first?.id
    }

    private func setPrediction(_ value: SleepForecast?) async {
        forecast = value
        await scheduleLocalReminder()
    }

    private func synchronizeWithRefresh(familyID: Family.ID) async throws -> SleepForecast? {
        let result: SleepForecast?
        do {
            result = try await coordinator.synchronize(familyID: familyID)
        } catch {
            if isPermissionDeniedAPIError(error) {
                try? await refreshAuthentication()
                throw error
            }
            guard isUnauthenticatedAPIError(error) else { throw error }
            try await refreshAuthentication()
            result = try await coordinator.synchronize(familyID: familyID)
        }
        await reconcileLiveActivities()
        // Claim existing local activity tokens before settings can request a remote start.
        await uploadActivityTokens()
        await uploadPushSettings()
        await watchBridge.publishSnapshot()
        return result
    }

    private func synchronizeInBackground(familyID: Family.ID) async -> Bool {
        guard accessToken != nil else { return false }
        do {
            let value = try await synchronizeWithRefresh(familyID: familyID)
            // A background pull for another family must not replace the visible forecast.
            if forecast == nil || value?.childID == forecast?.childID { await setPrediction(value) }
            return true
        } catch {
            return false
        }
    }

    private func synchronizeAllInBackground() async -> Bool {
        guard accessToken != nil else { return false }
        let allowedFamilyIDs = memberships.map { Set($0.map(\.id)) }
        let familyIDs = (try? await database.read { database in
            try Family.select(\.id).fetchAll(database)
        })?.filter { allowedFamilyIDs?.contains($0) ?? true } ?? []
        guard !familyIDs.isEmpty else { return true }
        var success = true
        for familyID in familyIDs where !Task.isCancelled {
            success = await synchronizeInBackground(familyID: familyID) && success
        }
        return success && !Task.isCancelled
    }

    private func hasUnresolvedSyncState() async -> Bool {
        (try? await database.read { database in
            try PendingCommand.fetchCount(database) > 0 || SyncConflict.fetchCount(database) > 0
        }) ?? true
    }

    private func hasUnresolvedSyncState(familyID: Family.ID) async -> Bool {
        (try? await database.read { database in
            try PendingCommand.where { $0.familyID.eq(familyID) }.fetchCount(database) > 0
                || SyncConflict.where { $0.familyID.eq(familyID) }.fetchCount(database) > 0
        }) ?? true
    }

    private func refreshAuthentication() async throws {
        if let refreshTask {
            let authentication = try await refreshTask.value
            save(authentication)
            _ = try await restoreAuthenticatedFamily(authentication)
            await configurePushRegistration()
            await watchBridge.publishSnapshot()
            return
        }
        guard let refreshToken = credentials.value(for: Key.refreshToken) else {
            throw SessionError.notAuthenticated
        }
        let task = Task { try await apiClient.refreshAuth(deviceID, refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        let authentication = try await task.value
        save(authentication)
        _ = try await restoreAuthenticatedFamily(authentication)
        await configurePushRegistration()
        await watchBridge.publishSnapshot()
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            // The UI shows a generic message; keep the cause for diagnosis without exposing it.
            sessionLogger.error("Session operation failed: \(String(describing: error), privacy: .private)")
            errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
        }
        await watchBridge.publishSnapshot()
    }
}

enum SessionError: Error {
    case invalidAppleCredential
    case missingAppleNonce
    case couldNotCreateNonce
    case notAuthenticated
    case unsyncedChanges
    case activeSleep
}

extension SessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsyncedChanges: String(localized: LocalizedStringResource("locSyncOrResolveThisFamilySPendingChangesBeforeLeavingOrDeletingIt", defaultValue: "Sync or resolve this family’s pending changes before leaving or deleting it.", comment: "Message in SessionStore: Sync or resolve this family’s pending changes before leaving or deleting it."))
        case .activeSleep: String(localized: LocalizedStringResource("locEndThisBabySActiveSleepBeforeDeletingTheirRecords", defaultValue: "End this baby’s active sleep before deleting their records.", comment: "Message in SessionStore: End this baby’s active sleep before deleting their records."))
        case .notAuthenticated: String(localized: LocalizedStringResource("locSignInToManageThisFamily", defaultValue: "Sign in to manage this family.", comment: "Message in SessionStore: Sign in to manage this family."))
        case .invalidAppleCredential: String(localized: LocalizedStringResource("locYourAppleSignInHasExpired", defaultValue: "Your Apple sign in has expired.", comment: "Message in SessionStore: Your Apple sign in has expired."))
        case .missingAppleNonce, .couldNotCreateNonce: String(localized: LocalizedStringResource("locCouldNotStartAppleSignInTryAgain", defaultValue: "Could not start Apple sign in. Try again.", comment: "Message in SessionStore: Could not start Apple sign in. Try again."))
        }
    }
}
