import Dependencies
import Foundation
import SQLiteData
@testable import UnetonCore

/// Simulated time shared by every virtual device and pushed to the simulator server.
final class SimulationClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ start: Date) { value = start }

  var now: Date { lock.withLock { value } }

  func set(_ date: Date) {
    lock.withLock { value = max(value, date) }
  }
}

/// SplitMix64: small, seedable, and identical on every platform.
final class SeededRandom: @unchecked Sendable {
  private let lock = NSLock()
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  func next() -> UInt64 {
    lock.withLock {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
  func chance(_ probability: Double) -> Bool { unit() < probability }
  func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
  func minutes(_ range: ClosedRange<Int>) -> TimeInterval { TimeInterval(int(range) * 60) }
  func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
}

/// Control endpoints exposed only by `simulate-family serve`.
struct SimulatorControl: Sendable {
  let baseURL: URL

  func clock() async throws -> Date {
    let (data, _) = try await URLSession.shared.data(from: baseURL.appending(path: "/_sim/clock"))
    let decoded = try JSONDecoder().decode([String: String].self, from: data)
    guard let value = decoded["now"], let date = ISO8601DateFormatter.simulation.date(from: value)
      ?? ISO8601DateFormatter().date(from: value) else { throw SimulationFailure("invalid clock response") }
    return date
  }

  func setClock(_ date: Date) async throws {
    try await post("/_sim/clock", body: ["now": ISO8601DateFormatter.simulation.string(from: date)])
  }

  func restart() async throws { try await post("/_sim/restart", body: [:]) }

  func checkpoint() async throws -> String {
    let data = try await post("/_sim/checkpoint", body: [:])
    let decoded = try JSONDecoder().decode([String: String].self, from: data)
    guard let id = decoded["id"] else { throw SimulationFailure("checkpoint returned no id") }
    return id
  }

  func restore(_ id: String) async throws { try await post("/_sim/restore", body: ["id": id]) }

  @discardableResult
  private func post(_ path: String, body: [String: String]) async throws -> Data {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw SimulationFailure("\(path) failed: \(String(decoding: data, as: UTF8.self))")
    }
    return data
  }
}

struct SimulationFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

struct SimulatedLostResponse: Error {}

extension ISO8601DateFormatter {
  nonisolated(unsafe) static let simulation: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

final class Credentials: @unchecked Sendable {
  private let lock = NSLock()
  private var access: String?
  private var refresh: String?

  var accessToken: String? { lock.withLock { access } }
  var refreshToken: String? { lock.withLock { refresh } }

  func store(_ authentication: AuthenticationResponse) {
    lock.withLock {
      access = authentication.accessToken
      refresh = authentication.refreshToken
    }
  }
}

/// Latency samples grouped by simulated month, so growth over years is visible.
final class Metrics: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [String: [Int: [Double]]] = [:]
  private var counters: [String: Int] = [:]

  func record(_ name: String, month: Int, seconds: Double) {
    lock.withLock { samples[name, default: [:]][month, default: []].append(seconds) }
  }

  func count(_ name: String, by amount: Int = 1) {
    lock.withLock { counters[name, default: 0] += amount }
  }

  func maximum(_ name: String, _ value: Int) {
    lock.withLock { counters[name] = max(counters[name] ?? 0, value) }
  }

  func report() -> String {
    lock.withLock {
      var lines = counters.keys.sorted().map { "\($0): \(counters[$0]!)" }
      for name in samples.keys.sorted() {
        let months = samples[name]!
        for month in months.keys.sorted() where month % 3 == 0 || month == months.keys.max() {
          let values = months[month]!.sorted()
          let p50 = values[values.count / 2] * 1_000
          let p95 = values[min(values.count - 1, Int(Double(values.count) * 0.95))] * 1_000
          lines.append(String(format: "%@ month %2d: n=%d p50=%.1fms p95=%.1fms", name, month, values.count, p50, p95))
        }
      }
      return lines.joined(separator: "\n")
    }
  }
}

/// One caregiver phone: its own SQLite file and a real `SyncCoordinator` talking to the simulator.
final class VirtualDevice {
  let name: String
  let user: String
  let deviceID = DeviceID()
  let path: String
  let credentials = Credentials()
  private let baseURL: URL
  private let clock: SimulationClock
  private let random: SeededRandom
  private let lostResponseRate: Double
  private(set) var coordinator: SyncCoordinator!
  private(set) var database: (any DatabaseWriter)!
  private(set) var api: APIClient!
  var offlineUntil: Date?

