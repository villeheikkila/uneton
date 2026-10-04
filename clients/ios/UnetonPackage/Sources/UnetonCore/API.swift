import Connect
import Dependencies
import Foundation
import Tagged
import UnetonAPI
import SwiftProtobuf

public enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Swift.Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Swift.Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .object(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .bool(value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct APICommand: Codable, Equatable, Sendable {
  public var id: PendingCommand.ID
  public var kind: String
  public var expectedRevision: Int?
  public var payload: JSONValue

  public init(id: PendingCommand.ID, kind: String, expectedRevision: Int? = nil, payload: JSONValue) {
    self.id = id
    self.kind = kind
    self.expectedRevision = expectedRevision
    self.payload = payload
  }
}

public struct SyncRequest: Codable, Equatable, Sendable {
  public var cursor: Int64
  public var generation: String
  public var deviceID: DeviceID
  public var commands: [APICommand]
  public var limit: Int

  public init(cursor: Int64, generation: String = "", deviceID: DeviceID, commands: [APICommand], limit: Int = 500) {
    self.cursor = cursor
    self.generation = generation
    self.deviceID = deviceID
    self.commands = commands
    self.limit = limit
  }
}

public struct APICommandResult: Codable, Equatable, Sendable {
  public var id: PendingCommand.ID
  public var status: String
  public var error: String?
  public var entityID: EntityID?
  public var payload: JSONValue?
}

public struct SyncEvent: Codable, Equatable, Sendable {
  public var cursor: Int64
  public var entityType: String
  public var entityID: EntityID
  public var operation: String
  public var revision: Int
  public var payload: JSONValue
  public var createdAt: Date
}

public struct SnapshotEntity: Codable, Equatable, Sendable {
  public var entityType: String
  public var entityID: EntityID
  public var revision: Int
  public var payload: JSONValue
}

public struct FamilySnapshot: Codable, Equatable, Sendable {
  public var cursor: Int64
  public var entities: [SnapshotEntity]
  public var createdAt: Date
}

public struct SleepPrediction: Codable, Equatable, Sendable {
  public var targetAt: Date
  public var rangeStartAt: Date
  public var rangeEndAt: Date
  public var confidence: String
  public var explanation: String
  public var algorithmVersion: Int
  public var kind: String
  public var sampleCount: Int
  /// Probability the range claims to contain the outcome. Optional so cached
  /// forecasts from before algorithm version 4 still decode.
  public var coverage: Double?

  public init(targetAt: Date, rangeStartAt: Date, rangeEndAt: Date, confidence: String, explanation: String, algorithmVersion: Int, kind: String = "offline", sampleCount: Int = 0, coverage: Double? = nil) {
    self.targetAt = targetAt
    self.rangeStartAt = rangeStartAt
    self.rangeEndAt = rangeEndAt
    self.confidence = confidence
    self.explanation = explanation
    self.algorithmVersion = algorithmVersion
    self.kind = kind
    self.sampleCount = sampleCount
    self.coverage = coverage
  }
}

public struct SleepForecast: Codable, Equatable, Sendable {
  public var childID: Child.ID?
  public var activeSleepID: SleepSession.ID?
  public var wakeEstimate: SleepPrediction?
  public var nextSleepEstimate: SleepPrediction?
  public var nextSleepIsProvisional: Bool
  /// Median naps on recent complete days, and whether a nap transition is under way.
  public var typicalNaps: Int?
  public var napTransition: Bool?

  public init(childID: Child.ID? = nil, activeSleepID: SleepSession.ID? = nil, wakeEstimate: SleepPrediction? = nil, nextSleepEstimate: SleepPrediction? = nil, nextSleepIsProvisional: Bool = false, typicalNaps: Int? = nil, napTransition: Bool? = nil) {
    self.childID = childID
    self.activeSleepID = activeSleepID
    self.wakeEstimate = wakeEstimate
    self.nextSleepEstimate = nextSleepEstimate
    self.nextSleepIsProvisional = nextSleepIsProvisional
    self.typicalNaps = typicalNaps
    self.napTransition = napTransition
  }
}

public struct GrowthReferenceBootstrapPoint: Codable, Equatable, Sendable {
  public var reference: String
  public var metric: String
  public var ageMonths: Int
  public var sd: Int
  public var value: Int
}

public struct SyncResponse: Codable, Equatable, Sendable {
  public var commandResults: [APICommandResult]
  public var events: [SyncEvent]
  public var nextCursor: Int64
  public var hasMore: Bool
  public var nextSleepEstimate: SleepPrediction?
  public var serverTime: Date
  public var sleepForecast: SleepForecast? = nil
  public var generation: String = "test-generation"
  public var snapshot: FamilySnapshot? = nil
  public var resetRequired: Bool = false
  public var growthReferencePoints: [GrowthReferenceBootstrapPoint] = []
  /// Server time before which acknowledged commands survive any restorable database.
  public var journalRetentionCutoff: Date? = nil
}

public struct AuthenticationResponse: Codable, Equatable, Sendable {
  public var userID: UserID
  public var deviceID: DeviceID
  public var accessToken: String
  public var refreshToken: String
  public var families: [AuthenticatedFamily]

  public init(userID: UserID, deviceID: DeviceID, accessToken: String, refreshToken: String, families: [AuthenticatedFamily] = []) {
    self.userID = userID
    self.deviceID = deviceID
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.families = families
  }
}

public struct AuthenticatedFamily: Codable, Equatable, Sendable {
  public var id: Family.ID
  public var name: String
  public var role: String

  public init(id: Family.ID, name: String, role: String) {
    self.id = id
    self.name = name
    self.role = role
  }
}

public struct FamilyInvite: Codable, Equatable, Sendable {
  public var token: String
  public var expiresAt: Date
}

public struct AcceptedInvite: Codable, Equatable, Sendable {
  public var familyID: Family.ID
  public var role: String
}

public struct ManagedFamilyMember: Identifiable, Codable, Equatable, Sendable {
  public var id: UserID
  public var displayName: String
  public var role: String
  public var joinedAt: Date

  public init(id: UserID, displayName: String, role: String, joinedAt: Date) {
    self.id = id
    self.displayName = displayName
    self.role = role
    self.joinedAt = joinedAt
  }
}

public struct ManagedFamilyInvite: Identifiable, Codable, Equatable, Sendable {
  public var id: FamilyInviteID
  public var expiresAt: Date
  public var createdAt: Date

  public init(id: FamilyInviteID, expiresAt: Date, createdAt: Date) {
    self.id = id
    self.expiresAt = expiresAt
    self.createdAt = createdAt
  }
}

public struct FamilyManagementSnapshot: Codable, Equatable, Sendable {
  public var familyID: Family.ID
  public var familyName: String
  public var myUserID: UserID
  public var myDisplayName: String
  public var myRole: String
  public var members: [ManagedFamilyMember]
  public var pendingInvites: [ManagedFamilyInvite]

  public init(familyID: Family.ID, familyName: String, myUserID: UserID,
              myDisplayName: String, myRole: String, members: [ManagedFamilyMember],
              pendingInvites: [ManagedFamilyInvite]) {
    self.familyID = familyID
    self.familyName = familyName
    self.myUserID = myUserID
    self.myDisplayName = myDisplayName
    self.myRole = myRole
    self.members = members
    self.pendingInvites = pendingInvites
  }
}

public struct DevicePushSettings: Codable, Equatable, Sendable {
  public var registrationRevision: Int64
  public var notificationsEnabled: Bool
  public var liveActivitiesEnabled: Bool
  public var reminderLeadMinutes: Int
  public var remoteRemindersUntil: Date?
  public var notificationLanguage: String

  public init(notificationsEnabled: Bool = true, liveActivitiesEnabled: Bool = true, reminderLeadMinutes: Int = 15, remoteRemindersUntil: Date? = nil, notificationLanguage: String = "en", registrationRevision: Int64 = 0) {
    self.registrationRevision = registrationRevision
    self.notificationsEnabled = notificationsEnabled
    self.liveActivitiesEnabled = liveActivitiesEnabled
    self.reminderLeadMinutes = reminderLeadMinutes
    self.remoteRemindersUntil = remoteRemindersUntil
    self.notificationLanguage = notificationLanguage
  }
}

public struct APIClient: Sendable {
  public var developmentAuth: @Sendable (_ name: String, _ deviceID: DeviceID) async throws -> AuthenticationResponse
  public var appleAuth: @Sendable (_ authorizationCode: String, _ nonce: String, _ displayName: String, _ deviceID: DeviceID) async throws -> AuthenticationResponse
  public var refreshAuth: @Sendable (_ deviceID: DeviceID, _ refreshToken: String) async throws -> AuthenticationResponse
  public var signOut: @Sendable (_ accessToken: String) async throws -> Void
  public var deleteAccount: @Sendable (_ accessToken: String) async throws -> Void
  public var updateDevicePushSettings: @Sendable (_ apnsToken: String?, _ pushToStartToken: String?, _ environment: String, _ settings: DevicePushSettings, _ accessToken: String) async throws -> DevicePushSettings
  public var registerLiveActivity: @Sendable (_ sessionID: SleepSession.ID, _ pushToken: String, _ environment: String, _ registrationRevision: Int64, _ accessToken: String) async throws -> Void
  public var createFamily: @Sendable (_ id: Family.ID, _ name: String, _ accessToken: String) async throws -> Void
  public var createInvite: @Sendable (_ familyID: Family.ID, _ accessToken: String) async throws -> FamilyInvite
  public var acceptInvite: @Sendable (_ token: String, _ accessToken: String) async throws -> AcceptedInvite
  public var getFamilyManagement: @Sendable (Family.ID, String) async throws -> FamilyManagementSnapshot
  public var updateProfile: @Sendable (String, String) async throws -> String
  public var renameFamily: @Sendable (Family.ID, String, String) async throws -> String
  public var removeFamilyMember: @Sendable (Family.ID, UserID, String) async throws -> Void
  public var leaveFamily: @Sendable (Family.ID, String) async throws -> Void
  public var transferFamilyOwnership: @Sendable (Family.ID, UserID, String) async throws -> Void
  public var revokeInvite: @Sendable (Family.ID, FamilyInviteID, String) async throws -> Void
  public var deleteFamily: @Sendable (Family.ID, String) async throws -> Void
  public var waitForChange: @Sendable (_ familyID: Family.ID, _ afterCursor: Int64, _ generation: String, _ accessToken: String) async throws -> Void
  public var sync: @Sendable (_ familyID: Family.ID, _ accessToken: String, _ request: SyncRequest) async throws -> SyncResponse

  public init(
    developmentAuth: @escaping @Sendable (String, DeviceID) async throws -> AuthenticationResponse,
    appleAuth: @escaping @Sendable (String, String, String, DeviceID) async throws -> AuthenticationResponse,
    refreshAuth: @escaping @Sendable (DeviceID, String) async throws -> AuthenticationResponse,
    signOut: @escaping @Sendable (String) async throws -> Void,
    deleteAccount: @escaping @Sendable (String) async throws -> Void,
    updateDevicePushSettings: @escaping @Sendable (String?, String?, String, DevicePushSettings, String) async throws -> DevicePushSettings,
    registerLiveActivity: @escaping @Sendable (SleepSession.ID, String, String, Int64, String) async throws -> Void,
    createFamily: @escaping @Sendable (Family.ID, String, String) async throws -> Void,
    createInvite: @escaping @Sendable (Family.ID, String) async throws -> FamilyInvite,
    acceptInvite: @escaping @Sendable (String, String) async throws -> AcceptedInvite,
    getFamilyManagement: @escaping @Sendable (Family.ID, String) async throws -> FamilyManagementSnapshot,
    updateProfile: @escaping @Sendable (String, String) async throws -> String,
    renameFamily: @escaping @Sendable (Family.ID, String, String) async throws -> String,
    removeFamilyMember: @escaping @Sendable (Family.ID, UserID, String) async throws -> Void,
    leaveFamily: @escaping @Sendable (Family.ID, String) async throws -> Void,
    transferFamilyOwnership: @escaping @Sendable (Family.ID, UserID, String) async throws -> Void,
    revokeInvite: @escaping @Sendable (Family.ID, FamilyInviteID, String) async throws -> Void,
    deleteFamily: @escaping @Sendable (Family.ID, String) async throws -> Void,
    waitForChange: @escaping @Sendable (Family.ID, Int64, String, String) async throws -> Void,
    sync: @escaping @Sendable (Family.ID, String, SyncRequest) async throws -> SyncResponse
  ) {
    self.developmentAuth = developmentAuth
    self.appleAuth = appleAuth
    self.refreshAuth = refreshAuth
    self.signOut = signOut
    self.deleteAccount = deleteAccount
    self.updateDevicePushSettings = updateDevicePushSettings
    self.registerLiveActivity = registerLiveActivity
    self.createFamily = createFamily
    self.createInvite = createInvite
    self.acceptInvite = acceptInvite
    self.getFamilyManagement = getFamilyManagement
    self.updateProfile = updateProfile
    self.renameFamily = renameFamily
    self.removeFamilyMember = removeFamilyMember
    self.leaveFamily = leaveFamily
    self.transferFamilyOwnership = transferFamilyOwnership
    self.revokeInvite = revokeInvite
    self.deleteFamily = deleteFamily
    self.waitForChange = waitForChange
    self.sync = sync
  }
}

extension APIClient: TestDependencyKey {
  public static var testValue: APIClient {
    APIClient(
      developmentAuth: { _, deviceID in AuthenticationResponse(userID: UserID(rawValue: UUID(0)), deviceID: deviceID, accessToken: "test", refreshToken: "test") },
      appleAuth: { _, _, _, deviceID in AuthenticationResponse(userID: UserID(rawValue: UUID(0)), deviceID: deviceID, accessToken: "test", refreshToken: "test") },
      refreshAuth: { deviceID, _ in AuthenticationResponse(userID: UserID(rawValue: UUID(0)), deviceID: deviceID, accessToken: "test", refreshToken: "test") },
      signOut: { _ in },
      deleteAccount: { _ in },
      updateDevicePushSettings: { _, _, _, settings, _ in settings },
      registerLiveActivity: { _, _, _, _, _ in },
      createFamily: { _, _, _ in },
      createInvite: { _, _ in FamilyInvite(token: "invite", expiresAt: .distantFuture) },
      acceptInvite: { _, _ in AcceptedInvite(familyID: Family.ID(rawValue: UUID(0)), role: "caregiver") },
      getFamilyManagement: { familyID, _ in FamilyManagementSnapshot(familyID: familyID, familyName: "Our family", myUserID: UserID(rawValue: UUID(0)), myDisplayName: "Caregiver", myRole: "owner", members: [], pendingInvites: []) },
      updateProfile: { name, _ in name },
      renameFamily: { _, name, _ in name },
      removeFamilyMember: { _, _, _ in },
      leaveFamily: { _, _ in },
      transferFamilyOwnership: { _, _, _ in },
      revokeInvite: { _, _, _ in },
      deleteFamily: { _, _ in },
      waitForChange: { _, _, _, _ in try await Task.sleep(for: .seconds(60)) },
      sync: { _, _, request in SyncResponse(commandResults: [], events: [], nextCursor: request.cursor, hasMore: false, serverTime: Date(timeIntervalSince1970: 0)) }
    )
  }
}

extension DependencyValues {
  public var apiClient: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
}

extension APIClient {
  public static func live(baseURL: URL, session: URLSession = .shared) -> APIClient {
    let configuration = session.configuration
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 90
    let generated = Uneton_V1_UnetonServiceClient(
      client: ProtocolClient(
        httpClient: URLSessionHTTPClient(configuration: configuration),
        config: ProtocolClientConfig(
          host: baseURL.absoluteString,
          networkProtocol: .connect,
          codec: ProtoCodec(),
          unaryGET: .disabled
        )
      )
    )
    return APIClient(
      developmentAuth: { name, deviceID in
        var request = Uneton_V1_DevelopmentAuthRequest()
        request.name = name
        request.deviceID = deviceID.uuidString
        let response = try await generated.developmentAuth(request: request, headers: [:]).result.get()
        return try authentication(response.authentication)
      },
      appleAuth: { code, nonce, displayName, deviceID in
        var request = Uneton_V1_AppleAuthRequest()
        request.authorizationCode = code
        request.nonce = nonce
        request.displayName = displayName
        request.deviceID = deviceID.uuidString
        let response = try await generated.appleAuth(request: request, headers: [:]).result.get()
        return try authentication(response.authentication)
      },
      refreshAuth: { deviceID, refreshToken in
        var request = Uneton_V1_RefreshAuthRequest()
        request.deviceID = deviceID.uuidString
        request.refreshToken = refreshToken
        let response = try await generated.refreshAuth(request: request, headers: [:]).result.get()
        return try authentication(response.authentication)
      },
      signOut: { token in
        _ = try await generated.signOut(request: Uneton_V1_SignOutRequest(), headers: authorization(token)).result.get()
      },
      deleteAccount: { token in
        _ = try await generated.deleteAccount(request: Uneton_V1_DeleteAccountRequest(), headers: authorization(token)).result.get()
      },
      updateDevicePushSettings: { apnsToken, pushToStartToken, environment, settings, token in
        var request = Uneton_V1_UpdateDevicePushSettingsRequest()
        if let apnsToken { request.apnsToken = apnsToken }
        if let pushToStartToken { request.pushToStartToken = pushToStartToken }
        request.apnsEnvironment = environment
        request.notificationsEnabled = settings.notificationsEnabled
        request.liveActivitiesEnabled = settings.liveActivitiesEnabled
        request.reminderLeadMinutes = Int32(settings.reminderLeadMinutes)
        request.remoteRemindersUntil = Google_Protobuf_Timestamp(date: settings.remoteRemindersUntil ?? Date(timeIntervalSince1970: 0))
        request.notificationLanguage = settings.notificationLanguage
        request.registrationRevision = settings.registrationRevision
        let response = try await generated.updateDevicePushSettings(request: request, headers: authorization(token)).result.get()
        if response.settings.hasRemoteRemindersUntil {
          guard let requestedUntil = settings.remoteRemindersUntil,
            response.settings.remoteRemindersUntil.date <= requestedUntil
          else { throw APIError.invalidResponse("Remote reminder ownership exceeds the requested period") }
        }
        return DevicePushSettings(notificationsEnabled: response.settings.notificationsEnabled, liveActivitiesEnabled: response.settings.liveActivitiesEnabled, reminderLeadMinutes: Int(response.settings.reminderLeadMinutes), remoteRemindersUntil: response.settings.hasRemoteRemindersUntil ? response.settings.remoteRemindersUntil.date : nil, notificationLanguage: response.settings.notificationLanguage)
      },
      registerLiveActivity: { sessionID, pushToken, environment, revision, token in
        var request = Uneton_V1_RegisterLiveActivityRequest()
        request.sessionID = sessionID.uuidString
        request.pushToken = pushToken
        request.registrationRevision = revision
        request.apnsEnvironment = environment
        _ = try await generated.registerLiveActivity(request: request, headers: authorization(token)).result.get()
      },
      createFamily: { id, name, token in
        var request = Uneton_V1_CreateFamilyRequest()
        request.id = id.uuidString
        request.name = name
        _ = try await generated.createFamily(request: request, headers: authorization(token)).result.get()
      },
      createInvite: { familyID, token in
        var request = Uneton_V1_CreateInviteRequest()
        request.familyID = familyID.uuidString
        let response = try await generated.createInvite(request: request, headers: authorization(token)).result.get()
        return FamilyInvite(token: response.token, expiresAt: response.expiresAt.date)
      },
      acceptInvite: { inviteToken, token in
        var request = Uneton_V1_AcceptInviteRequest()
        request.token = inviteToken
        let response = try await generated.acceptInvite(request: request, headers: authorization(token)).result.get()
        guard let familyID = Family.ID(uuidString: response.familyID) else { throw APIError.invalidResponse("Invalid family identifier") }
        return AcceptedInvite(familyID: familyID, role: response.role)
      },
      getFamilyManagement: { familyID, token in
        var request = Uneton_V1_GetFamilyManagementRequest()
        request.familyID = familyID.uuidString
        let response = try await generated.getFamilyManagement(request: request, headers: authorization(token)).result.get()
        guard let responseFamilyID = Family.ID(uuidString: response.familyID), responseFamilyID == familyID,
              let myUserID = UserID(uuidString: response.myUserID) else {
          throw APIError.invalidResponse("Invalid family management identity")
        }
        let members = try response.members.map { member in
          guard let id = UserID(uuidString: member.userID), member.hasJoinedAt else {
            throw APIError.invalidResponse("Invalid caregiver")
          }
          return ManagedFamilyMember(id: id, displayName: member.displayName, role: member.role, joinedAt: member.joinedAt.date)
        }
        let invites = try response.pendingInvites.map { invite in
          guard let id = FamilyInviteID(uuidString: invite.id), invite.hasExpiresAt, invite.hasCreatedAt else {
            throw APIError.invalidResponse("Invalid invitation")
          }
          return ManagedFamilyInvite(id: id, expiresAt: invite.expiresAt.date, createdAt: invite.createdAt.date)
        }
        return FamilyManagementSnapshot(familyID: familyID, familyName: response.familyName,
          myUserID: myUserID, myDisplayName: response.myDisplayName, myRole: response.myRole,
          members: members, pendingInvites: invites)
      },
      updateProfile: { name, token in
        var request = Uneton_V1_UpdateProfileRequest()
        request.displayName = name
        return try await generated.updateProfile(request: request, headers: authorization(token)).result.get().displayName
      },
      renameFamily: { familyID, name, token in
        var request = Uneton_V1_RenameFamilyRequest()
        request.familyID = familyID.uuidString
        request.name = name
        return try await generated.renameFamily(request: request, headers: authorization(token)).result.get().name
      },
      removeFamilyMember: { familyID, userID, token in
        var request = Uneton_V1_RemoveFamilyMemberRequest()
        request.familyID = familyID.uuidString
        request.userID = userID.uuidString
        _ = try await generated.removeFamilyMember(request: request, headers: authorization(token)).result.get()
      },
      leaveFamily: { familyID, token in
        var request = Uneton_V1_LeaveFamilyRequest()
        request.familyID = familyID.uuidString
        _ = try await generated.leaveFamily(request: request, headers: authorization(token)).result.get()
      },
      transferFamilyOwnership: { familyID, userID, token in
        var request = Uneton_V1_TransferFamilyOwnershipRequest()
        request.familyID = familyID.uuidString
        request.userID = userID.uuidString
        _ = try await generated.transferFamilyOwnership(request: request, headers: authorization(token)).result.get()
      },
      revokeInvite: { familyID, inviteID, token in
        var request = Uneton_V1_RevokeInviteRequest()
        request.familyID = familyID.uuidString
        request.inviteID = inviteID.uuidString
        _ = try await generated.revokeInvite(request: request, headers: authorization(token)).result.get()
      },
      deleteFamily: { familyID, token in
        var request = Uneton_V1_DeleteFamilyRequest()
        request.familyID = familyID.uuidString
        _ = try await generated.deleteFamily(request: request, headers: authorization(token)).result.get()
      },
      waitForChange: { familyID, afterCursor, generation, token in
        let stream = generated.watchFamily(headers: authorization(token))
        defer { stream.cancel() }
        var request = Uneton_V1_WatchFamilyRequest()
        request.familyID = familyID.uuidString
        request.afterCursor = afterCursor
        request.generation = generation
        try stream.send(request)
        for await result in stream.results() {
          switch result {
          case let .message(message):
            if message.resetRequired || message.generation != generation || message.cursor > afterCursor { return }
          case let .complete(_, error, _):
            if let error { throw error }
            throw APIError.invalidResponse("Family stream closed")
          case .headers:
            continue
          }
        }
        throw APIError.invalidResponse("Family stream closed")
      },
      sync: { familyID, token, body in
        let request = try protoSyncRequest(familyID: familyID, request: body)
        let response = try await generated.sync(request: request, headers: authorization(token)).result.get()
        return try syncResponse(response)
      }
    )
  }
}

public func isUnauthenticatedAPIError(_ error: any Error) -> Bool {
  (error as? ConnectError)?.code == .unauthenticated
}

public func isPermissionDeniedAPIError(_ error: any Error) -> Bool {
  (error as? ConnectError)?.code == .permissionDenied
}

private func authorization(_ token: String) -> Connect.Headers { ["Authorization": ["Bearer \(token)"]] }

private func authentication(_ value: Uneton_V1_AuthenticationResponse) throws -> AuthenticationResponse {
  guard let userID = UserID(uuidString: value.userID), let deviceID = DeviceID(uuidString: value.deviceID) else {
    throw APIError.invalidResponse("Invalid authentication identifiers")
  }
  let families = try value.families.map { family in
    guard let id = Family.ID(uuidString: family.id) else { throw APIError.invalidResponse("Invalid family identifier") }
    return AuthenticatedFamily(id: id, name: family.name, role: family.role)
  }
  return AuthenticationResponse(
    userID: userID, deviceID: deviceID, accessToken: value.accessToken,
    refreshToken: value.refreshToken, families: families
  )
}

private func protoSyncRequest(familyID: Family.ID, request: SyncRequest) throws -> Uneton_V1_SyncRequest {
  var result = Uneton_V1_SyncRequest()
  result.familyID = familyID.uuidString
  result.cursor = request.cursor
  result.generation = request.generation
  result.limit = Int32(request.limit)
  result.commands = try request.commands.map(protoCommand)
  return result
}

private func protoCommand(_ command: APICommand) throws -> Uneton_V1_Command {
  var result = Uneton_V1_Command()
  result.id = command.id.uuidString
  if let revision = command.expectedRevision { result.expectedRevision = Int64(revision) }
  let data = try JSONEncoder.uneton.encode(command.payload)
  switch command.kind {
  case "createChild":
    var payload = Uneton_V1_CreateChild()
    payload.child = try childInput(JSONDecoder.uneton.decode(ChildCommandPayload.self, from: data))
    result.payload = .createChild(payload)
  case "updateChild":
    var payload = Uneton_V1_UpdateChild()
    payload.child = try childInput(JSONDecoder.uneton.decode(ChildCommandPayload.self, from: data))
    result.payload = .updateChild(payload)
  case "deleteChild":
    let value = try JSONDecoder.uneton.decode(DeleteCommandPayload<Child.ID>.self, from: data)
    var payload = Uneton_V1_DeleteChild()
    payload.id = value.id.uuidString
    result.payload = .deleteChild(payload)
  case "startSleep":
    var payload = Uneton_V1_StartSleep()
    payload.sleep = try sleepInput(JSONDecoder.uneton.decode(SleepCommandPayload.self, from: data))
    result.payload = .startSleep(payload)
  case "endSleep":
    let value = try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: data)
    guard let endedAt = value.endedAt else { throw APIError.invalidResponse("End sleep command has no end time") }
    var payload = Uneton_V1_EndSleep()
    payload.id = value.id.uuidString
    payload.endedAt = .init(date: endedAt)
    payload.endCondition = value.endCondition
    payload.wakeMood = value.wakeMood
    payload.wakeReason = value.wakeReason
    if let intervened = value.caregiverIntervened { payload.caregiverIntervened = intervened }
    result.payload = .endSleep(payload)
  case "upsertSleep":
    var payload = Uneton_V1_UpsertSleep()
    payload.sleep = try sleepInput(JSONDecoder.uneton.decode(SleepCommandPayload.self, from: data))
    result.payload = .upsertSleep(payload)
  case "deleteSleep":
    let value = try JSONDecoder.uneton.decode(DeleteCommandPayload<SleepSession.ID>.self, from: data)
    var payload = Uneton_V1_DeleteSleep()
    payload.id = value.id.uuidString
    result.payload = .deleteSleep(payload)
  case "upsertGrowthMeasurement":
    var payload = Uneton_V1_UpsertGrowthMeasurement()
    payload.measurement = try growthMeasurementInput(JSONDecoder.uneton.decode(GrowthMeasurementCommandPayload.self, from: data))
    result.payload = .upsertGrowthMeasurement(payload)
  case "deleteGrowthMeasurement":
    let value = try JSONDecoder.uneton.decode(DeleteCommandPayload<GrowthMeasurement.ID>.self, from: data)
    var payload = Uneton_V1_DeleteGrowthMeasurement()
    payload.id = value.id.uuidString
    result.payload = .deleteGrowthMeasurement(payload)
  case "upsertTemperatureReading":
    var payload = Uneton_V1_UpsertTemperatureReading()
    payload.reading = try temperatureReadingInput(JSONDecoder.uneton.decode(TemperatureReadingCommandPayload.self, from: data))
    result.payload = .upsertTemperatureReading(payload)
  case "deleteTemperatureReading":
    let value = try JSONDecoder.uneton.decode(DeleteCommandPayload<TemperatureReading.ID>.self, from: data)
    var payload = Uneton_V1_DeleteTemperatureReading()
    payload.id = value.id.uuidString
    result.payload = .deleteTemperatureReading(payload)
  default:
    throw APIError.invalidResponse("Unsupported command \(command.kind)")
  }
  return result
}

private func childInput(_ value: ChildCommandPayload) -> Uneton_V1_ChildInput {
  var result = Uneton_V1_ChildInput()
  result.id = value.id.uuidString
  result.nickname = value.nickname
  result.birthDate = value.birthDate
  result.predictionMode = value.predictionMode
  if let minutes = value.manualIntervalMinutes { result.manualIntervalMinutes = Int32(minutes) }
  result.quietHoursStartMinutes = Int32(value.quietHoursStartMinutes)
  result.quietHoursEndMinutes = Int32(value.quietHoursEndMinutes)
  result.timeZone = value.timeZone
  result.growthReference = value.growthReference
  return result
}

private func sleepInput(_ value: SleepCommandPayload) -> Uneton_V1_SleepInput {
  var result = Uneton_V1_SleepInput()
  result.id = value.id.uuidString
  result.childID = value.childID.uuidString
  result.startedAt = .init(date: value.startedAt)
  if let endedAt = value.endedAt { result.endedAt = .init(date: endedAt) }
  result.source = value.source
  result.startCondition = value.startCondition
  result.sleepLocation = value.sleepLocation
  result.endCondition = value.endCondition
  result.wakeMood = value.wakeMood
  result.wakeReason = value.wakeReason
  if let intervened = value.caregiverIntervened { result.caregiverIntervened = intervened }
  return result
}

private func growthMeasurementInput(_ value: GrowthMeasurementCommandPayload) -> Uneton_V1_GrowthMeasurementInput {
  var result = Uneton_V1_GrowthMeasurementInput()
  result.id = value.id.uuidString
  result.childID = value.childID.uuidString
  result.measuredAt = .init(date: value.measuredAt)
  if let weight = value.weightGrams { result.weightGrams = Int32(weight) }
  if let height = value.heightMillimeters { result.heightMillimeters = Int32(height) }
  result.note = value.note
  return result
}

private func temperatureReadingInput(_ value: TemperatureReadingCommandPayload) -> Uneton_V1_TemperatureReadingInput {
  var result = Uneton_V1_TemperatureReadingInput()
  result.id = value.id.uuidString
  result.childID = value.childID.uuidString
  result.measuredAt = .init(date: value.measuredAt)
  result.centiCelsius = Int32(value.centiCelsius)
  result.note = value.note
  return result
}

private func syncResponse(_ value: Uneton_V1_SyncResponse) throws -> SyncResponse {
  SyncResponse(
    commandResults: try value.commandResults.map { item in
      guard let id = PendingCommand.ID(uuidString: item.id) else { throw APIError.invalidResponse("Invalid command identifier") }
      return APICommandResult(
        id: id,
        status: item.status == .accepted ? "accepted" : "rejected",
        error: item.error.isEmpty ? nil : item.error,
        entityID: EntityID(uuidString: item.entityID),
        payload: item.hasEntity ? entityJSON(item.entity) : nil
      )
    },
    events: try value.events.map { item in
      guard let entityID = EntityID(uuidString: item.entityID) else { throw APIError.invalidResponse("Invalid event identifier") }
      return SyncEvent(
        cursor: item.cursor,
        entityType: entityTypeName(item.entityType),
        entityID: entityID,
        operation: item.operation == .delete ? "delete" : "upsert",
        revision: Int(item.revision),
        payload: entityJSON(item.entity),
        createdAt: item.createdAt.date
      )
    },
    nextCursor: value.nextCursor,
    hasMore: value.hasMore_p,
	  nextSleepEstimate: value.hasNextSleepEstimate ? sleepPrediction(value.nextSleepEstimate) : nil,
	  serverTime: value.serverTime.date,
	  sleepForecast: value.hasSleepForecast ? try sleepForecast(value.sleepForecast) : nil,
    generation: value.generation,
    snapshot: value.hasSnapshot ? try familySnapshot(value.snapshot) : nil,
    resetRequired: value.resetRequired,
    growthReferencePoints: value.growthReferencePoints.map {
      GrowthReferenceBootstrapPoint(reference: $0.reference, metric: $0.metric, ageMonths: Int($0.ageMonths), sd: Int($0.sd), value: Int($0.value))
    },
    journalRetentionCutoff: value.hasJournalRetentionCutoff ? value.journalRetentionCutoff.date : nil
  )
}

private func familySnapshot(_ value: Uneton_V1_FamilySnapshot) throws -> FamilySnapshot {
  FamilySnapshot(
    cursor: value.cursor,
    entities: try value.entities.map { item in
      guard let entityID = EntityID(uuidString: item.entityID) else {
        throw APIError.invalidResponse("Invalid snapshot entity identifier")
      }
      return SnapshotEntity(
        entityType: entityTypeName(item.entityType),
        entityID: entityID,
        revision: Int(item.revision),
        payload: entityJSON(item.entity)
      )
    },
    createdAt: value.createdAt.date
  )
}

private func sleepPrediction(_ value: Uneton_V1_SleepPrediction) -> SleepPrediction {
  SleepPrediction(
    targetAt: value.targetAt.date,
    rangeStartAt: value.rangeStartAt.date,
    rangeEndAt: value.rangeEndAt.date,
    confidence: value.confidence,
    explanation: value.explanation,
    algorithmVersion: Int(value.algorithmVersion),
    kind: value.kind,
    sampleCount: Int(value.sampleCount),
    coverage: value.coverage > 0 ? value.coverage : nil
  )
}

private func sleepForecast(_ value: Uneton_V1_SleepForecast) throws -> SleepForecast {
  guard let childID = Child.ID(uuidString: value.childID) else { throw APIError.invalidResponse("Invalid forecast child identifier") }
  return SleepForecast(
    childID: childID,
    activeSleepID: value.hasActiveSleepID ? SleepSession.ID(uuidString: value.activeSleepID) : nil,
    wakeEstimate: value.hasWakeEstimate ? sleepPrediction(value.wakeEstimate) : nil,
    nextSleepEstimate: value.hasNextSleepEstimate ? sleepPrediction(value.nextSleepEstimate) : nil,
    nextSleepIsProvisional: value.nextSleepIsProvisional,
    typicalNaps: value.typicalNaps > 0 ? Int(value.typicalNaps) : nil,
    napTransition: value.typicalNaps > 0 ? value.napTransition : nil
  )
}

private func entityJSON(_ entity: Uneton_V1_Entity) -> JSONValue {
  switch entity.value {
  case let .child(value):
    var object: [String: JSONValue] = [
      "id": .string(value.id), "familyID": .string(value.familyID), "nickname": .string(value.nickname),
      "birthDate": .string(value.birthDate), "predictionMode": .string(value.predictionMode),
      "quietHoursStartMinutes": .number(Double(value.quietHoursStartMinutes)),
      "quietHoursEndMinutes": .number(Double(value.quietHoursEndMinutes)),
      "timeZone": .string(value.timeZone),
      "growthReference": .string(value.growthReference),
      "revision": .number(Double(value.revision)), "updatedAt": .string(dateString(value.updatedAt.date)),
    ]
    if value.hasManualIntervalMinutes { object["manualIntervalMinutes"] = .number(Double(value.manualIntervalMinutes)) }
    if value.hasDeletedAt { object["deletedAt"] = .string(dateString(value.deletedAt.date)) }
    return .object(object)
  case let .sleepSession(value):
    var object: [String: JSONValue] = [
      "id": .string(value.id), "familyID": .string(value.familyID), "childID": .string(value.childID),
      "startedAt": .string(dateString(value.startedAt.date)), "revision": .number(Double(value.revision)),
      "authorID": .string(value.authorID), "source": .string(value.source),
      "startCondition": .string(value.startCondition), "sleepLocation": .string(value.sleepLocation),
      "endCondition": .string(value.endCondition), "wakeMood": .string(value.wakeMood),
      "wakeReason": .string(value.wakeReason),
      "updatedAt": .string(dateString(value.updatedAt.date)),
    ]
    if value.hasEndedAt { object["endedAt"] = .string(dateString(value.endedAt.date)) }
    if value.hasSupersededByID { object["supersededByID"] = .string(value.supersededByID) }
    if value.hasDeletedAt { object["deletedAt"] = .string(dateString(value.deletedAt.date)) }
    if value.hasCaregiverIntervened { object["caregiverIntervened"] = .bool(value.caregiverIntervened) }
    return .object(object)
  case let .growthMeasurement(value):
    var object: [String: JSONValue] = [
      "id": .string(value.id), "familyID": .string(value.familyID), "childID": .string(value.childID),
      "measuredAt": .string(dateString(value.measuredAt.date)), "note": .string(value.note),
      "revision": .number(Double(value.revision)), "updatedAt": .string(dateString(value.updatedAt.date)),
    ]
    if value.hasWeightGrams { object["weightGrams"] = .number(Double(value.weightGrams)) }
    if value.hasHeightMillimeters { object["heightMillimeters"] = .number(Double(value.heightMillimeters)) }
    if value.hasDeletedAt { object["deletedAt"] = .string(dateString(value.deletedAt.date)) }
    return .object(object)
  case let .temperatureReading(value):
    var object: [String: JSONValue] = [
      "id": .string(value.id), "familyID": .string(value.familyID), "childID": .string(value.childID),
      "measuredAt": .string(dateString(value.measuredAt.date)),
      "centiCelsius": .number(Double(value.centiCelsius)), "note": .string(value.note),
      "revision": .number(Double(value.revision)), "updatedAt": .string(dateString(value.updatedAt.date)),
    ]
    if value.hasDeletedAt { object["deletedAt"] = .string(dateString(value.deletedAt.date)) }
    return .object(object)
  case let .deleted(value):
    return .object(["id": .string(value.id)])
  case nil:
    return .null
  }
}

private func entityTypeName(_ value: Uneton_V1_EntityType) -> String {
  switch value {
  case .child: "child"
  case .growthMeasurement: "growthMeasurement"
  case .temperatureReading: "temperatureReading"
  default: "sleepSession"
  }
}

private func dateString(_ date: Date) -> String { ISO8601DateFormatter.uneton.string(from: date) }

public enum APIError: Error, Equatable {
  case invalidResponse(String)
}

extension JSONEncoder {
  public static var uneton: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(ISO8601DateFormatter.uneton.string(from: date))
    }
    return encoder
  }
}

extension JSONDecoder {
  public static var uneton: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = ISO8601DateFormatter.uneton.date(from: value)
        ?? ISO8601DateFormatter.unetonWholeSeconds.date(from: value)
      else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date") }
      return date
    }
    return decoder
  }
}

extension ISO8601DateFormatter {
  // Creating a formatter costs far more than using one, and every stored
  // payload date passes through here. ISO8601DateFormatter is thread-safe.
  fileprivate nonisolated(unsafe) static let uneton: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  fileprivate nonisolated(unsafe) static let unetonWholeSeconds = ISO8601DateFormatter()
}
