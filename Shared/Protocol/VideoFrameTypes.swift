import Foundation
import CoreVideo

/// Pixel format contract for captured/decoded frame payloads.
enum PixelFormat: String, Codable, Sendable {
    case bgra8
}

/// Declares codec intent for encoded frame payloads.
enum VideoCodec: String, Codable, Sendable {
    case h264AVCC
    case rawBGRA
}

/// Raw frame emitted by capture pipeline before compression.
struct CapturedFrame: @unchecked Sendable {
    let metadata: FrameMetadata
    let rawData: Data
    let bytesPerRow: Int
    let pixelFormat: PixelFormat
    /// Optional direct pixel buffer reference for efficient H.264 encoding.
    let pixelBuffer: CVPixelBuffer?

    init(metadata: FrameMetadata, rawData: Data, bytesPerRow: Int, pixelFormat: PixelFormat, pixelBuffer: CVPixelBuffer? = nil) {
        self.metadata = metadata
        self.rawData = rawData
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.pixelBuffer = pixelBuffer
    }
}

/// Encoded frame contract for sender -> receiver payload handling.
struct EncodedFrame: Codable, Sendable {
    let metadata: FrameMetadata
    let codec: VideoCodec
    let payload: Data
    let isKeyFrame: Bool
    let sourceBytesPerRow: Int
    let sourcePixelFormat: PixelFormat
    let targetBitrateKbps: Int
    let targetFramesPerSecond: Int
    let h264SPS: Data?
    let h264PPS: Data?
}

/// Decoded frame contract for receiver rendering stage.
struct DecodedFrame {
    let metadata: FrameMetadata
    let pixelBuffer: CVPixelBuffer?
    let pixelData: Data?
    let bytesPerRow: Int
    let pixelFormat: PixelFormat
}
