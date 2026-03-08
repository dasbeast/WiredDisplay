import Foundation

/// Describes a single captured frame so sender and receiver can stay in sync.
struct FrameMetadata: Codable, Sendable {
    let frameIndex: UInt64
    let timestampNanoseconds: UInt64
    let width: Int
    let height: Int
    let isKeyFrame: Bool

    init(
        frameIndex: UInt64,
        timestampNanoseconds: UInt64,
        width: Int,
        height: Int,
        isKeyFrame: Bool
    ) {
        self.frameIndex = frameIndex
        self.timestampNanoseconds = timestampNanoseconds
        self.width = width
        self.height = height
        self.isKeyFrame = isKeyFrame
    }
}
