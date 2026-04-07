import Foundation

extension Notification.Name {
    static let wiredDisplayRenderFrameUpdated = Notification.Name("wiredDisplayRenderFrameUpdated")
    static let wiredDisplayCursorStateUpdated = Notification.Name("wiredDisplayCursorStateUpdated")
}

/// Metal-backed renderer service placeholder for fullscreen presentation.
final class RenderService {
    private(set) var isPrepared = false
    private(set) var lastRenderedFrameMetadata: FrameMetadata?
    private(set) var lastRenderedBytesPerRow: Int = 0

    func prepareRenderer() {
        isPrepared = true
    }

    func render(frame: DecodedFrame) {
        guard isPrepared else { return }
        lastRenderedFrameMetadata = frame.metadata
        lastRenderedBytesPerRow = frame.bytesPerRow
        RenderFrameStore.shared.update(frame: frame)
        NotificationCenter.default.post(name: .wiredDisplayRenderFrameUpdated, object: nil)
    }

    // Backward-compatible placeholder signature used by older call sites.
    func render(frameData: Data, metadata: FrameMetadata) {
        render(
            frame: DecodedFrame(
                metadata: metadata,
                pixelBuffer: nil,
                pixelData: frameData,
                bytesPerRow: max(1, metadata.width * 4),
                pixelFormat: .bgra8
            )
        )
    }
}
