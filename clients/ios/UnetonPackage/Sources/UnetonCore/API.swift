import Connect
import Dependencies
import Foundation
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
  public var id: UUID
  public var kind: String
  public var expectedRevision: Int?
  public var payload: JSONValue

  public init(id: UUID, kind: String, expectedRevision: Int? = nil, payload: JSONValue) {
    self.id = id
    self.kind = kind
    self.expectedRevision = expectedRevision
    self.payload = payload
  }
}

public struct SyncRequest: Codable, Equatable, Sendable {
  public var cursor: Int64
  public var generation: String
  public var deviceID: UUID
  public var commands: [APICommand]
  public var limit: Int

  public init(cursor: Int64, generation: String = "", deviceID: UUID, commands: [APICommand], limit: Int = 500) {
    self.cursor = cursor
    self.generation = generation
    self.deviceID = deviceID
    self.commands = commands
    self.limit = limit
  }
}

public struct APICommandResult: Codable, Equatable, Sendable {
  public var id: UUID
  public var status: String
  public var error: String?
  public var entityID: UUID?
  public var payload: JSONValue?
}

public struct SyncEvent: Codable, Equatable, Sendable {
  public var cursor: Int64
  public var entityType: String
  public var entityID: UUID
  public var operation: String
  public var revision: Int
  public var payload: JSONValue
  public var createdAt: Date
}

public struct SnapshotEntity: Codable, Equatable, Sendable {
  public var entityType: String
  public var entityID: UUID
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

  public init(targetAt: Date, rangeStartAt: Date, rangeEndAt: Date, confidence: String, explanation: String, algorithmVersion: Int, kind: String = "offline", sampleCount: Int = 0) {
    self.targetAt = targetAt
    self.rangeStartAt = rangeStartAt
    self.rangeEndAt = rangeEndAt
    self.confidence = confidence
    self.explanation = explanation
    self.algorithmVersion = algorithmVersion
    self.kind = kind
    self.sampleCount = sampleCount
  }
}

public struct SleepForecast: Codable, Equatable, Sendable {
  public var childID: UUID?
  public var activeSleepID: UUID?
  public var wakeEstimate: SleepPrediction?
  public var nextSleepEstimate: SleepPrediction?
  public var nextSleepIsProvisional: Bool

  public init(childID: UUID? = nil, activeSleepID: UUID? = nil, wakeEstimate: SleepPrediction? = nil, nextSleepEstimate: SleepPrediction? = nil, nextSleepIsProvisional: Bool = false) {
    self.childID = childID
    self.activeSleepID = activeSleepID
    self.wakeEstimate = wakeEstimate
    self.nextSleepEstimate = nextSleepEstimate
    self.nextSleepIsProvisional = nextSleepIsProvisional
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
}

public struct AuthenticationResponse: Codable, Equatable, Sendable {
  public var userID: UUID
  public var deviceID: UUID
  public var accessToken: String
  public var refreshToken: String
  public var families: [AuthenticatedFamily]

  public init(userID: UUID, deviceID: UUID, accessToken: String, refreshToken: String, families: [AuthenticatedFamily] = []) {
    self.userID = userID
    self.deviceID = deviceID
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.families = families
  }
}

public struct AuthenticatedFamily: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var role: String

  public init(id: UUID, name: String, role: String) {
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
  public var familyID: UUID
  public var role: String
}

public struct DevicePushSettings: Codable, Equatable, Sendable {
  public var notificationsEnabled: Bool
  public var liveActivitiesEnabled: Bool
  public var reminderLeadMinutes: Int

