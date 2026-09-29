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
                elapsed: Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false),
                endURL: endURL(context.attributes))
            .activityBackgroundTint(SleepActivityPalette.softBlue)
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(SleepActivityPalette.blue)
                }
                DynamicIslandExpandedRegion(.center) {
                    SleepActivityExpandedCenterView(
                        elapsed: Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: endURL(context.attributes)) {
                        Text("locWake", comment: "Short Dynamic Island action that ends the active sleep session")
                            .font(.caption.weight(.bold))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SleepActivityExpandedBottomView(childName: context.attributes.childName)
                }
            } compactLeading: {
                Image(systemName: "moon.fill").foregroundStyle(SleepActivityPalette.blue)
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(width: 42)
            } minimal: {
                Image(systemName: "moon.fill").foregroundStyle(SleepActivityPalette.blue)
            }
            .widgetURL(endURL(context.attributes))
        }
    }

    private func endURL(_ attributes: SleepActivityAttributes) -> URL {
        URL(string: "uneton://sleep/end?familyID=\(attributes.familyID)&sessionID=\(attributes.sessionID)")!
    }
}
