import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
final class ReceiverPowerManagementService: NSObject, ObservableObject {
    @Published private(set) var isPreventingSleep = false
    @Published private(set) var lastErrorMessage: String?

    private var processInfoActivity: NSObjectProtocol?
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var screensaverRefreshTimer: Timer?

    func startPreventingSleep() {
        guard !isPreventingSleep else { return }

        lastErrorMessage = nil
        processInfoActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "DisplayReceiver must stay awake while available for incoming streams."
        )

        createAssertion(
            type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            name: "DisplayReceiver Prevent Display Sleep"
        ) { assertionID in
            displaySleepAssertionID = assertionID
        }
        createAssertion(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            name: "DisplayReceiver Prevent System Sleep"
        ) { assertionID in
            systemSleepAssertionID = assertionID
        }

        screensaverRefreshTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(refreshUserActivityTimerFired),
            userInfo: nil,
            repeats: true
        )
        screensaverRefreshTimer?.tolerance = 5
        if let screensaverRefreshTimer {
            RunLoop.main.add(screensaverRefreshTimer, forMode: .common)
        }
        refreshUserActivity()
        isPreventingSleep = true
    }

    func stopPreventingSleep() {
        guard isPreventingSleep else { return }

        screensaverRefreshTimer?.invalidate()
        screensaverRefreshTimer = nil

        if let processInfoActivity {
            ProcessInfo.processInfo.endActivity(processInfoActivity)
            self.processInfoActivity = nil
        }

        releaseAssertion(&displaySleepAssertionID)
        releaseAssertion(&systemSleepAssertionID)

        isPreventingSleep = false
    }

    @objc
    private func refreshUserActivityTimerFired() {
        refreshUserActivity()
    }

    private func refreshUserActivity() {
        var userActivityAssertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "DisplayReceiver refreshing user activity to suppress the screen saver." as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )
        if result == kIOReturnSuccess {
            IOPMAssertionRelease(userActivityAssertionID)
        } else {
            lastErrorMessage = "Unable to refresh user activity (\(result))"
        }
    }

    private func createAssertion(
        type: CFString,
        name: String,
        assign: (IOPMAssertionID) -> Void
    ) {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            lastErrorMessage = "Unable to create power assertion (\(result))"
            return
        }

        assign(assertionID)
    }

    private func releaseAssertion(_ assertionID: inout IOPMAssertionID) {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
