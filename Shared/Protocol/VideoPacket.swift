import Foundation

/// Wraps encoded frame data and metadata for transport over the wired link.
struct VideoPacket: Codable, Sendable {
    let metadata: FrameMetadata
    let payload: Data

    init(metadata: FrameMetadata, payload: Data) {
        self.metadata = metadata
        self.payload = payload
    }
}
