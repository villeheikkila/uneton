import ActivityKit
import AuthenticationServices
import CryptoKit
import Dependencies
import Foundation
import Observation
import SQLiteData
import UnetonActivity
import UnetonCore

@MainActor
@Observable
final class SessionStore {
    @ObservationIgnored @Dependency(\.apiClient) private var apiClient
    @ObservationIgnored @Dependency(\.defaultDatabase) private var database
    @ObservationIgnored @Dependency(\.date.now) private var now
    @ObservationIgnored @Dependency(\.uuid) private var uuid

    private enum Key {
        static let accessToken = "session.accessToken"
        static let refreshToken = "session.refreshToken"
        static let deviceID = "session.deviceID"
        static let appleUserID = "session.appleUserID"
        static let notificationsEnabled = "push.notificationsEnabled"
        static let liveActivitiesEnabled = "push.liveActivitiesEnabled"
        static let reminderLeadMinutes = "push.reminderLeadMinutes"
    }

    private let credentials = CredentialStore()
    private let appleCredentialMonitor = AppleCredentialMonitor()
    private let liveActivities = LiveActivityController()
    private let reminders = ReminderController()

    var isWorking = false
    var errorMessage: String?
    var forecast: SleepForecast?
    var prediction: SleepPrediction? { forecast?.nextSleepEstimate }
    var pendingInviteURL: URL?
    var notificationsEnabled: Bool
    var liveActivitiesEnabled: Bool
    var reminderLeadMinutes: Int

    private(set) var deviceID: UUID
    private var coordinator: SyncCoordinator
    private var refreshTask: Task<AuthenticationResponse, Error>?
    private var pendingAppleNonce: String?
    @ObservationIgnored private var watchBridge: PhoneWatchBridge!
    @ObservationIgnored private var credentialRevocationTask: Task<Void, Never>?
    @ObservationIgnored private var apnsTokenTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityTokenTask: Task<Void, Never>?
    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private var pushToStartToken: String?
    @ObservationIgnored private var activityTokens: [UUID: String] = [:]

