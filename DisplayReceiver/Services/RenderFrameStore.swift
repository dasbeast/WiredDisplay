import Foundation

/// Thread-safe latest-frame store shared between render service and Metal surface.
final class RenderFrameStore {
    static let shared = RenderFrameStore()

    private let lock = NSLock()
    private var latestFrame: DecodedFrame?
    private var hasUnreadFrame = false
    private var replacedBeforeRenderCount: UInt64 = 0

    private init() {}

    func reset() {
        lock.lock()
        latestFrame = nil
        hasUnreadFrame = false
        replacedBeforeRenderCount = 0
        lock.unlock()
    }

    func update(frame: DecodedFrame) {
        lock.lock()
        if hasUnreadFrame {
            replacedBeforeRenderCount += 1
        }
        latestFrame = frame
        hasUnreadFrame = true
        lock.unlock()
    }

    func snapshot() -> DecodedFrame? {
        lock.lock()
        let frame = latestFrame
        if frame != nil {
            hasUnreadFrame = false
        }
        lock.unlock()
        return frame
    }

    func replacedFramesCount() -> UInt64 {
        lock.lock()
        let count = replacedBeforeRenderCount
        lock.unlock()
        return count
    }
}
