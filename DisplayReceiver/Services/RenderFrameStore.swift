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

struct ReceiverCursorState: Equatable {
    let senderTimestampNanoseconds: UInt64
    let receiverTimestampNanoseconds: UInt64
    let normalizedX: Double
    let normalizedY: Double
    let isVisible: Bool
    let appearance: CursorAppearancePayload?
}

struct ReceiverCursorSnapshot {
    let previous: ReceiverCursorState?
    let latest: ReceiverCursorState?
}

/// Thread-safe cursor state store shared between receiver control handling and presentation.
final class ReceiverCursorStore {
    static let shared = ReceiverCursorStore()

    private let lock = NSLock()
    private var previousState: ReceiverCursorState?
    private var latestState: ReceiverCursorState?

    private init() {}

    func reset() {
        lock.lock()
        previousState = nil
        latestState = nil
        lock.unlock()
    }

    func update(state: ReceiverCursorState) {
        lock.lock()
        let resolvedState: ReceiverCursorState
        if state.appearance != nil {
            resolvedState = state
        } else if let latestState {
            resolvedState = ReceiverCursorState(
                senderTimestampNanoseconds: state.senderTimestampNanoseconds,
                receiverTimestampNanoseconds: state.receiverTimestampNanoseconds,
                normalizedX: state.normalizedX,
                normalizedY: state.normalizedY,
                isVisible: state.isVisible,
                appearance: latestState.appearance
            )
        } else {
            resolvedState = state
        }

        previousState = latestState
        latestState = resolvedState
        lock.unlock()
    }

    func snapshot(maxAgeNanoseconds: UInt64? = nil) -> ReceiverCursorState? {
        lock.lock()
        let state = latestState
        lock.unlock()

        guard let state else { return nil }
        guard let maxAgeNanoseconds else { return state }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= state.receiverTimestampNanoseconds else { return state }
        return (now - state.receiverTimestampNanoseconds) <= maxAgeNanoseconds ? state : nil
    }

    func snapshotPair() -> ReceiverCursorSnapshot {
        lock.lock()
        let snapshot = ReceiverCursorSnapshot(previous: previousState, latest: latestState)
        lock.unlock()
        return snapshot
    }
}
