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
struct CapturedFrame: Sendable {
    let metadata: FrameMetadata
    let rawData: Data
    let bytesPerRow: Int
    let pixelFormat: PixelFormat
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
