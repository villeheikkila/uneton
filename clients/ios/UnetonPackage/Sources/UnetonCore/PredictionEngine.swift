import Foundation

public struct PredictionEngine: Sendable {
  public static let algorithmVersion = 1

  public init() {}

  public func estimate(
    wokeAt: Date,
    birthDate: Date,
    intervals: [TimeInterval],
    manualMinutes: Int?,
    calendar: Calendar = .current
  ) -> SleepPrediction? {
    if let manualMinutes {
      let target = wokeAt.addingTimeInterval(TimeInterval(manualMinutes * 60))
      return SleepPrediction(targetAt: target, rangeStartAt: target, rangeEndAt: target, confidence: "manual", explanation: "Using your family reminder interval.", algorithmVersion: Self.algorithmVersion)
    }
    let months = calendar.dateComponents([.month], from: birthDate, to: wokeAt).month ?? 0
    guard let range = prior(for: months) else { return nil }
    let recent = Array(intervals.suffix(14).map { $0 / 60 }.filter { 30...720 ~= $0 })
    let filtered = filterOutliers(recent)
    let priorMidpoint = Double(range.lowerBound + range.upperBound) / 2
    var targetMinutes = priorMidpoint
    var confidence = "low"
    var explanation = "Based on the age-based starting range."
    if !filtered.isEmpty {
      let weight = min(Double(filtered.count) / 7, 0.8)
      targetMinutes = priorMidpoint * (1 - weight) + median(filtered) * weight
      if filtered.count >= 10 { confidence = "high" }
      else if filtered.count >= 4 { confidence = "medium" }
      explanation = "Based on \(filtered.count) recent wake periods and the age-based range."
    }
    return SleepPrediction(
      targetAt: wokeAt.addingTimeInterval(targetMinutes.rounded() * 60),
      rangeStartAt: wokeAt.addingTimeInterval(TimeInterval(range.lowerBound * 60)),
      rangeEndAt: wokeAt.addingTimeInterval(TimeInterval(range.upperBound * 60)),
      confidence: confidence,
      explanation: explanation,
      algorithmVersion: Self.algorithmVersion
    )
  }

  private func prior(for months: Int) -> ClosedRange<Int>? {
    switch months {
    case 2...3: 60...120
    case 4...5: 90...150
    case 6...8: 120...210
    case 9...12: 150...240
    case 13...18: 240...330
    case 19...24: 300...360
    default: nil
    }
  }

  private func filterOutliers(_ values: [Double]) -> [Double] {
    guard values.count >= 5 else { return values }
    let center = median(values)
    let deviations = values.map { abs($0 - center) }
    let mad = median(deviations)
    guard mad > 0 else { return values }
    return values.filter { abs($0 - center) / mad <= 3.5 }
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
  }
}
