import CryptoKit
import Foundation

/// Only sleep fields are retained; the source export and other activity types stay on-device.
public struct HuckleberryImport: Equatable, Sendable {
  public struct Sleep: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let startCondition: String
    public let sleepLocation: String
    public let endCondition: String

    public func sessionID(familyID: Family.ID, childID: Child.ID) -> SleepSession.ID {
      let identity = "huckleberry|\(familyID.uuidString)|\(childID.uuidString)|\(startedAt.timeIntervalSince1970)|\(endedAt.timeIntervalSince1970)"
      var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
      bytes[6] = (bytes[6] & 0x0f) | 0x50
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      return SleepSession.ID(rawValue: UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])))
    }
  }

  public let sleeps: [Sleep]
  public let ignoredRows: Int
  public enum ParseError: Error { case invalidFile, invalidRow(Int), tooLarge }
  public static let maximumBytes = 10 * 1_024 * 1_024

  public static func parse(data: Data, timeZone: TimeZone) throws -> Self {
    guard data.count <= maximumBytes else { throw ParseError.tooLarge }
    guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalidFile }
    let rows = try csv(text.replacingOccurrences(of: "\u{feff}", with: ""))
    guard let header = rows.first else { throw ParseError.invalidFile }
    let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    guard Set(names).count == names.count, ["type", "start", "end"].allSatisfy(names.contains) else {
      throw ParseError.invalidFile
    }
    let columns = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
    let iso = ISO8601DateFormatter()
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.calendar = Calendar(identifier: .gregorian)
    local.timeZone = timeZone
    local.isLenient = false
    func timestamp(_ value: String) -> Date? {
      iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = iso.date(from: value) { return date }
      iso.formatOptions = [.withInternetDateTime]
      if let date = iso.date(from: value) { return date }
      for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "M/d/yyyy h:mm a"] {
        local.dateFormat = format
        if let date = local.date(from: value) { return date }
      }
      return nil
    }
    var sleeps: [Sleep] = []
    var ignored = 0
    var identities = Set<String>()
    for (index, row) in rows.dropFirst().enumerated() {
      func value(_ name: String) -> String {
        guard let column = columns[name], column < row.count else { return "" }
        return row[column].trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard value("type").lowercased() == "sleep" else { ignored += 1; continue }
      guard row.count == header.count, let start = timestamp(value("start")),
            let end = timestamp(value("end")), end > start else { throw ParseError.invalidRow(index + 2) }
      guard ["start condition", "start location", "end condition"].allSatisfy({ value($0).utf8.count <= 2_048 }) else {
        throw ParseError.invalidRow(index + 2)
      }
      let identity = "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
      guard identities.insert(identity).inserted else { ignored += 1; continue }
      let location = value("start location").lowercased()
      let mapped = ["on own in bed": "crib", "co sleep": "cosleep", "swing": "motion", "nursing": "feeding"][location] ?? location
      sleeps.append(Sleep(startedAt: start, endedAt: end, startCondition: value("start condition"),
        sleepLocation: mapped, endCondition: value("end condition")))
    }
    return Self(sleeps: sleeps.sorted { $0.startedAt < $1.startedAt }, ignoredRows: ignored)
  }

  private static func csv(_ text: String) throws -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var closed = false
    let characters = Array(text)
    var index = 0
    func finishRow() throws {
      row.append(field)
      if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
      guard rows.count <= 10_001 else { throw ParseError.tooLarge }
      row = []; field = ""; closed = false
    }
    while index < characters.count {
      let c = characters[index]
      if quoted {
        if c == "\"" {
          if index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
          else { quoted = false; closed = true }
        } else { field.append(c) }
      } else if c == "," {
        row.append(field); field = ""; closed = false
      } else if c == "\n" || c == "\r" || c == "\r\n" {
        try finishRow()
      } else if c == "\"" && field.isEmpty && !closed {
        quoted = true
      } else {
        guard !closed && c != "\"" else { throw ParseError.invalidFile }
        field.append(c)
      }
      index += 1
    }
    guard !quoted else { throw ParseError.invalidFile }
    if !row.isEmpty || !field.isEmpty || closed { try finishRow() }
    return rows
  }
}