  init(name: String, user: String, directory: URL, baseURL: URL, clock: SimulationClock, random: SeededRandom, lostResponseRate: Double) throws {
    self.name = name
    self.user = user
    self.path = directory.appending(path: "\(name).sqlite").path
    self.baseURL = baseURL
    self.clock = clock
    self.random = random
    self.lostResponseRate = lostResponseRate
    try launch()
  }

  /// Reopens the database file and builds a fresh coordinator, as an app relaunch would.
  func launch() throws {
    var api = APIClient.live(baseURL: baseURL)
    let liveSync = api.sync
    let random = random
    let lostResponseRate = lostResponseRate
    api.sync = { familyID, token, request in
      let response = try await liveSync(familyID, token, request)
      // The server committed; the phone never hears back and must retry safely.
      if !request.commands.isEmpty, random.chance(lostResponseRate) { throw SimulatedLostResponse() }
      return response
    }
    self.api = api
    let clock = clock
    let credentials = credentials
    let deviceID = deviceID
    (coordinator, database) = try withDependencies {
      try $0.bootstrapDatabase(path: path)
      $0.apiClient = api
      $0.date = DateGenerator { clock.now }
      $0.uuid = UUIDGenerator { UUID() }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      return (SyncCoordinator(deviceID: deviceID, accessToken: { credentials.accessToken }), database)
    }
  }

  func isOnline(at date: Date) -> Bool { offlineUntil.map { date >= $0 } ?? true }

  @discardableResult
  func signIn() async throws -> AuthenticationResponse {
    let authentication = try await api.developmentAuth(user, deviceID)
    credentials.store(authentication)
    try await database.write { database in
      for membership in authentication.families {
        try Family.upsert { Family(id: membership.id, name: membership.name, role: membership.role, updatedAt: Date()) }
          .execute(database)
      }
    }
    return authentication
  }

  /// Mirrors the app: refresh an expired access token, and sign in again when
  /// the refresh token itself is gone (for example after 30 unused days).
  func synchronize(_ familyID: Family.ID) async throws {
    do {
      _ = try await coordinator.synchronize(familyID: familyID)
    } catch where isUnauthenticatedAPIError(error) {
      try await reauthenticate()
      _ = try await coordinator.synchronize(familyID: familyID)
    }
  }

  func reauthenticate() async throws {
    if let refresh = credentials.refreshToken {
      do {
        credentials.store(try await api.refreshAuth(deviceID, refresh))
        return
      } catch where isUnauthenticatedAPIError(error) {}
    }
    try await signIn()
  }

  func activeSleep(childID: Child.ID) async throws -> SleepSession? {
    try await database.read { database in
      try SleepSession.where { $0.childID.eq(childID) && $0.endedAt.is(nil) && $0.deletedAt.is(nil) && $0.supersededByID.is(nil) }
        .fetchOne(database)
    }
  }

  func recentSleeps(childID: Child.ID, limit: Int) async throws -> [SleepSession] {
    try await database.read { database in
      try SleepSession.where { $0.childID.eq(childID) && $0.deletedAt.is(nil) && $0.supersededByID.is(nil) && !$0.endedAt.is(nil) }
        .order { $0.startedAt.desc() }
        .limit(limit)
        .fetchAll(database)
    }
  }

  func pendingCount() async throws -> Int {
    try await database.read { try PendingCommand.fetchCount($0) }
  }

