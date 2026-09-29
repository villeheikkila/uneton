import SwiftUI
import UnetonCore

struct TemperatureContent: View {
    let readings: [TemperatureReading]
    let onAdd: () -> Void
    let onSelect: (TemperatureReading) -> Void

    var body: some View {
        TemperatureCard(readings: readings, onAdd: onAdd, onSelect: onSelect)
    }
}

private struct TemperatureCard: View {
    let readings: [TemperatureReading]
    let onAdd: () -> Void
    let onSelect: (TemperatureReading) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Temperature", systemImage: "thermometer.medium")
                        .font(.title2.weight(.bold))
                    Text("Log readings and notes for your baby. Your family can see updates too.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .glassEffect(.regular.tint(Color.sleepMoonlight.opacity(0.12)), in: .rect(cornerRadius: 24))

                Button(action: onAdd) {
                    Label("Add temperature", systemImage: "plus.circle.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.sleepIndigo)

                if readings.isEmpty {
                    ContentUnavailableView("No readings yet", systemImage: "thermometer.medium",
                        description: Text("Add a reading with its time and an optional note."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    ForEach(readings) { reading in
                        Button { onSelect(reading) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "thermometer.medium")
                                    .font(.title3)
                                    .foregroundStyle(Color.sleepIndigo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(reading.measuredAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.headline)
                                    Text(String(format: "%.2f °C", Double(reading.centiCelsius) / 100))
                                        .font(.subheadline.monospacedDigit())
                                    if !reading.note.isEmpty {
                                        Text(reading.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}
