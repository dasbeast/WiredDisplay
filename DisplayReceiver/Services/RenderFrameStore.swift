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
    let ownershipIntent: CursorOwnershipIntent
    let appearance: CursorAppearancePayload?
}

struct ReceiverCursorSnapshot {
    let previous: ReceiverCursorState?
    let latest: ReceiverCursorState?
}

/// Thread-safe cursor state store shared between receiver control handling and presentation.
final class ReceiverCursorStore {
    static let shared = ReceiverCursorStore()
    private static let maximumHistoryCount = 6

    private let lock = NSLock()
    private var historyStates: [ReceiverCursorState] = []

    private init() {}

    func reset() {
        lock.lock()
        historyStates.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func update(state: ReceiverCursorState) {
        lock.lock()
        let resolvedState: ReceiverCursorState
        if state.appearance != nil {
            resolvedState = state
        } else if let latestState = historyStates.last {
            resolvedState = ReceiverCursorState(
                senderTimestampNanoseconds: state.senderTimestampNanoseconds,
                receiverTimestampNanoseconds: state.receiverTimestampNanoseconds,
                normalizedX: state.normalizedX,
                normalizedY: state.normalizedY,
                isVisible: state.isVisible,
                ownershipIntent: state.ownershipIntent,
                appearance: latestState.appearance
            )
        } else {
            resolvedState = state
        }

        historyStates.append(resolvedState)
        if historyStates.count > Self.maximumHistoryCount {
            historyStates.removeFirst(historyStates.count - Self.maximumHistoryCount)
        }
        lock.unlock()
    }

    func snapshot(maxAgeNanoseconds: UInt64? = nil) -> ReceiverCursorState? {
        lock.lock()
        let state = historyStates.last
        lock.unlock()

        guard let state else { return nil }
        guard let maxAgeNanoseconds else { return state }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= state.receiverTimestampNanoseconds else { return state }
        return (now - state.receiverTimestampNanoseconds) <= maxAgeNanoseconds ? state : nil
    }

    func snapshotPair() -> ReceiverCursorSnapshot {
        lock.lock()
        let latest = historyStates.last
        let previous = historyStates.dropLast().last
        let snapshot = ReceiverCursorSnapshot(previous: previous, latest: latest)
        lock.unlock()
        return snapshot
    }

    func snapshotHistory() -> [ReceiverCursorState] {
        lock.lock()
        let snapshot = historyStates
        lock.unlock()
        return snapshot
    }
}
