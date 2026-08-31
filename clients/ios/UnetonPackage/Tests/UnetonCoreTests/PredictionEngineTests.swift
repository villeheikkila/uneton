import Foundation
import Testing
@testable import UnetonCore

@Suite struct PredictionEngineTests {
  @Test func agePriorAndPersonalization() throws {
    let calendar = Calendar(identifier: .gregorian)
    let birth = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    let wake = try #require(calendar.date(from: DateComponents(year: 2025, month: 7, day: 1, hour: 9)))
    let estimate = try #require(
      PredictionEngine().estimate(
        wokeAt: wake,
        birthDate: birth,
        intervals: Array(repeating: 150 * 60, count: 7),
        manualMinutes: nil,
        calendar: calendar
      )
    )
    #expect(estimate.confidence == "medium")
    #expect(estimate.targetAt == wake.addingTimeInterval(153 * 60))
  }

  @Test func manualIntervalIsExact() throws {
    let wake = Date(timeIntervalSince1970: 1_000)
    let estimate = try #require(
      PredictionEngine().estimate(
        wokeAt: wake,
        birthDate: .distantPast,
        intervals: [],
        manualMinutes: 90
      )
    )
    #expect(estimate.targetAt == wake.addingTimeInterval(90 * 60))
    #expect(estimate.confidence == "manual")
  }
}
