import ActivityKit
import UnetonActivity
import UnetonCore
import SwiftUI
import WidgetKit

@main
struct UnetonWidgets: WidgetBundle {
    var body: some Widget {
        SleepLiveActivity()
    }
}

struct SleepLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(context.attributes.childName) is sleeping")
                        .font(.headline)
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: endURL(context.attributes)) {
                    Text("Wake up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.indigo, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .padding()
            .activityBackgroundTint(Color.indigo.opacity(0.12))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link("Wake", destination: endURL(context.attributes))
                        .font(.caption.weight(.bold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.childName) is sleeping")
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "moon.fill").foregroundStyle(.indigo)
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(width: 42)
            } minimal: {
                Image(systemName: "moon.fill").foregroundStyle(.indigo)
            }
            .widgetURL(endURL(context.attributes))
        }
    }

    private func endURL(_ attributes: SleepActivityAttributes) -> URL {
        URL(string: "uneton://sleep/end?familyID=\(attributes.familyID)&sessionID=\(attributes.sessionID)")!
    }
}
