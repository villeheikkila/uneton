import ActivityKit
import Foundation
import UnetonActivity
import UnetonCore

@MainActor
struct LiveActivityController {
    func start(
        familyID: UUID,
        childID: UUID,
        sessionID: UUID,
        childName: String,
        startedAt: Date
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = SleepActivityAttributes(
            familyID: familyID,
            childID: childID,
            sessionID: sessionID,
            childName: childName,
            startedAt: startedAt
        )
        _ = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: .init(), staleDate: nil),
            pushType: .token
        )
    }

    func observeTokens(
        pushToStart: @escaping @Sendable (String) async -> Void,
        activity: @escaping @Sendable (UUID, String) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await token in Activity<SleepActivityAttributes>.pushToStartTokenUpdates {
                    await pushToStart(token.hexadecimalString)
                }
            }
            group.addTask {
                for existing in Activity<SleepActivityAttributes>.activities {
                    await observe(existing, activity: activity)
                }
                for await newActivity in Activity<SleepActivityAttributes>.activityUpdates {
                    await observe(newActivity, activity: activity)
                }
            }
            await group.waitForAll()
        }
    }

    func end(sessionID: UUID, endedAt: Date) async {
        for activity in Activity<SleepActivityAttributes>.activities
        where activity.attributes.sessionID == sessionID {
            await activity.end(
                ActivityContent(state: .init(endedAt: endedAt), staleDate: nil),
                dismissalPolicy: .after(endedAt.addingTimeInterval(60))
            )
        }
    }
}

private func observe(
    _ value: Activity<SleepActivityAttributes>,
    activity: @escaping @Sendable (UUID, String) async -> Void
) async {
    for await token in value.pushTokenUpdates {
        await activity(value.attributes.sessionID, token.hexadecimalString)
    }
}
