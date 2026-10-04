import Foundation
import Testing
@testable import UnetonCore

struct HuckleberryImportTests {
  @Test func parsesQuotedContextAndUsesSelectedTimeZone() throws {
    let csv = "\u{feff}Type,Start,End,Start Condition,Start Location,End Condition\r\nSleep,2026-01-01 08:00,2026-01-01 09:00,\"Rocked, then held\",On own in bed,\"Woke \"\"happy\"\"\"\r\nFeed,invalid,invalid,,,\r\n"
    let result = try HuckleberryImport.parse(data: Data(csv.utf8), timeZone: TimeZone(identifier: "Europe/Helsinki")!)
    #expect(result.sleeps.count == 1)
    #expect(result.ignoredRows == 1)
    #expect(result.sleeps[0].startCondition == "Rocked, then held")
    #expect(result.sleeps[0].sleepLocation == "crib")
    #expect(result.sleeps[0].endCondition == "Woke \"happy\"")
    #expect(result.sleeps[0].startedAt == ISO8601DateFormatter().date(from: "2026-01-01T06:00:00Z"))
  }

  @Test func explicitOffsetsDeduplicateAndDistinctOverlapsStayIntact() throws {
    let csv = "Type,Start,End\nSleep,2026-01-01T08:00:00+02:00,2026-01-01T09:00:00+02:00\nSleep,2026-01-01T06:00:00Z,2026-01-01T07:00:00Z\nSleep,2026-01-01T06:01:00Z,2026-01-01T07:05:00Z\n"
    let result = try HuckleberryImport.parse(data: Data(csv.utf8), timeZone: .gmt)
    #expect(result.sleeps.count == 2)
    #expect(result.ignoredRows == 1)
    let familyID = Family.ID()
    let childID = Child.ID()
    #expect(result.sleeps[0].sessionID(familyID: familyID, childID: childID)
      != result.sleeps[1].sessionID(familyID: familyID, childID: childID))
    let repeated = try HuckleberryImport.parse(data: Data(csv.utf8), timeZone: .gmt)
    #expect(result.sleeps[0].sessionID(familyID: familyID, childID: childID)
      == repeated.sleeps[0].sessionID(familyID: familyID, childID: childID))
    #expect(result.sleeps[0].sessionID(familyID: familyID, childID: childID)
      != result.sleeps[0].sessionID(familyID: familyID, childID: Child.ID()))
  }

  @Test func rejectsWholeFileOnMalformedSleepOrCSV() {
    for csv in ["Type,Start\n", "Type,Start,End\nSleep,2026-01-01 08:00,\n",
      "Type,Start,End\nSleep,2026-01-01 09:00,2026-01-01 08:00\n",
      "Type,Start,End\nSleep,\"unterminated", "Type,Type,Start,End\n"] {
      #expect(throws: HuckleberryImport.ParseError.self) {
        try HuckleberryImport.parse(data: Data(csv.utf8), timeZone: .gmt)
      }
    }
  }

  @Test func supportsAmericanDatesAndMultilineFields() throws {
    let csv = "Type,Start,End,Start Condition\nSleep,1/2/2026 3:04 PM,1/2/2026 4:04 PM,\"Held\nthen put down\"\n"
    let result = try HuckleberryImport.parse(data: Data(csv.utf8), timeZone: .gmt)
    #expect(result.sleeps[0].startCondition == "Held\nthen put down")
    #expect(result.sleeps[0].startedAt == ISO8601DateFormatter().date(from: "2026-01-02T15:04:00Z"))
  }
}
