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
            SleepActivityLockScreenView(
                childName: context.attributes.childName,
                startedAt: context.attributes.startedAt,
                elapsed: Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false),
                endURL: endURL(context.attributes))
            .activityBackgroundTint(SleepActivityPalette.softBlue)
            .activitySystemActionForegroundColor(SleepActivityPalette.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SleepActivityIdentityView(childName: context.attributes.childName, diameter: 42)
                }
                DynamicIslandExpandedRegion(.center) {
                    SleepActivityExpandedCenterView(
                        elapsed: Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SleepActivityWakeLink(endURL: endURL(context.attributes), diameter: 42)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SleepActivityExpandedBottomView(startedAt: context.attributes.startedAt)
                }
            } compactLeading: {
                Image(systemName: "moon.fill").foregroundStyle(SleepActivityPalette.turquoise)
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(width: 42)
            } minimal: {
                Image(systemName: "moon.fill").foregroundStyle(SleepActivityPalette.turquoise)
            }
            .widgetURL(endURL(context.attributes))
        }
    }

    private func endURL(_ attributes: SleepActivityAttributes) -> URL {
        URL(string: "uneton://sleep/end?familyID=\(attributes.familyID)&sessionID=\(attributes.sessionID)")!
    }
}
