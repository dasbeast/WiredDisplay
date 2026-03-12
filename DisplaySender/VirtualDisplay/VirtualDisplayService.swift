import Foundation
import CoreGraphics

/// Manages the lifecycle of a virtual display that macOS treats as an extended monitor.
/// Uses the private CGVirtualDisplay API via an Obj-C bridge.
final class VirtualDisplayService {
    private(set) var displayID: CGDirectDisplayID = 0
    var isActive: Bool { displayID != 0 }

    /// Creates a virtual display with the given logical resolution.
    /// macOS will treat this as a real extended display that apps can use.
    func createDisplay(width: Int, height: Int, refreshRate: Double = 60, hiDPI: Bool = true) -> CGDirectDisplayID {
        destroyDisplay()

        let newID = VirtualDisplayBridge.createVirtualDisplay(
            withWidth: UInt32(width),
            height: UInt32(height),
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            name: "WiredDisplay"
        )

        if newID != 0 {
            displayID = newID
            print("[VirtualDisplayService] Virtual display created with ID \(newID)")
        } else {
            print("[VirtualDisplayService] Failed to create virtual display")
        }

        return newID
    }

    /// Destroys the current virtual display.
    func destroyDisplay() {
        guard displayID != 0 else { return }
        VirtualDisplayBridge.destroyVirtualDisplay(displayID)
        print("[VirtualDisplayService] Virtual display \(displayID) destroyed")
        displayID = 0
    }

    deinit {
        destroyDisplay()
    }
}
