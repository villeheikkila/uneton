import Foundation
import Testing
@testable import UnetonCore

/// Drives real `SyncCoordinator` instances through years of family life against
/// `simulate-family serve`. Run with `mise run sim:client`; skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNETON_SIM_URL"] != nil, "set UNETON_SIM_URL (mise run sim:client)"))
struct FamilySimulationTests {
  @Test(.timeLimit(.minutes(120)))
  func yearsOfFamilyLifeConvergeOnEveryDevice() async throws {
    let environment = ProcessInfo.processInfo.environment
    Projection.verifiesIncrementalRefresh = environment["UNETON_SIM_VERIFY_PROJECTION"] == "1"
    let simulation = try await FamilySimulation(
      baseURL: URL(string: environment["UNETON_SIM_URL"]!)!,
      seed: UInt64(environment["UNETON_SIM_SEED"] ?? "1") ?? 1,
      days: Int((Double(environment["UNETON_SIM_YEARS"] ?? "1") ?? 1) * 365),
      lostResponseRate: Double(environment["UNETON_SIM_LOST_RESPONSES"] ?? "0.02") ?? 0.02
    )
    try await simulation.run()
  }
}

final class FamilySimulation {
  private let control: SimulatorControl
  private let clock: SimulationClock
  private let random: SeededRandom
  private let days: Int
  private let directory: URL
  private let metrics = Metrics()
  private let calendar: Calendar
  private let birth: Date
  private var devices: [VirtualDevice] = []
  private var familyID: Family.ID!
  private var childID: Child.ID!
  private var log: [String] = []
  private let baseURL: URL
  private let lostResponseRate: Double