  public init(notificationsEnabled: Bool = true, liveActivitiesEnabled: Bool = true, reminderLeadMinutes: Int = 15) {
    self.notificationsEnabled = notificationsEnabled
    self.liveActivitiesEnabled = liveActivitiesEnabled
    self.reminderLeadMinutes = reminderLeadMinutes
  }
}

public struct APIClient: Sendable {
  public var developmentAuth: @Sendable (_ name: String, _ deviceID: UUID) async throws -> AuthenticationResponse
  public var appleAuth: @Sendable (_ authorizationCode: String, _ nonce: String, _ displayName: String, _ deviceID: UUID) async throws -> AuthenticationResponse
  public var refreshAuth: @Sendable (_ deviceID: UUID, _ refreshToken: String) async throws -> AuthenticationResponse
  public var signOut: @Sendable (_ accessToken: String) async throws -> Void
  public var deleteAccount: @Sendable (_ accessToken: String) async throws -> Void
  public var updateDevicePushSettings: @Sendable (_ apnsToken: String?, _ pushToStartToken: String?, _ environment: String, _ settings: DevicePushSettings, _ accessToken: String) async throws -> DevicePushSettings
  public var registerLiveActivity: @Sendable (_ sessionID: UUID, _ pushToken: String, _ environment: String, _ accessToken: String) async throws -> Void
  public var createFamily: @Sendable (_ id: UUID, _ name: String, _ accessToken: String) async throws -> Void
  public var createInvite: @Sendable (_ familyID: UUID, _ accessToken: String) async throws -> FamilyInvite
  public var acceptInvite: @Sendable (_ token: String, _ accessToken: String) async throws -> AcceptedInvite
  public var waitForChange: @Sendable (_ familyID: UUID, _ afterCursor: Int64, _ generation: String, _ accessToken: String) async throws -> Void
  public var sync: @Sendable (_ familyID: UUID, _ accessToken: String, _ request: SyncRequest) async throws -> SyncResponse

