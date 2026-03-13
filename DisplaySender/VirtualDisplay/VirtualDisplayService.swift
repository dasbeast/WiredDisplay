import Foundation
import CoreGraphics

/// A resolved display mode on a virtual display.
struct VirtualDisplayMode: Identifiable, Equatable, Hashable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let refreshRateHz: Double

    var id: String { "\(pixelWidth)x\(pixelHeight)" }

    var isRetina: Bool { scale >= 1.5 }

    /// Human-readable label for display in the UI.
    var label: String {
        let scaleStr = String(format: "%.0f", scale)
        if isRetina {
            return "\(logicalWidth)×\(logicalHeight) logical · \(pixelWidth)×\(pixelHeight) pixels · \(scaleStr)× Retina"
        } else {
            return "\(pixelWidth)×\(pixelHeight) pixels · non-HiDPI"
        }
    }

    /// Short description for status readouts.
    var shortDescription: String {
        if isRetina {
            return "\(logicalWidth)×\(logicalHeight) @ \(String(format: "%.0f", scale))x (\(pixelWidth)×\(pixelHeight) pixels)"
        } else {
            return "\(pixelWidth)×\(pixelHeight) non-HiDPI"
        }
    }
}

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

    /// Returns all modes macOS exposes for the current virtual display, sorted sharpest first.
    func availableModes() -> [VirtualDisplayMode] {
        guard displayID != 0 else { return [] }
        let raw = VirtualDisplayBridge.availableModes(forDisplay: displayID)
        return raw.compactMap { dict in
            guard
                let lw = dict["logicalWidth"] as? Int,
                let lh = dict["logicalHeight"] as? Int,
                let pw = dict["pixelWidth"] as? Int,
                let ph = dict["pixelHeight"] as? Int,
                let scale = dict["scale"] as? Double,
                let rr = dict["refreshRate"] as? Double
            else { return nil }
            return VirtualDisplayMode(
                logicalWidth: lw, logicalHeight: lh,
                pixelWidth: pw, pixelHeight: ph,
                scale: scale, refreshRateHz: rr
            )
        }
    }

    /// Returns the mode macOS currently has active on the virtual display.
    func activeMode() -> VirtualDisplayMode? {
        guard displayID != 0 else { return nil }
        guard let dict = VirtualDisplayBridge.activeMode(forDisplay: displayID) else { return nil }
        guard
            let lw = dict["logicalWidth"] as? Int,
            let lh = dict["logicalHeight"] as? Int,
            let pw = dict["pixelWidth"] as? Int,
            let ph = dict["pixelHeight"] as? Int,
            let scale = dict["scale"] as? Double,
            let rr = dict["refreshRate"] as? Double
        else { return nil }
        return VirtualDisplayMode(
            logicalWidth: lw, logicalHeight: lh,
            pixelWidth: pw, pixelHeight: ph,
            scale: scale, refreshRateHz: rr
        )
    }

    /// Applies the given mode via CGConfigureDisplayWithDisplayMode.
    /// Returns true if macOS accepted the configuration.
    @discardableResult
    func apply(mode: VirtualDisplayMode) -> Bool {
        guard displayID != 0 else { return false }
        let success = VirtualDisplayBridge.applyMode(
            forDisplay: displayID,
            pixelWidth: UInt32(mode.pixelWidth),
            pixelHeight: UInt32(mode.pixelHeight)
        )
        if !success {
            print("[VirtualDisplayService] Failed to apply mode \(mode.pixelWidth)×\(mode.pixelHeight)")
        }
        return success
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
