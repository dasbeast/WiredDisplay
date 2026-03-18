import Foundation
import CoreGraphics

/// A fixed pixel-resolution preset that can be requested for the virtual display.
struct VirtualDisplayPreset: Identifiable, Equatable, Hashable {
    let pixelWidth: Int
    let pixelHeight: Int

    var id: String { "\(pixelWidth)x\(pixelHeight)" }
    var label: String { "\(pixelWidth)×\(pixelHeight) pixels" }

    static let defaultFixed = VirtualDisplayPreset(pixelWidth: 3008, pixelHeight: 1692)

    static let commonPresets: [VirtualDisplayPreset] = [
        VirtualDisplayPreset(pixelWidth: 5120, pixelHeight: 2880),
        VirtualDisplayPreset(pixelWidth: 4096, pixelHeight: 2304),
        VirtualDisplayPreset(pixelWidth: 3840, pixelHeight: 2160),
        VirtualDisplayPreset(pixelWidth: 3200, pixelHeight: 1800),
        VirtualDisplayPreset(pixelWidth: 3024, pixelHeight: 1964),
        VirtualDisplayPreset(pixelWidth: 3008, pixelHeight: 1692),
        VirtualDisplayPreset(pixelWidth: 2880, pixelHeight: 1620),
        VirtualDisplayPreset(pixelWidth: 2560, pixelHeight: 1440),
        VirtualDisplayPreset(pixelWidth: 2304, pixelHeight: 1296),
        VirtualDisplayPreset(pixelWidth: 2048, pixelHeight: 1152),
        VirtualDisplayPreset(pixelWidth: 1920, pixelHeight: 1080),
        VirtualDisplayPreset(pixelWidth: 1680, pixelHeight: 945),
        VirtualDisplayPreset(pixelWidth: 1600, pixelHeight: 900),
        VirtualDisplayPreset(pixelWidth: 1366, pixelHeight: 768),
        VirtualDisplayPreset(pixelWidth: 1280, pixelHeight: 720)
    ]
}

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
    private var isDestroyingDisplay = false
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
        guard displayID != 0, !isDestroyingDisplay else { return }

        isDestroyingDisplay = true
        let doomedDisplayID = displayID
        displayID = 0

        VirtualDisplayBridge.destroyVirtualDisplay(doomedDisplayID)
        print("[VirtualDisplayService] Virtual display \(doomedDisplayID) destroy requested")
        isDestroyingDisplay = false
    }

    deinit {
        destroyDisplay()
    }
}