  public init(
    developmentAuth: @escaping @Sendable (String, UUID) async throws -> AuthenticationResponse,
    appleAuth: @escaping @Sendable (String, String, String, UUID) async throws -> AuthenticationResponse,
    refreshAuth: @escaping @Sendable (UUID, String) async throws -> AuthenticationResponse,
    signOut: @escaping @Sendable (String) async throws -> Void,
    deleteAccount: @escaping @Sendable (String) async throws -> Void,
    updateDevicePushSettings: @escaping @Sendable (String?, String?, String, DevicePushSettings, String) async throws -> DevicePushSettings,
    registerLiveActivity: @escaping @Sendable (UUID, String, String, String) async throws -> Void,
    createFamily: @escaping @Sendable (UUID, String, String) async throws -> Void,
    createInvite: @escaping @Sendable (UUID, String) async throws -> FamilyInvite,
    acceptInvite: @escaping @Sendable (String, String) async throws -> AcceptedInvite,
    waitForChange: @escaping @Sendable (UUID, Int64, String, String) async throws -> Void,
    sync: @escaping @Sendable (UUID, String, SyncRequest) async throws -> SyncResponse
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
    self.waitForChange = waitForChange
    self.sync = sync
  }
}

extension APIClient: TestDependencyKey {
  public static var testValue: APIClient {
    APIClient(
      developmentAuth: { _, deviceID in AuthenticationResponse(userID: UUID(0), deviceID: deviceID, accessToken: "test", refreshToken: "test") },
      appleAuth: { _, _, _, deviceID in AuthenticationResponse(userID: UUID(0), deviceID: deviceID, accessToken: "test", refreshToken: "test") },
      refreshAuth: { deviceID, _ in AuthenticationResponse(userID: UUID(0), deviceID: deviceID, accessToken: "test", refreshToken: "test") },
      signOut: { _ in },
      deleteAccount: { _ in },
      updateDevicePushSettings: { _, _, _, settings, _ in settings },
      registerLiveActivity: { _, _, _, _ in },
      createFamily: { _, _, _ in },
      createInvite: { _, _ in FamilyInvite(token: "invite", expiresAt: .distantFuture) },
      acceptInvite: { _, _ in AcceptedInvite(familyID: UUID(0), role: "caregiver") },
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
        let response = try await generated.updateDevicePushSettings(request: request, headers: authorization(token)).result.get()
        return DevicePushSettings(notificationsEnabled: response.settings.notificationsEnabled, liveActivitiesEnabled: response.settings.liveActivitiesEnabled, reminderLeadMinutes: Int(response.settings.reminderLeadMinutes))
      },
      registerLiveActivity: { sessionID, pushToken, environment, token in
        var request = Uneton_V1_RegisterLiveActivityRequest()
        request.sessionID = sessionID.uuidString
        request.pushToken = pushToken
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
        guard let familyID = UUID(uuidString: response.familyID) else { throw APIError.invalidResponse("Invalid family identifier") }
        return AcceptedInvite(familyID: familyID, role: response.role)
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

private func authorization(_ token: String) -> Connect.Headers { ["Authorization": ["Bearer \(token)"]] }

private func authentication(_ value: Uneton_V1_AuthenticationResponse) throws -> AuthenticationResponse {
  guard let userID = UUID(uuidString: value.userID), let deviceID = UUID(uuidString: value.deviceID) else {
    throw APIError.invalidResponse("Invalid authentication identifiers")
  }
  let families = try value.families.map { family in
    guard let id = UUID(uuidString: family.id) else { throw APIError.invalidResponse("Invalid family identifier") }
    return AuthenticatedFamily(id: id, name: family.name, role: family.role)
  }
  return AuthenticationResponse(
    userID: userID, deviceID: deviceID, accessToken: value.accessToken,
    refreshToken: value.refreshToken, families: families
  )
}

private func protoSyncRequest(familyID: UUID, request: SyncRequest) throws -> Uneton_V1_SyncRequest {
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
  case "updateChild", "updatePredictionSettings":
    var payload = Uneton_V1_UpdateChild()
    payload.child = try childInput(JSONDecoder.uneton.decode(ChildCommandPayload.self, from: data))
    result.payload = .updateChild(payload)
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
    let value = try JSONDecoder.uneton.decode(DeleteCommandPayload.self, from: data)
    var payload = Uneton_V1_DeleteSleep()
    payload.id = value.id.uuidString
    result.payload = .deleteSleep(payload)
  case "upsertGrowthMeasurement":
    var payload = Uneton_V1_UpsertGrowthMeasurement()
    payload.measurement = try growthMeasurementInput(JSONDecoder.uneton.decode(GrowthMeasurementCommandPayload.self, from: data))
    result.payload = .upsertGrowthMeasurement(payload)
  case "deleteGrowthMeasurement":
    let value = try JSONDecoder.uneton.decode(DeleteCommandPayload.self, from: data)
    var payload = Uneton_V1_DeleteGrowthMeasurement()
    payload.id = value.id.uuidString
    result.payload = .deleteGrowthMeasurement(payload)
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

private func syncResponse(_ value: Uneton_V1_SyncResponse) throws -> SyncResponse {
  SyncResponse(
    commandResults: try value.commandResults.map { item in
      guard let id = UUID(uuidString: item.id) else { throw APIError.invalidResponse("Invalid command identifier") }
      return APICommandResult(
        id: id,
        status: item.status == .accepted ? "accepted" : "rejected",
        error: item.error.isEmpty ? nil : item.error,
        entityID: UUID(uuidString: item.entityID),
        payload: item.hasEntity ? entityJSON(item.entity) : nil
      )
    },
    events: try value.events.map { item in
      guard let entityID = UUID(uuidString: item.entityID) else { throw APIError.invalidResponse("Invalid event identifier") }
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
    }
  )
}

private func familySnapshot(_ value: Uneton_V1_FamilySnapshot) throws -> FamilySnapshot {
  FamilySnapshot(
    cursor: value.cursor,
    entities: try value.entities.map { item in
      guard let entityID = UUID(uuidString: item.entityID) else {
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
    sampleCount: Int(value.sampleCount)
  )
}

private func sleepForecast(_ value: Uneton_V1_SleepForecast) throws -> SleepForecast {
  guard let childID = UUID(uuidString: value.childID) else { throw APIError.invalidResponse("Invalid forecast child identifier") }
  return SleepForecast(
    childID: childID,
    activeSleepID: value.hasActiveSleepID ? UUID(uuidString: value.activeSleepID) : nil,
    wakeEstimate: value.hasWakeEstimate ? sleepPrediction(value.wakeEstimate) : nil,
    nextSleepEstimate: value.hasNextSleepEstimate ? sleepPrediction(value.nextSleepEstimate) : nil,
    nextSleepIsProvisional: value.nextSleepIsProvisional
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
        ?? ISO8601DateFormatter().date(from: value)
      else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date") }
      return date
    }
    return decoder
  }
}

extension ISO8601DateFormatter {
  fileprivate static var uneton: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}
