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

/// The animated sky behind every main screen.
struct SkyBackground: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.unetonDisplayNow) private var displayNowOverride

    /// Previews and snapshots pin the clock, so the sky holds still there too.
    private var isStill: Bool { reduceMotion || palette.mode == .nightLight || displayNowOverride != nil }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isStill)) { timeline in
            GeometryReader { proxy in
                Rectangle()
                    .fill(.white)
                    .colorEffect(
                        ShaderLibrary.sleepClouds(
                            .float(isStill ? 0 : Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 600))),
                            .float2(proxy.size),
                            .color(palette.skyTop.color),
                            .color(palette.skyMiddle.color),
                            .color(palette.skyBottom.color),
                            .color(palette.cloud.color),
                            .color(palette.cloudShade.color),
                            .float(palette.mode == .nightLight ? 0 : 1)
                        )
                    )
                    .overlay(alignment: .topTrailing) { celestial(width: proxy.size.width) }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func celestial(width: CGFloat) -> some View {
        switch palette.mode {
        case .day:
            Circle()
                .fill(palette.celestial.color)
                .frame(width: 104, height: 104)
                .blur(radius: 1)
                .padding(.top, 118)
                .padding(.trailing, 36)
        case .night:
            Circle()
                .fill(palette.celestial.color)
                .frame(width: 70, height: 70)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(palette.skyTop.color)
                        .frame(width: 62, height: 62)
                        .offset(x: -18, y: -14)
                }
                .clipShape(.circle)
                .padding(.top, 122)
                .padding(.trailing, 52)
        case .nightLight:
            EmptyView()
        }
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