  func pendingDescriptions() async throws -> [String] {
    try await database.read { database in
      try PendingCommand.order(by: \.sequence).fetchAll(database).map { command in
        let payload = String(decoding: command.payloadJSON, as: UTF8.self)
        return "\(command.kind) expected=\(command.expectedRevision.map(String.init) ?? "nil") deferrals=\(command.deferrals) deferredAt=\(command.deferredAtCursor.map(String.init) ?? "nil") error=\(command.lastError ?? "") payload=\(payload.prefix(160))"
      }
    }
  }

  func conflicts() async throws -> [SyncConflict] {
    try await database.read { try SyncConflict.fetchAll($0) }
  }

  func journalCount() async throws -> Int {
    try await database.read { try AcknowledgedCommand.fetchCount($0) }
  }

  func state(familyID: Family.ID) async throws -> FamilyState {
    try await database.read { database in
      FamilyState(
        children: try Child.where { $0.familyID.eq(familyID) }.fetchAll(database)
          .map { "\($0.id) \($0.nickname) r\($0.revision)" }.sorted(),
        sleeps: try SleepSession.where { $0.familyID.eq(familyID) && $0.deletedAt.is(nil) && $0.supersededByID.is(nil) }
          .fetchAll(database)
          .map { "\($0.id) \($0.childID) \($0.startedAt.timeIntervalSince1970) \($0.endedAt?.timeIntervalSince1970 ?? -1) r\($0.revision)" }
          .sorted(),
        growth: try GrowthMeasurement.where { $0.familyID.eq(familyID) && $0.deletedAt.is(nil) }.fetchAll(database)
          .map { "\($0.id) \($0.weightGrams ?? -1) \($0.heightMillimeters ?? -1) r\($0.revision)" }.sorted(),
        temperatures: try TemperatureReading.where { $0.familyID.eq(familyID) && $0.deletedAt.is(nil) }.fetchAll(database)
          .map { "\($0.id) \($0.centiCelsius) r\($0.revision)" }.sorted()
      )
    }
  }
}

struct FamilyState: Equatable {
  var children: [String]
  var sleeps: [String]
  var growth: [String]
  var temperatures: [String]

  struct Interval: Equatable {
    var start: TimeInterval
    var end: TimeInterval?
  }

  /// Visible sleeps as intervals, ignoring identity: after a restore, which of two
  /// duplicate starts becomes canonical depends on replay order.
  var sleepIntervals: [Interval] {
    sleeps.map { line in
      let fields = line.split(separator: " ")
      let end = Double(fields[3])!
      return Interval(start: Double(fields[2])!, end: end < 0 ? nil : end)
    }.sorted { $0.start < $1.start }
  }

  /// Sleeps in `other` with no visible sleep here starting within `tolerance`.
  /// Ends are not compared: a presented end can be derived (the next sleep's
  /// start) on one side and a caregiver's recorded end on the other.
  func covers(_ other: FamilyState, tolerance: TimeInterval = 15 * 60) -> [Interval] {
    let mine = sleepIntervals
    return other.sleepIntervals.filter { wanted in
      !mine.contains { have in abs(have.start - wanted.start) <= tolerance }
    }
  }

  var identities: [String] {
    (children + sleeps + growth + temperatures).map { String($0.prefix(36)) }.sorted()
  }

  func difference(from other: FamilyState) -> String {
    func diff(_ label: String, _ left: [String], _ right: [String]) -> [String] {
      let l = Set(left), r = Set(right)
      return l.subtracting(r).sorted().map { "\(label) only left: \($0)" } + r.subtracting(l).sorted().map { "\(label) only right: \($0)" }
    }
    return (diff("child", children, other.children) + diff("sleep", sleeps, other.sleeps)
      + diff("growth", growth, other.growth) + diff("temperature", temperatures, other.temperatures))
      .prefix(20).joined(separator: "\n")
  }
}
