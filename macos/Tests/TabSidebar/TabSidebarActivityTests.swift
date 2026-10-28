import Foundation
import Testing
@testable import Nubb

@Suite
struct TabSidebarActivityTests {
    private let threshold: Duration = .seconds(10)
    private let long: Duration = .seconds(30)

    // MARK: Initial state

    @Test func initialStateIsQuiet() {
        let activity = TabSidebarActivity()
        #expect(activity.status == nil)
        #expect(activity.needsAttention == false)
        #expect(activity.isError == false)
    }

    // MARK: Notifications

    @Test func hiddenNotificationUsesTrimmedTitleAndNeedsAttention() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "  \n Build done\t\n", body: "ignored", isVisible: false)
        #expect(activity.status == "Build done")
        #expect(activity.needsAttention == true)
        #expect(activity.isError == false)
    }

    @Test func notificationFallsBackToTrimmedBodyWhenTitleBlank() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: " \n\t ", body: "\n  Tests passed  \n", isVisible: false)
        #expect(activity.status == "Tests passed")
    }

    @Test func notificationFallsBackToBodyWhenTitleEmpty() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "", body: "Body only", isVisible: false)
        #expect(activity.status == "Body only")
    }

    @Test func notificationWithBlankTitleAndBodyUsesPlaceholder() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "  ", body: "\n\t", isVisible: false)
        #expect(activity.status == "Notification")
        #expect(activity.needsAttention == true)
        #expect(activity.isError == false)
    }

    @Test func visibleNotificationUpdatesStatusWithoutAttention() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: " Hello ", body: "World", isVisible: true)
        #expect(activity.status == "Hello")
        #expect(activity.needsAttention == false)
        #expect(activity.isError == false)
    }

    @Test func visibleNotificationUsesSameFallbacks() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "", body: " ", isVisible: true)
        #expect(activity.status == "Notification")
        #expect(activity.needsAttention == false)
    }

    @Test func notificationClearsErrorFromFailedCommand() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 2, duration: long, threshold: threshold, isVisible: false)
        #expect(activity.isError == true)
        activity.recordNotification(title: "Hello", body: "", isVisible: false)
        #expect(activity.status == "Hello")
        #expect(activity.isError == false)
    }

    @Test func visibleNotificationClearsErrorToo() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 2, duration: long, threshold: threshold, isVisible: true)
        activity.recordNotification(title: "Hello", body: "", isVisible: true)
        #expect(activity.status == "Hello")
        #expect(activity.isError == false)
        #expect(activity.needsAttention == false)
    }

    @Test func visibleNotificationKeepsExistingAttention() {
        var activity = TabSidebarActivity()
        activity.recordBell(isVisible: false)
        activity.recordNotification(title: "Hello", body: "", isVisible: true)
        // A visible event never sets needsAttention, and nothing says it clears it.
        #expect(activity.needsAttention == true)
        #expect(activity.status == "Hello")
    }

    // MARK: Bell

    @Test func hiddenBellOnlySetsAttention() {
        var activity = TabSidebarActivity()
        activity.recordBell(isVisible: false)
        #expect(activity.needsAttention == true)
        #expect(activity.status == nil)
        #expect(activity.isError == false)
    }

    @Test func hiddenBellKeepsExistingStatus() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "Deploy ready", body: "", isVisible: true)
        activity.recordBell(isVisible: false)
        #expect(activity.status == "Deploy ready")
        #expect(activity.needsAttention == true)
    }

    @Test func hiddenBellKeepsErrorFlag() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 3, duration: long, threshold: threshold, isVisible: true)
        activity.recordBell(isVisible: false)
        #expect(activity.status == "Failed (exit 3)")
        #expect(activity.isError == true)
        #expect(activity.needsAttention == true)
    }

    @Test func visibleBellChangesNothingFromInitial() {
        var activity = TabSidebarActivity()
        activity.recordBell(isVisible: true)
        #expect(activity == TabSidebarActivity())
    }

    @Test func visibleBellChangesNothingFromExistingState() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 1, duration: long, threshold: threshold, isVisible: true)
        let before = activity
        activity.recordBell(isVisible: true)
        #expect(activity == before)
    }

    // MARK: Command finished

    @Test func hiddenCommandWithZeroExitFinishes() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 0, duration: long, threshold: threshold, isVisible: false)
        #expect(activity.status == "Finished")
        #expect(activity.isError == false)
        #expect(activity.needsAttention == true)
    }

    @Test func hiddenCommandWithNilExitFinishes() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: nil, duration: long, threshold: threshold, isVisible: false)
        #expect(activity.status == "Finished")
        #expect(activity.isError == false)
        #expect(activity.needsAttention == true)
    }

    @Test(arguments: [1, 2, 127, 255, -1])
    func hiddenCommandWithNonZeroExitFails(code: Int) {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: code, duration: long, threshold: threshold, isVisible: false)
        #expect(activity.status == "Failed (exit \(code))")
        #expect(activity.isError == true)
        #expect(activity.needsAttention == true)
    }

    @Test func visibleFailedCommandUpdatesStatusWithoutAttention() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 7, duration: long, threshold: threshold, isVisible: true)
        #expect(activity.status == "Failed (exit 7)")
        #expect(activity.isError == true)
        #expect(activity.needsAttention == false)
    }

    @Test func visibleSuccessfulCommandUpdatesStatusWithoutAttention() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: nil, duration: long, threshold: threshold, isVisible: true)
        #expect(activity.status == "Finished")
        #expect(activity.isError == false)
        #expect(activity.needsAttention == false)
    }

    @Test func commandShorterThanThresholdIsIgnoredWhenHidden() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(
            exitCode: 1,
            duration: .milliseconds(9_999),
            threshold: threshold,
            isVisible: false
        )
        #expect(activity == TabSidebarActivity())
    }

    @Test func commandShorterThanThresholdIsIgnoredWhenVisible() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 1, duration: .seconds(1), threshold: threshold, isVisible: true)
        #expect(activity == TabSidebarActivity())
    }

    @Test func shortCommandKeepsExistingState() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "Earlier", body: "", isVisible: false)
        let before = activity
        activity.recordCommandFinished(exitCode: 1, duration: .seconds(1), threshold: threshold, isVisible: false)
        #expect(activity == before)
    }

    @Test func commandExactlyAtThresholdIsRecorded() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 0, duration: threshold, threshold: threshold, isVisible: false)
        #expect(activity.status == "Finished")
        #expect(activity.needsAttention == true)
    }

    @Test func successAfterFailureClearsError() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 1, duration: long, threshold: threshold, isVisible: false)
        activity.recordCommandFinished(exitCode: 0, duration: long, threshold: threshold, isVisible: false)
        #expect(activity.status == "Finished")
        #expect(activity.isError == false)
    }

    // MARK: Replacement

    @Test func commandReplacesNotificationStatus() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "First", body: "", isVisible: false)
        activity.recordCommandFinished(exitCode: 4, duration: long, threshold: threshold, isVisible: false)
        #expect(activity.status == "Failed (exit 4)")
        #expect(activity.isError == true)
    }

    @Test func laterNotificationReplacesEarlierOne() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "One", body: "", isVisible: false)
        activity.recordNotification(title: "Two", body: "", isVisible: true)
        #expect(activity.status == "Two")
    }

    // MARK: markSeen

    @Test func markSeenClearsAttentionButKeepsStatusAndError() {
        var activity = TabSidebarActivity()
        activity.recordCommandFinished(exitCode: 9, duration: long, threshold: threshold, isVisible: false)
        activity.markSeen()
        #expect(activity.needsAttention == false)
        #expect(activity.status == "Failed (exit 9)")
        #expect(activity.isError == true)
    }

    @Test func markSeenKeepsNotificationStatus() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "Done", body: "", isVisible: false)
        activity.markSeen()
        #expect(activity.status == "Done")
        #expect(activity.needsAttention == false)
        #expect(activity.isError == false)
    }

    @Test func markSeenOnInitialStateIsNoOp() {
        var activity = TabSidebarActivity()
        activity.markSeen()
        #expect(activity == TabSidebarActivity())
    }

    @Test func attentionReturnsAfterMarkSeen() {
        var activity = TabSidebarActivity()
        activity.recordNotification(title: "Old", body: "", isVisible: false)
        activity.markSeen()
        activity.recordBell(isVisible: false)
        #expect(activity.needsAttention == true)
        #expect(activity.status == "Old")
    }
}