  init(baseURL: URL, seed: UInt64, days: Int, lostResponseRate: Double) async throws {
    self.baseURL = baseURL
    self.control = SimulatorControl(baseURL: baseURL)
    let start = try await control.clock()
    self.clock = SimulationClock(start)
    self.random = SeededRandom(seed: seed)
    self.days = days
    self.lostResponseRate = lostResponseRate
    self.directory = FileManager.default.temporaryDirectory.appending(path: "uneton-sim-\(seed)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
    self.calendar = calendar
    self.birth = calendar.startOfDay(for: start)
  }

  func run() async throws {
    let started = Date()
    try await setUpFamily()
    for day in 0..<days {
      let dayStart = calendar.date(byAdding: .day, value: day, to: birth)!
      do {
        try await simulateDay(day, start: dayStart)
        try await checkConvergence(day: day, freshObserver: day % 30 == 29)
      } catch {
        print(log.suffix(40).joined(separator: "\n"))
        throw SimulationFailure("day \(day): \(error)")
      }
    }
    for device in devices { device.offlineUntil = nil }
    try await checkConvergence(day: days, freshObserver: true)
    for device in devices {
      metrics.maximum("journal rows at end (\(device.name))", try await device.journalCount())
      let size = (try? FileManager.default.attributesOfItem(atPath: device.path)[.size] as? Int) ?? 0
      metrics.maximum("database bytes at end (\(device.name))", size)
    }
    print("""
      === family simulation: \(days) days in \(Int(Date().timeIntervalSince(started))) s ===
      \(metrics.report())
      """)
  }

  // MARK: Family

  private func setUpFamily() async throws {
    let owner = try makeDevice("parent-a-phone", user: "Parent A")
    let partner = try makeDevice("parent-b-phone", user: "Parent B")
    let grandparent = try makeDevice("grandparent-phone", user: "Grandparent")
    var ownerAuth = try await owner.signIn()
    familyID = Family.ID()
    try await owner.api.createFamily(familyID, "Simulated family", ownerAuth.accessToken)
    ownerAuth = try await owner.signIn()
    for device in [partner, grandparent] {
      let auth = try await device.signIn()
      let invite = try await owner.api.createInvite(familyID, ownerAuth.accessToken)
      _ = try await device.api.acceptInvite(invite.token, auth.accessToken)
      try await device.signIn()
    }
    devices = [owner, partner, grandparent]
    childID = try await owner.coordinator.createChild(familyID: familyID, nickname: "Baby", birthDate: birth)
    try await sync(owner)
  }

  private func makeDevice(_ name: String, user: String) throws -> VirtualDevice {
    try VirtualDevice(name: name, user: user, directory: directory, baseURL: baseURL, clock: clock,
      random: random, lostResponseRate: lostResponseRate)
  }

  // MARK: One day

  private enum Action {
    case start(Int), end(Int), growth, temperature, edit
  }

  private func simulateDay(_ day: Int, start dayStart: Date) async throws {
    let months = Double(day) / 30.4
    var plan: [(Date, Action)] = []
    let sleeps = schedule(dayStart: dayStart, months: months)
    for (index, sleep) in sleeps.enumerated() {
      plan.append((sleep.start, .start(index)))
      plan.append((sleep.end, .end(index)))
    }
    if day % (months < 3 ? 7 : 30) == 3 { plan.append((dayStart.addingTimeInterval(11 * 3_600), .growth)) }
    if (day / 60) % 2 == 1, day % 60 < 4 {
      for hour in [8, 14, 20] { plan.append((dayStart.addingTimeInterval(Double(hour) * 3_600 + random.minutes(0...40)), .temperature)) }
    }
    if random.chance(0.15) { plan.append((dayStart.addingTimeInterval(21 * 3_600 + random.minutes(0...90)), .edit)) }
    plan.sort { $0.0 < $1.0 }

    try await applyDailyFaults(day: day, at: dayStart)
    var sessionByIndex: [Int: (VirtualDevice, SleepSession.ID)] = [:]
    for (time, action) in plan {
      try await advance(to: time)
      switch action {
      case let .start(index):
        let device = random.pick(devices)
        if try await device.activeSleep(childID: childID) != nil { continue }
        let sessionID = try await timed("enqueue") {
          try await device.coordinator.startSleep(familyID: self.familyID, childID: self.childID, startedAt: time)
        }
        sessionByIndex[index] = (device, sessionID)
        note("\(device.name) start \(index)")
        try await syncIfOnline(device)
        if random.chance(0.02) {
          // Both parents tap start before either phone hears from the other.
          let other = devices.first { $0 !== device }!
          try await advance(to: time.addingTimeInterval(30))
          if try await other.activeSleep(childID: childID) == nil {
            _ = try await timed("enqueue") {
              try await other.coordinator.startSleep(familyID: self.familyID, childID: self.childID, startedAt: time.addingTimeInterval(20))
            }
            note("\(other.name) duplicate start \(index)")
            try await syncIfOnline(other)
          }
        }
      case let .end(index):
        let sleep = sleeps[index]
        let device = random.chance(0.7) ? (sessionByIndex[index]?.0 ?? random.pick(devices)) : random.pick(devices)
        if let active = try await device.activeSleep(childID: childID) {
          let forgot = random.chance(0.03)
          let end = forgot ? sleep.end.addingTimeInterval(random.minutes(60...180)) : sleep.end
          if forgot { try await advance(to: end) }
          try await timed("enqueue") {
            try await device.coordinator.endSleep(familyID: self.familyID, sessionID: active.id, endedAt: max(end, active.startedAt.addingTimeInterval(60)))
          }
          note("\(device.name) end \(index)\(forgot ? " late" : "")")
          try await syncIfOnline(device)
          if forgot {
            try await advance(to: end.addingTimeInterval(random.minutes(5...30)))
            try await timed("enqueue") {
              try await device.coordinator.upsertSleep(familyID: self.familyID, childID: self.childID, sessionID: active.id,
                startedAt: active.startedAt, endedAt: max(sleep.end, active.startedAt.addingTimeInterval(60)))
            }
            note("\(device.name) corrects end \(index)")
            try await syncIfOnline(device)
          }
        } else {
          // This phone never saw the start; the caregiver logs the sleep by hand.
          try await timed("enqueue") {
            try await device.coordinator.upsertSleep(familyID: self.familyID, childID: self.childID, startedAt: sleep.start, endedAt: sleep.end)
          }
          note("\(device.name) manual log \(index)")
          try await syncIfOnline(device)
        }
      case .growth:
        let device = devices[0]
        let weight = 3_500 + Int(months * 600) + random.int(-150...150)
        let height = 500 + Int(months * 25) + random.int(-10...10)
        try await timed("enqueue") {
          try await device.coordinator.upsertGrowthMeasurement(familyID: self.familyID, childID: self.childID, measuredAt: time,
            weightGrams: min(weight, 100_000), heightMillimeters: min(height, 2_500))
        }
        note("\(device.name) growth")
        try await syncIfOnline(device)
      case .temperature:
        let device = random.pick(devices)
        try await timed("enqueue") {
          try await device.coordinator.upsertTemperatureReading(familyID: self.familyID, childID: self.childID, measuredAt: time,
            centiCelsius: 3_700 + self.random.int(0...180))
        }
        note("\(device.name) temperature")
        try await syncIfOnline(device)
      case .edit:
        let device = random.pick(devices)
        guard let session = try await device.recentSleeps(childID: childID, limit: 6).randomElement(using: &generator) else { continue }
        let shift = random.minutes(-10...10)
        let start = session.startedAt.addingTimeInterval(shift)
        guard let end = session.endedAt, end > start.addingTimeInterval(60) else { continue }
        try await timed("enqueue") {
          try await device.coordinator.upsertSleep(familyID: self.familyID, childID: self.childID, sessionID: session.id, startedAt: start, endedAt: end)
        }
        note("\(device.name) edit \(session.id)")
        try await syncIfOnline(device)
      }
    }
  }

  private lazy var generator = SeededGenerator(random: random)

  private struct PlannedSleep { var start: Date; var end: Date }

  /// Age-driven pattern: frequent short naps early, one long nap by 18 months, fewer night wakings.
  private func schedule(dayStart: Date, months: Double) -> [PlannedSleep] {
    let naps = months < 3 ? 4 : months < 6 ? 3 : months < 15 ? 2 : 1
    let napLength = months < 3 ? 40...90 : months < 15 ? 50...120 : 80...150
    var result: [PlannedSleep] = []
    var cursor = dayStart.addingTimeInterval(7 * 3_600 + random.minutes(0...60))
    for _ in 0..<naps {
      let awake = months < 3 ? 70...110 : months < 9 ? 120...180 : 180...300
      let start = cursor.addingTimeInterval(random.minutes(awake))
      let end = start.addingTimeInterval(random.minutes(napLength))
      if calendar.component(.hour, from: end) >= 19 { break }
      result.append(PlannedSleep(start: start, end: end))
      cursor = end
    }
    // The night belongs to this day; wakings split it into separate sessions.
    var nightStart = dayStart.addingTimeInterval(19 * 3_600 + random.minutes(0...90))
    let morning = calendar.date(byAdding: .day, value: 1, to: dayStart)!.addingTimeInterval(6 * 3_600 + random.minutes(0...75))
    let wakings = months < 4 ? 3 : months < 9 ? 2 : months < 15 ? 1 : (random.chance(0.15) ? 1 : 0)
    for _ in 0..<wakings {
      let remaining = morning.timeIntervalSince(nightStart)
      let end = nightStart.addingTimeInterval(remaining * (0.3 + random.unit() * 0.3))
      result.append(PlannedSleep(start: nightStart, end: end))
      nightStart = end.addingTimeInterval(random.minutes(10...40))
    }
    if morning > nightStart.addingTimeInterval(1_800) { result.append(PlannedSleep(start: nightStart, end: morning)) }
    return result
  }

  // MARK: Faults

  private var lastCheckpoint: (id: String, at: Date)?

  private func applyDailyFaults(day: Int, at dayStart: Date) async throws {
    for device in devices where device.isOnline(at: dayStart) {
      if random.chance(0.003), device !== devices[0] {
        device.offlineUntil = dayStart.addingTimeInterval(35 * 86_400)
        metrics.count("devices left unused for 35 days")
        note("\(device.name) unused for 35 days")
      } else if random.chance(0.04) {
        device.offlineUntil = dayStart.addingTimeInterval(random.minutes(60...(48 * 60)))
        metrics.count("offline stretches")
      }
      if random.chance(0.02) {
        try device.launch()
        metrics.count("app relaunches")
      }
    }
    if random.chance(0.004) {
      try await control.restart()
      metrics.count("server restarts")
      note("server restart")
    }
  }

  private func advance(to time: Date) async throws {
    guard time > clock.now else { return }
    clock.set(time)
    try await control.setClock(time)
  }

  // MARK: Sync

  private func syncIfOnline(_ device: VirtualDevice) async throws {
    guard device.isOnline(at: clock.now) else { return }
    try await sync(device)
  }

  private func sync(_ device: VirtualDevice) async throws {
    do {
      try await timed("sync") { try await device.synchronize(self.familyID) }
    } catch is SimulatedLostResponse {
      metrics.count("lost responses")
    }
  }

  private func checkConvergence(day: Int, freshObserver: Bool) async throws {
    let online = devices.filter { $0.isOnline(at: clock.now) }
    guard !online.isEmpty else { return }
    for _ in 0..<6 {
      for device in online {
        try await sync(device)
        for conflict in try await device.conflicts() {
          // A real caregiver would read the conflict; the simulation keeps the shared version.
          try await device.coordinator.resolveConflict(conflict.id, resolution: random.chance(0.8) ? .keepServer : .keepMine)
          metrics.count("conflicts")
          metrics.count("conflict \(conflict.commandKind): \(conflict.reason)")
          note("\(device.name) conflict \(conflict.commandKind): \(conflict.reason)")
        }
      }
      var settled = true
      for device in online {
        let pending = try await device.pendingCount()
        let conflicts = try await device.conflicts()
        if pending > 0 || !conflicts.isEmpty { settled = false }
      }
      if settled { break }
    }
    for device in online {
      metrics.maximum("max journal rows", try await device.journalCount())
      let pending = try await device.pendingCount()
      guard pending == 0 else {
        let details = try await device.pendingDescriptions().joined(separator: "\n")
        throw SimulationFailure("\(device.name) still has \(pending) pending commands:\n\(details)")
      }
    }
    // Devices synced in turn, so earlier ones may have missed later commits.
    for device in online { try await sync(device) }
    let reference = try await online[0].state(familyID: familyID)
    for device in online.dropFirst() {
      let state = try await device.state(familyID: familyID)
      guard state == reference else {
        throw SimulationFailure("\(device.name) diverged from \(online[0].name):\n\(state.difference(from: reference))")
      }
    }
    if freshObserver {
      let observer = try makeDevice("observer-\(day)", user: "Parent A")
      try await observer.signIn()
      try await timed("fresh device full sync") { try await observer.synchronize(self.familyID) }
      let state = try await observer.state(familyID: familyID)
      guard state == reference else {
        throw SimulationFailure("fresh device disagrees with \(online[0].name):\n\(state.difference(from: reference))")
      }
      metrics.maximum("visible sleeps", reference.sleeps.count)
    }
    try await maybeRestore(day: day, settled: reference, online: online)
  }

  /// Restores the server to this day's checkpoint (always inside the backup window)
  /// and requires every acknowledged entity to come back through journal replay.
  private func maybeRestore(day: Int, settled: FamilyState, online: [VirtualDevice]) async throws {
    if let checkpoint = lastCheckpoint, online.count == devices.count, random.chance(0.02),
       clock.now.timeIntervalSince(checkpoint.at) < 86_400 {
      try await control.restore(checkpoint.id)
      metrics.count("database restores")
      note("server restored to checkpoint from \(checkpoint.at)")
      var replayConflicts: [String] = []
      for _ in 0..<6 {
        for device in devices {
          try await sync(device)
          for conflict in try await device.conflicts() {
            // Restored data was already acknowledged once; the parent wants it back.
            replayConflicts.append("""
              \(device.name) \(conflict.commandKind) \(conflict.entityID): \(conflict.reason) \
              local \(String(decoding: conflict.localPayloadJSON, as: UTF8.self)) \
              server \(conflict.serverPayloadJSON.map { String(decoding: $0, as: UTF8.self) } ?? "none")
              """)
            try await device.coordinator.resolveConflict(conflict.id, resolution: .keepMine)
          }
        }
      }
      for device in devices { try await sync(device) }
      metrics.count("conflicts raised by restore replay", by: replayConflicts.count)
      let restored = try await devices[0].state(familyID: familyID)
      let missing = restored.covers(settled)
      let extra = settled.covers(restored)
      let sameRecords = restored.children == settled.children
        && restored.growth.map({ $0.prefix(36) }) == settled.growth.map({ $0.prefix(36) })
        && restored.temperatures.map({ $0.prefix(36) }) == settled.temperatures.map({ $0.prefix(36) })
      guard missing.isEmpty, extra.isEmpty, sameRecords else {
        var diagnostics: [String] = replayConflicts.map { "replay conflict: \($0)" }
        for device in devices {
          diagnostics.append("\(device.name): pending \(try await device.pendingCount()), journal \(try await device.journalCount())")
        }
        throw SimulationFailure("""
          restore changed the diary:
          missing sleeps \(missing), unexpected sleeps \(extra)
          \(restored.difference(from: settled))
          \(diagnostics.joined(separator: "\n"))
          """)
      }
      if !replayConflicts.isEmpty { note("restore replay conflicts:\n" + replayConflicts.joined(separator: "\n")) }
      if restored != settled { metrics.count("restores that changed record contents") }
    }
    lastCheckpoint = (try await control.checkpoint(), clock.now)
  }

  // MARK: Helpers

  @discardableResult
  private func timed<T>(_ name: String, _ operation: () async throws -> T) async throws -> T {
    let started = Date()
    defer {
      metrics.record(name, month: Int(clock.now.timeIntervalSince(birth) / (30.4 * 86_400)), seconds: Date().timeIntervalSince(started))
    }
    return try await operation()
  }

  private func note(_ line: String) {
    log.append("\(ISO8601DateFormatter.simulation.string(from: clock.now)) \(line)")
    if log.count > 400 { log.removeFirst(200) }
  }
}

struct SeededGenerator: RandomNumberGenerator {
  let random: SeededRandom
  mutating func next() -> UInt64 { random.next() }
}
