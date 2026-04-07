import Foundation
import CoreGraphics

/// A fixed pixel-resolution preset that can be requested for the virtual display.
struct VirtualDisplayPreset: Identifiable, Equatable, Hashable {
    enum ScaleMode: String, Equatable, Hashable {
        case nonHiDPI
        case retina2x
    }

    let pixelWidth: Int
    let pixelHeight: Int
    let scaleMode: ScaleMode

    var id: String { "\(pixelWidth)x\(pixelHeight)-\(scaleMode.rawValue)" }
    var usesHiDPI: Bool { scaleMode == .retina2x }
    var logicalWidth: Int { usesHiDPI ? max(1, pixelWidth / 2) : pixelWidth }
    var logicalHeight: Int { usesHiDPI ? max(1, pixelHeight / 2) : pixelHeight }
    var shortLabel: String {
        usesHiDPI
            ? "\(logicalWidth)×\(logicalHeight) @ 2x"
            : "\(pixelWidth)×\(pixelHeight) @ 1x"
    }
    var label: String {
        if usesHiDPI {
            return "\(logicalWidth)×\(logicalHeight) logical · \(pixelWidth)×\(pixelHeight) pixels · 2× Retina"
        }
        return "\(pixelWidth)×\(pixelHeight) pixels · non-HiDPI"
    }

    private static func make(_ pixelWidth: Int, _ pixelHeight: Int, _ scaleMode: ScaleMode) -> VirtualDisplayPreset {
        VirtualDisplayPreset(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scaleMode: scaleMode)
    }

    private static func sortedPresets(_ presets: [VirtualDisplayPreset]) -> [VirtualDisplayPreset] {
        presets.sorted { lhs, rhs in
            let leftArea = lhs.pixelWidth * lhs.pixelHeight
            let rightArea = rhs.pixelWidth * rhs.pixelHeight
            if leftArea != rightArea {
                return leftArea > rightArea
            }
            if lhs.pixelWidth != rhs.pixelWidth {
                return lhs.pixelWidth > rhs.pixelWidth
            }
            if lhs.pixelHeight != rhs.pixelHeight {
                return lhs.pixelHeight > rhs.pixelHeight
            }
            if lhs.usesHiDPI != rhs.usesHiDPI {
                return !lhs.usesHiDPI && rhs.usesHiDPI
            }
            return lhs.label < rhs.label
        }
    }

    static func preset(forID id: String) -> VirtualDisplayPreset? {
        if let exact = allPresets.first(where: { $0.id == id }) {
            return exact
        }

        let parts = id.split(separator: "x")
        if parts.count == 2,
           let pixelWidth = Int(parts[0]),
           let pixelHeight = Int(parts[1]) {
            return allPresets.first(where: {
                $0.pixelWidth == pixelWidth &&
                $0.pixelHeight == pixelHeight &&
                $0.scaleMode == .nonHiDPI
            }) ?? allPresets.first(where: {
                $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight
            })
        }

        return nil
    }

    static let defaultFixed = make(3840, 2160, .nonHiDPI)

    static let standardPresets: [VirtualDisplayPreset] = sortedPresets([
        make(3840, 2160, .nonHiDPI),
        make(3840, 2160, .retina2x),
        make(6016, 3384, .retina2x),
        make(4096, 2304, .nonHiDPI),
        make(5120, 2880, .retina2x),
        make(3008, 1692, .retina2x),
        make(2560, 1440, .nonHiDPI),
        make(1920, 1080, .nonHiDPI)
    ])

    static let advancedPresets: [VirtualDisplayPreset] = {
        let candidates: [(Int, Int)] = [
            (7680, 4320),
            (6016, 3384),
            (5120, 3200),
            (5120, 2880),
            (5120, 2160),
            (4480, 2520),
            (4096, 2560),
            (4096, 2304),
            (3840, 2560),
            (3840, 2400),
            (3840, 2160),
            (3840, 1600),
            (3456, 2234),
            (3440, 1440),
            (3200, 2048),
            (3200, 1800),
            (3072, 1920),
            (3072, 1800),
            (3024, 1964),
            (3008, 1692),
            (2940, 1912),
            (2880, 1864),
            (2880, 1800),
            (2880, 1620),
            (2560, 1664),
            (2560, 1600),
            (2560, 1440),
            (2560, 1200),
            (2560, 1080),
            (2304, 1440),
            (2304, 1296),
            (2234, 1488),
            (2048, 1536),
            (2048, 1280),
            (2048, 1152),
            (1920, 1200),
            (1920, 1080),
            (1728, 1117),
            (1680, 1050),
            (1680, 945),
            (1600, 1024),
            (1600, 900),
            (1512, 982),
            (1470, 956),
            (1440, 900),
            (1366, 768),
            (1280, 800),
            (1280, 720)
        ]

        var presets: [VirtualDisplayPreset] = []
        var seen = Set<String>()

        for (width, height) in candidates {
            for scaleMode in [ScaleMode.nonHiDPI, .retina2x] {
                let preset = make(width, height, scaleMode)
                if seen.insert(preset.id).inserted {
                    presets.append(preset)
                }
            }
        }

        return sortedPresets(presets)
    }()

    static let allPresets: [VirtualDisplayPreset] = {
        var presets = standardPresets
        for preset in advancedPresets where !presets.contains(preset) {
            presets.append(preset)
        }
        return presets
    }()
}

/// A resolved display mode on a virtual display.
struct VirtualDisplayMode: Identifiable, Equatable, Hashable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let refreshRateHz: Double

    var id: String {
        "\(logicalWidth)x\(logicalHeight)-\(pixelWidth)x\(pixelHeight)-" +
        "\(String(format: "%.2f", scale))-\(String(format: "%.2f", refreshRateHz))"
    }

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
            logicalWidth: UInt32(mode.logicalWidth),
            logicalHeight: UInt32(mode.logicalHeight),
            pixelWidth: UInt32(mode.pixelWidth),
            pixelHeight: UInt32(mode.pixelHeight),
            refreshRate: mode.refreshRateHz
        )
        if !success {
            print(
                "[VirtualDisplayService] Failed to apply mode " +
                "\(mode.pixelWidth)×\(mode.pixelHeight) @ \(String(format: "%.2f", mode.refreshRateHz))Hz"
            )
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
