import SwiftUI
import UnetonTheme

extension EnvironmentValues {
    /// The active child palette. Views read semantic roles from it instead of
    /// hard-coding colors, so a per-child seed only has to change this value.
    @Entry var palette: Palette = .make(mode: .day)
}

extension View {
    /// Installs a palette for a subtree: the environment value, the tint used by
    /// native controls, and the matching light or dark appearance.
    func palette(_ palette: Palette) -> some View {
        environment(\.palette, palette)
            .tint(palette.accent.color)
            .environment(\.colorScheme, palette.mode == .day ? .light : .dark)
    }
}

extension View {
    /// Puts the shared sky behind a full screen. Sheets keep their system glass.
    /// Forms and lists drop their grouped background so the sky shows through.
    func skyBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { SkyBackground() }
    }
}

/// The animated sky behind every full screen and tab.
///
/// Colors follow the palette and the local time of day. Motion is derived from the
/// wall clock, so separate instances on different tabs and screens always
/// draw the same frame and switching between them never jumps.
struct SkyBackground: View {
    @Environment(\.palette) private var palette
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.unetonDisplayNow) private var displayNowOverride

    /// Previews and snapshots pin the clock, so the sky holds still there too.
    private var isStill: Bool { reduceMotion || palette.mode == .nightLight || displayNowOverride != nil }

    var body: some View {
        // A still sky still refreshes once a minute so the time of day moves on.
        TimelineView(.animation(minimumInterval: isStill ? 60 : 1 / 60, paused: displayNowOverride != nil)) { timeline in
            let now = displayNowOverride ?? timeline.date
            ZStack {
                SkyCanvas(
                    palette: palette,
                    phase: DayPhase(date: now, calendar: calendar),
                    time: isStill ? 0 : now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                )
                .id(palette.mode)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: palette.mode)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct SkyCanvas: View {
    let palette: Palette
    let phase: DayPhase
    /// Seconds into the current hour; the shader loops seamlessly at 3600.
    let time: Double

    var body: some View {
        let sky = palette.sky(at: phase)
        let celestialAmount = palette.mode == .nightLight ? 0.0 : 1.0
        let daylight = Self.sunVisibility(phase.hour)
        // The night palette always shows the moon: a pale sun on a dark sky would sit
        // behind light text with too little contrast.
        let isNight = palette.mode == .night
        let sunAmount = isNight ? 0 : daylight * celestialAmount
        let moonAmount = isNight ? celestialAmount : (1 - daylight) * celestialAmount
        GeometryReader { proxy in
            let sunPoint = Self.arcPoint(Self.sunProgress(phase.hour), in: proxy.size)
            let nightMoonPoint = Self.arcPoint(Self.moonProgress(phase.hour), in: proxy.size)
            let moonPoint = isNight ? Self.mix(nightMoonPoint, sunPoint, daylight) : nightMoonPoint
            Rectangle()
                .fill(.white)
                .colorEffect(
                    ShaderLibrary.sleepClouds(
                        .float(time),
                        .float2(proxy.size),
                        .color(sky.top.color),
                        .color(sky.middle.color),
                        .color(sky.bottom.color),
                        .color(sky.cloud.color),
                        .color(sky.cloudShade.color),
                        .float(palette.mode == .nightLight ? 0 : 1),
                        .float(sky.stars),
                        .color(palette.celestial.color),
                        .float2(sunPoint),
                        .float(sunAmount),
                        .float2(moonPoint),
                        .float(moonAmount)
                    )
                )
        }
    }

    /// The sun is up from about 06:00 to 20:00 and the moon the rest of the time.
    private static func sunVisibility(_ hour: Double) -> Double {
        smoothstep(5.5, 7, hour) * (1 - smoothstep(19.5, 21, hour))
    }

    /// The sun crosses from left to right between 06:00 and 20:00.
    private static func sunProgress(_ hour: Double) -> Double {
        ((hour - 6) / 14).clamped(to: 0...1)
    }

    /// The moon crosses from left to right between 19:00 and 06:00.
    private static func moonProgress(_ hour: Double) -> Double {
        (((hour < 12 ? hour + 24 : hour) - 19) / 11).clamped(to: 0...1)
    }

    /// A low arc over the top trailing corner, clear of the leading screen titles,
    /// highest at the middle of the crossing.
    private static func arcPoint(_ progress: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (0.62 + 0.3 * progress), y: 215 - 60 * sin(.pi * progress))
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ amount: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// The soft glass card used for panels and lists.
struct GlassCard<Content: View>: View {
    @Environment(\.palette) private var palette
    var cornerRadius: CGFloat = 28
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    private var glass: Glass {
        palette.mode == .nightLight ? .clear : .regular.tint(palette.surface.color.opacity(0.35))
    }
}

/// A rounded, playful number style shared by timers and stats.
extension Font {
    static func soft(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Large rounded screen title used at the top of each tab.
struct TabHeader: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringResource
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.soft(32))
                .foregroundStyle(palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.soft(14, weight: .bold))
                    .foregroundStyle(palette.inkSecondary.color)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// A small glass tile with a label, a big value and an optional detail line.
struct StatTile: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringResource
    let value: String
    var detail: String?

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.soft(12, weight: .bold))
                    .foregroundStyle(palette.inkSecondary.color)
                Text(value)
                    .font(.soft(24))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(palette.ink.color)
                if let detail {
                    Text(detail)
                        .font(.soft(12, weight: .semibold))
                        .foregroundStyle(palette.inkSecondary.color)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One tappable row in a diary-style list: colored marker, title, subtitle, value.
struct DiaryRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    let value: String
    let marker: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Capsule().fill(marker).frame(width: 6, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.soft(16, weight: .bold))
                        .foregroundStyle(palette.ink.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(.soft(14, weight: .semibold))
                            .foregroundStyle(palette.inkSecondary.color)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(value)
                    .font(.soft(16))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.color)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(palette.inkSecondary.color)
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
