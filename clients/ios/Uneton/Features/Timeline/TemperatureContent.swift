import SwiftUI
import UnetonCore

struct TemperatureContent: View {
    @Environment(\.palette) private var palette
    @Environment(\.calendar) private var calendar
    let readings: [TemperatureReading]
    let onAdd: () -> Void
    let onSelect: (TemperatureReading) -> Void

    private var days: [(date: Date, readings: [TemperatureReading])] {
        Dictionary(grouping: readings) { calendar.startOfDay(for: $0.measuredAt) }
            .map { (date: $0.key, readings: $0.value.sorted { $0.measuredAt > $1.measuredAt }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                TabHeader(title: LocalizedStringResource("locTemperature", defaultValue: "Temperature", comment: "Label in Timeline: Temperature"))

                if let latest = readings.max(by: { $0.measuredAt < $1.measuredAt }) {
                    GlassCard(cornerRadius: 30, padding: 18) {
                        HStack(spacing: 16) {
                            Image(systemName: "thermometer.medium")
                                .font(.title2)
                                .foregroundStyle(palette.accent.color)
                                .frame(width: 56, height: 56)
                                .glassEffect(.regular, in: .circle)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(latest.measuredAt, format: .dateTime.weekday().hour().minute())
                                    .font(.soft(13, weight: .bold))
                                    .foregroundStyle(palette.inkSecondary.color)
                                Text(TemperatureFormat.value(latest.centiCelsius))
                                    .font(.soft(40))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.ink.color)
                                if !latest.note.isEmpty {
                                    Text(latest.note)
                                        .font(.soft(13, weight: .semibold))
                                        .foregroundStyle(palette.inkSecondary.color)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)

                    ForEach(days, id: \.date) { day in
                        HStack(alignment: .firstTextBaseline) {
                            Text(day.date, format: .dateTime.weekday(.wide).day().month())
                                .font(.soft(17))
                                .foregroundStyle(palette.ink.color)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 6)

                        GlassCard(cornerRadius: 26, padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(day.readings) { reading in
                                    DiaryRow(
                                        title: reading.measuredAt.formatted(date: .omitted, time: .shortened),
                                        subtitle: reading.note.isEmpty ? nil : reading.note,
                                        value: TemperatureFormat.value(reading.centiCelsius),
                                        marker: palette.accent.color
                                    ) { onSelect(reading) }
                                    if reading.id != day.readings.last?.id {
                                        Divider().padding(.leading, 34)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    Text("locLogReadingsAndNotesForYourBabyYourFamilyCanSeeUpdatesToo", comment: "Text in Timeline: Log readings and notes for your baby. Your family can see updates too.")
                        .font(.soft(13, weight: .semibold))
                        .foregroundStyle(palette.inkSecondary.color)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                } else {
                    GlassCard {
                        ContentUnavailableView {
                            Label(LocalizedStringResource("locNoReadingsYet", defaultValue: "No readings yet", comment: "Text in Timeline: No readings yet"), systemImage: "thermometer.medium")
                        } description: {
                            Text("locAddAReadingWithItsTimeAndAnOptionalNote", comment: "Text in Timeline: Add a reading with its time and an optional note.")
                        } actions: {
                            Button(LocalizedStringResource("locAddTemperature", defaultValue: "Add temperature", comment: "Label in Timeline: Add temperature"), systemImage: "plus", action: onAdd)
                                .buttonStyle(.glassProminent)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

enum TemperatureFormat {
    static func value(_ centiCelsius: Int) -> String {
        // Readings are stored in hundredths; show the second decimal only when it was entered.
        String(format: centiCelsius % 10 == 0 ? "%.1f °C" : "%.2f °C", locale: .current, Double(centiCelsius) / 100)
    }
}
