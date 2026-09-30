import ActivityKit
import Foundation
import UnetonActivity
import UnetonCore

@MainActor
struct LiveActivityController {
    func start(
        familyID: Family.ID,
        childID: Child.ID,
        sessionID: SleepSession.ID,
        childName: String,
        startedAt: Date
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<SleepActivityAttributes>.activities.contains(where: {
                  $0.attributes.sessionID == sessionID
              }) else { return }
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
        activity: @escaping @Sendable (SleepSession.ID, String) async -> Void
    ) async {
        let observers = ConcurrentTokenObservers()
        let starts = Task { @MainActor in
            if let token = Activity<SleepActivityAttributes>.pushToStartToken {
                await pushToStart(token.hexadecimalString)
            }
            for await token in Activity<SleepActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                await pushToStart(token.hexadecimalString)
            }
        }
        let discovery = Task { @MainActor in
            for existing in Activity<SleepActivityAttributes>.activities {
                await observers.start(id: existing.id) { await observe(existing, activity: activity) }
            }
            for await newActivity in Activity<SleepActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { break }
                await observers.start(id: newActivity.id) { await observe(newActivity, activity: activity) }
            }
            await observers.cancelAll()
        }
        await withTaskCancellationHandler {
            await discovery.value
            starts.cancel()
            await starts.value
        } onCancel: {
            starts.cancel()
            discovery.cancel()
        }
    }

    func end(sessionID: SleepSession.ID, endedAt: Date) async {
        for activity in Activity<SleepActivityAttributes>.activities
        where activity.attributes.sessionID == sessionID {
            await activity.end(
                ActivityContent(state: .init(endedAt: endedAt), staleDate: nil),
                dismissalPolicy: .after(endedAt.addingTimeInterval(60))
            )
        }
    }
}

@MainActor
private func observe(
    _ value: Activity<SleepActivityAttributes>,
    activity: @escaping @Sendable (SleepSession.ID, String) async -> Void
) async {
    let tokens = Task { @MainActor in
        if let token = value.pushToken {
            await activity(value.attributes.sessionID, token.hexadecimalString)
        }
        for await token in value.pushTokenUpdates {
            guard !Task.isCancelled else { return }
            await activity(value.attributes.sessionID, token.hexadecimalString)
        }
    }
    await withTaskCancellationHandler {
        for await state in value.activityStateUpdates {
            if Task.isCancelled || state == .ended || state == .dismissed { break }
        }
        tokens.cancel()
        await tokens.value
    } onCancel: {
        tokens.cancel()
    }
}