    init() {
        let defaults = UserDefaults.standard
        let deviceID: UUID
        if let stored = defaults.string(forKey: Key.deviceID).flatMap(UUID.init(uuidString:)) {
            deviceID = stored
        } else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString, forKey: Key.deviceID)
        }
        self.deviceID = deviceID
        self.notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        self.liveActivitiesEnabled = defaults.object(forKey: Key.liveActivitiesEnabled) as? Bool ?? true
        self.reminderLeadMinutes = defaults.object(forKey: Key.reminderLeadMinutes) as? Int ?? 15
        self.coordinator = SyncCoordinator(
            deviceID: deviceID,
            accessToken: { CredentialStore().value(for: Key.accessToken) }
        )
        self.watchBridge = PhoneWatchBridge(store: self)
        self.credentialRevocationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            ) {
                guard !Task.isCancelled else { return }
                await self?.validateAppleCredential(force: true)
            }
        }
        self.apnsTokenTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .unetonAPNSTokenChanged) {
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
            errorMessage = error.localizedDescription
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
            errorMessage = "Uneton could not sync your changes. Connect to the internet and try again before signing out."
            return false
        }
        guard !(await hasUnresolvedSyncState()) else {
            errorMessage = "Resolve or discard sync conflicts before signing out."
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
            errorMessage = error.localizedDescription
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
        do {
            try await apiClient.deleteAccount(accessToken)
            await clearLocalSession()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startSleep(familyID: Family.ID, childID: Child.ID, childName: String = "Child", startedAt: Date = .now) async {
        await perform {
            let sessionID = try await coordinator.startSleep(familyID: familyID, childID: childID, startedAt: startedAt)
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

    func endSleep(familyID: Family.ID, sessionID: SleepSession.ID, endedAt: Date = .now) async {
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
        while !Task.isCancelled {
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
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    func handle(url: URL) async {
        if url.scheme == "uneton", url.host == "invite" {
            guard let token = url.pathComponents.dropFirst().first, let accessToken else {
                pendingInviteURL = url
                return
            }
            await perform {
                let accepted = try await apiClient.acceptInvite(token, accessToken)
                let acceptedAt = now
                try await database.write { database in
                    try Family.upsert {
                        Family(id: accepted.familyID, name: "Shared family", role: accepted.role, updatedAt: acceptedAt)
                    }.execute(database)
                }
                await setPrediction(try await synchronizeWithRefresh(familyID: accepted.familyID))
            }
            return
        }
        guard url.scheme == "uneton", url.host == "sleep", url.path == "/end",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let familyValue = components.queryItems?.first(where: { $0.name == "familyID" })?.value,
              let sessionValue = components.queryItems?.first(where: { $0.name == "sessionID" })?.value,
              let familyID = UUID(uuidString: familyValue),
              let sessionID = UUID(uuidString: sessionValue)
        else { return }
        await endSleep(familyID: familyID, sessionID: sessionID)
    }

    func acceptPendingInviteIfPossible() async {
        guard let pendingInviteURL else { return }
        self.pendingInviteURL = nil
        await handle(url: pendingInviteURL)
    }

    func createChildFamily(childName: String, birthDate: Date) async {
        await perform {
            try await createInitialFamily(childName: childName, birthDate: birthDate)
        }
    }

    func createInvite(familyID: UUID) async -> URL? {
        guard let accessToken else { return nil }
        do {
            let invite = try await apiClient.createInvite(familyID, accessToken)
            return URL(string: "uneton://invite/\(invite.token)")
        } catch {
            errorMessage = error.localizedDescription
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
        await reminders.schedule(forecast?.nextSleepIsProvisional == true ? nil : forecast?.nextSleepEstimate, leadMinutes: minutes)
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

    func handleWatchAction(_ action: String) async -> (isSleeping: Bool, startedAt: Date?, error: String?) {
        do {
            let context = try await database.read { database -> (Family, Child, SleepSession?)? in
                guard let family = try Family.order(by: { $0.updatedAt.desc() }).fetchOne(database),
                      let child = try Child.where({ $0.familyID.eq(family.id) }).fetchOne(database)
                else { return nil }
                let active = try SleepSession
                    .where { $0.childID.eq(child.id) && $0.endedAt.is(nil) && $0.deletedAt.is(nil) }
                    .order { $0.startedAt.desc() }
                    .fetchOne(database)
                return (family, child, active)
            }
            guard let (family, child, active) = context else {
                return (false, nil, "Set up Uneton on iPhone first")
            }
            if action == "endSleep", let active {
                await endSleep(familyID: family.id, sessionID: active.id)
            } else if action == "startSleep", active == nil {
                await startSleep(familyID: family.id, childID: child.id, childName: child.nickname)
            }
            let current = try await database.read { database in
                try SleepSession
                    .where { $0.childID.eq(child.id) && $0.endedAt.is(nil) && $0.deletedAt.is(nil) }
                    .order { $0.startedAt.desc() }
                    .fetchOne(database)
            }
            return (current != nil, current?.startedAt, errorMessage)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    private func createInitialFamily(childName: String, birthDate: Date) async throws {
        guard let accessToken else { throw SessionError.notAuthenticated }
        let familyID = try await database.read { database in
            try Family.order(by: { $0.updatedAt.desc() }).fetchOne(database)?.id
        } ?? uuid()
        let family = Family(id: familyID, name: "Our family", role: "owner", updatedAt: now)
        try await database.write { database in
            try Family.upsert { family }.execute(database)
        }
        // Persist the client-generated identity before the network request. If the
        // response is lost, onboarding retries the same idempotent server operation.
        try await apiClient.createFamily(familyID, "Our family", accessToken)
        _ = try await coordinator.createChild(familyID: familyID, nickname: childName, birthDate: birthDate)
        await reminders.requestAuthorization()
        await setPrediction(try await synchronizeWithRefresh(familyID: familyID))
    }

    private func save(_ authentication: AuthenticationResponse) {
        credentials.set(authentication.accessToken, for: Key.accessToken)
        credentials.set(authentication.refreshToken, for: Key.refreshToken)
        UserDefaults.standard.set(authentication.deviceID.uuidString, forKey: Key.deviceID)
    }

    private func configurePushRegistration() async {
        if notificationsEnabled { await PushRegistrationController.requestAuthorization() }
        await uploadPushSettings()
        for (sessionID, token) in activityTokens { await uploadActivityToken(sessionID: sessionID, token: token) }
    }

    private func receivedAPNSToken(_ token: String) async {
        apnsToken = token
        await uploadPushSettings()
    }

    private func receivedPushToStartToken(_ token: String) async {
        pushToStartToken = token
        await uploadPushSettings()
    }

    private func receivedActivityToken(sessionID: UUID, token: String) async {
        activityTokens[sessionID] = token
        await uploadActivityToken(sessionID: sessionID, token: token)
    }

    private func uploadPushSettings() async {
        guard let accessToken else { return }
        let settings = DevicePushSettings(notificationsEnabled: notificationsEnabled, liveActivitiesEnabled: liveActivitiesEnabled, reminderLeadMinutes: reminderLeadMinutes)
        _ = try? await apiClient.updateDevicePushSettings(apnsToken, pushToStartToken, PushRegistrationController.environment, settings, accessToken)
    }

    private func uploadActivityToken(sessionID: UUID, token: String) async {
        guard let accessToken else { return }
        try? await apiClient.registerLiveActivity(sessionID, token, PushRegistrationController.environment, accessToken)
    }

    private func clearLocalSession() async {
        for activity in Activity<SleepActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activityTokens.removeAll()
        credentials.removeValue(for: Key.accessToken)
        credentials.removeValue(for: Key.refreshToken)
        credentials.removeValue(for: Key.appleUserID)
        forecast = nil
        await reminders.schedule(nil, leadMinutes: reminderLeadMinutes)
        try? await database.write { database in
            try SyncConflict.delete().execute(database)
            try PendingCommand.delete().execute(database)
            try AuthoritativeRecord.delete().execute(database)
            try SleepSession.delete().execute(database)
            try GrowthMeasurement.delete().execute(database)
            try Child.delete().execute(database)
            try FamilyMember.delete().execute(database)
            try SyncState.delete().execute(database)
            try Family.delete().execute(database)
        }
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
        guard let membership = authentication.families.first else { return nil }
        let family = Family(id: membership.id, name: membership.name, role: membership.role, updatedAt: now)
        try await database.write { database in
            try Family.upsert { family }.execute(database)
        }
        return family.id
    }

    private func setPrediction(_ value: SleepForecast?) async {
        forecast = value
        await reminders.schedule(value?.nextSleepIsProvisional == true ? nil : value?.nextSleepEstimate, leadMinutes: reminderLeadMinutes)
    }

    private func synchronizeWithRefresh(familyID: UUID) async throws -> SleepForecast? {
        do {
            return try await coordinator.synchronize(familyID: familyID)
        } catch {
            guard isUnauthenticatedAPIError(error) else { throw error }
            try await refreshAuthentication()
            return try await coordinator.synchronize(familyID: familyID)
        }
    }

    private func synchronizeInBackground(familyID: UUID) async -> Bool {
        guard accessToken != nil else { return false }
        do {
            _ = try await synchronizeWithRefresh(familyID: familyID)
            return true
        } catch {
            return false
        }
    }

    private func synchronizeAllInBackground() async -> Bool {
        guard accessToken != nil else { return false }
        let familyIDs = (try? await database.read { database in
            try Family.select(\.id).fetchAll(database)
        }) ?? []
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

    private func refreshAuthentication() async throws {
        if let refreshTask {
            save(try await refreshTask.value)
            await configurePushRegistration()
            return
        }
        guard let refreshToken = credentials.value(for: Key.refreshToken) else {
            throw SessionError.notAuthenticated
        }
        let task = Task { try await apiClient.refreshAuth(deviceID, refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        save(try await task.value)
        await configurePushRegistration()
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum SessionError: Error {
    case invalidAppleCredential
    case missingAppleNonce
    case couldNotCreateNonce
    case notAuthenticated
}
