import Foundation
import CoreVideo

/// Pixel format contract for captured/decoded frame payloads.
enum PixelFormat: String, Codable, Sendable {
    case bgra8
    case yuv420
}

/// Declares codec intent for encoded frame payloads.
enum VideoCodec: String, Codable, Sendable {
    case h264AVCC
    case hevcAVCC
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
    /// H.264 SPS or HEVC SPS parameter set bytes.
    let h264SPS: Data?
    /// H.264 PPS or HEVC PPS parameter set bytes.
    let h264PPS: Data?
    /// HEVC-only: Video Parameter Set bytes (nil for H.264).
    let hevcVPS: Data?

    init(
        metadata: FrameMetadata,
        codec: VideoCodec,
        payload: Data,
        isKeyFrame: Bool,
        sourceBytesPerRow: Int,
        sourcePixelFormat: PixelFormat,
        targetBitrateKbps: Int,
        targetFramesPerSecond: Int,
        h264SPS: Data? = nil,
        h264PPS: Data? = nil,
        hevcVPS: Data? = nil
    ) {
        self.metadata = metadata
        self.codec = codec
        self.payload = payload
        self.isKeyFrame = isKeyFrame
        self.sourceBytesPerRow = sourceBytesPerRow
        self.sourcePixelFormat = sourcePixelFormat
        self.targetBitrateKbps = targetBitrateKbps
        self.targetFramesPerSecond = targetFramesPerSecond
        self.h264SPS = h264SPS
        self.h264PPS = h264PPS
        self.hevcVPS = hevcVPS
    }
}

/// Decoded frame contract for receiver rendering stage.
struct DecodedFrame {
    let metadata: FrameMetadata
    let pixelBuffer: CVPixelBuffer?
    let pixelData: Data?
    let bytesPerRow: Int
    let pixelFormat: PixelFormat
}
