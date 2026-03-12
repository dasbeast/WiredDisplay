import Foundation

/// Defines wire-level messages and protocol validation shared by sender and receiver.
enum NetworkProtocol {
    static let protocolVersion: UInt16 = 1
    static let defaultPort: UInt16 = 50999
    static let maximumEnvelopeBytes: Int = 134_217_728  // 128 MB – HEVC key frames at high bitrate
    static let maximumMessageBytes: Int = 134_217_728  // 128 MB – binary framed messages
    static let heartbeatIntervalSeconds: TimeInterval = 1.0
    static let heartbeatTimeoutSeconds: TimeInterval = 5.0
    static let reconnectDelaySeconds: TimeInterval = 2.0
    static let maxPendingOutboundFrames: Int = 8
    static let transportReceiveChunkBytes: Int = 2 * 1024 * 1024  // 2 MB – reduces syscall overhead for high-throughput HEVC stream
    static let targetFramesPerSecond: Int = 60
    static let keyFrameIntervalSeconds: Int = 1
    static let captureFramesPerSecond: Int = 60
    // HEVC (H.265) encoder target: ~300 Mbps for near-lossless retina quality over Thunderbolt.
    // Thunderbolt 3 provides 40,000 Mbps — we use at most 5% of available bandwidth.
    static let targetVideoBitrateBps: Int = 300_000_000
    static let minVideoBitrateBps: Int = 50_000_000
    static let maxVideoBitrateBps: Int = 2_000_000_000  // 2 Gbps – well within Thunderbolt 3 limits
    // HEVC pixel budget: supports up to 5120×2880 HiDPI capture (22.1 MP).
    // Hardware HEVC encoders handle this resolution at 60 fps over Thunderbolt.
    static let maxCapturePixelsAtTargetFPS: Int = 22_118_400 // 5120x2880 + headroom
    static let allowLoopbackForLocalTesting: Bool = true
    static let preferRawFrameTransportForDiagnostics: Bool = false
    static let rawDiagnosticsMaxWidth: Int = 320
    static let rawDiagnosticsMaxHeight: Int = 180
    static let forceSyntheticCaptureForDiagnostics: Bool = false

    /// Heuristic bitrate target tuned for near-lossless retina UI content over Thunderbolt.
    /// Uses 0.20 bits-per-pixel-per-frame — 2× higher than the old H.264 setting —
    /// to achieve perceptually lossless HEVC quality for text, icons, and sharp edges.
    static func recommendedVideoBitrateBps(width: Int, height: Int, fps: Int) -> Int {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let safeFPS = max(1, fps)
        let pixelsPerSecond = Double(safeWidth * safeHeight * safeFPS)
        let target = Int(pixelsPerSecond * 0.20) // bits-per-pixel-per-frame heuristic
        return min(max(target, minVideoBitrateBps), maxVideoBitrateBps)
    }

    // MARK: - Binary Wire Format for Video Frames
    // Layout: [4-byte magic][1-byte type][4-byte header-length][header-JSON][payload-bytes]
    // This avoids base64-encoding binary data inside JSON envelopes.
    static let binaryMagic: UInt32 = 0x57445646 // "WDVF" – WiredDisplay Video Frame

    enum MessageType: UInt8, Codable, Sendable {
        case hello = 1
        case helloAck = 2
        case heartbeat = 3
        case videoFrame = 4
    }

    enum ProtocolError: Error, Sendable {
        case unsupportedVersion(received: UInt16, expected: UInt16)
    }

    /// Validates that an incoming message uses the exact protocol version we support.
    static func validate(version: UInt16) throws {
        guard version == protocolVersion else {
            throw ProtocolError.unsupportedVersion(received: version, expected: protocolVersion)
        }
    }

    /// Reads a big-endian UInt32 from a Data buffer without assuming pointer alignment.
    static func readUInt32BigEndian(from data: Data, atOffset offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }

        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: 4)

        return data[start..<end].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }
}
/// Shared envelope used by all on-wire messages.
struct NetworkEnvelope: Codable, Sendable {
    let version: UInt16
    let type: NetworkProtocol.MessageType
    let sequenceNumber: UInt64
    let payload: Data

    init(
        version: UInt16 = NetworkProtocol.protocolVersion,
        type: NetworkProtocol.MessageType,
        sequenceNumber: UInt64,
        payload: Data
    ) {
        self.version = version
        self.type = type
        self.sequenceNumber = sequenceNumber
        self.payload = payload
    }

    /// Encodes a typed payload into an envelope for transport.
    static func make<T: Encodable>(
        type: NetworkProtocol.MessageType,
        sequenceNumber: UInt64,
        payload: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> NetworkEnvelope {
        let encodedPayload = try encoder.encode(payload)
        return NetworkEnvelope(type: type, sequenceNumber: sequenceNumber, payload: encodedPayload)
    }

    /// Decodes a typed payload after validating protocol version compatibility.
    func decodePayload<T: Decodable>(
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try NetworkProtocol.validate(version: version)
        return try decoder.decode(T.self, from: payload)
    }
}

/// Sender -> receiver handshake payload with sender identity and capabilities.
struct HelloPayload: Codable, Sendable {
    let senderName: String
    let requestedProtocolVersion: UInt16
    /// Legacy fallback logical size used when the receiver cannot report its display mode.
    let targetWidth: Int
    let targetHeight: Int
}

/// Receiver display mode advertised during handshake so the sender can mirror macOS scaling.
struct ReceiverDisplayMetrics: Codable, Sendable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let backingScaleFactor: Double
    let refreshRateHz: Double?
}

/// Receiver -> sender handshake acknowledgement payload.
struct HelloAckPayload: Codable, Sendable {
    let accepted: Bool
    let acceptedProtocolVersion: UInt16
    let receiverName: String
    let reason: String?
    let displayMetrics: ReceiverDisplayMetrics?
}

/// Bidirectional keepalive payload to detect stale links.
struct HeartbeatPayload: Codable, Sendable {
    /// Time at which the sender of this heartbeat put it on the wire.
    let transmitTimestampNanoseconds: UInt64
    /// Original sender transmit time when this heartbeat is acting as a reply.
    let originTimestampNanoseconds: UInt64?
    /// Time at which the replier received the original heartbeat.
    let receiveTimestampNanoseconds: UInt64?
    /// Most recently rendered frame index on the receiver, if known.
    let renderedFrameIndex: UInt64?
    /// Sender-side capture timestamp for the most recently rendered frame.
    let renderedFrameSenderTimestampNanoseconds: UInt64?
    /// Receiver-local render timestamp for the most recently rendered frame.
    let renderedFrameReceiverTimestampNanoseconds: UInt64?
}

// MARK: - Binary Video Frame Wire Format

/// Header sent as JSON in the binary frame format (no base64 payload in here).
struct BinaryFrameHeader: Codable, Sendable {
    let frameIndex: UInt64
    let timestampNanoseconds: UInt64
    let width: Int
    let height: Int
    let isKeyFrame: Bool
    let codec: VideoCodec
    let bytesPerRow: Int
    let pixelFormat: PixelFormat
    let payloadLength: Int
    let spsLength: Int
    let ppsLength: Int
    /// HEVC-only: Video Parameter Set byte count. Nil/absent for H.264 (treated as 0).
    let vpsLength: Int?
}

/// Helpers to serialize/deserialize the binary wire format.
enum BinaryFrameWire {
    /// Serialize an EncodedFrame into binary wire format (no base64).
    /// Layout: [4-byte magic][1-byte reserved][4-byte header-length][header-JSON][VPS-bytes][SPS-bytes][PPS-bytes][payload-bytes]
    /// VPS is HEVC-only; for H.264 vpsLength is 0 and no VPS bytes are written.
    static func serialize(encodedFrame: EncodedFrame) -> Data? {
        serialize(encodedFrame: encodedFrame, includeLengthPrefix: false)
    }

    /// Serialize an EncodedFrame into the on-wire format including the 4-byte length prefix.
    static func serializeFramed(encodedFrame: EncodedFrame) -> Data? {
        serialize(encodedFrame: encodedFrame, includeLengthPrefix: true)
    }

    private static func serialize(encodedFrame: EncodedFrame, includeLengthPrefix: Bool) -> Data? {
        let vpsData = encodedFrame.hevcVPS ?? Data()
        let spsData = encodedFrame.h264SPS ?? Data()
        let ppsData = encodedFrame.h264PPS ?? Data()

        let header = BinaryFrameHeader(
            frameIndex: encodedFrame.metadata.frameIndex,
            timestampNanoseconds: encodedFrame.metadata.timestampNanoseconds,
            width: encodedFrame.metadata.width,
            height: encodedFrame.metadata.height,
            isKeyFrame: encodedFrame.isKeyFrame,
            codec: encodedFrame.codec,
            bytesPerRow: encodedFrame.sourceBytesPerRow,
            pixelFormat: encodedFrame.sourcePixelFormat,
            payloadLength: encodedFrame.payload.count,
            spsLength: spsData.count,
            ppsLength: ppsData.count,
            vpsLength: vpsData.isEmpty ? nil : vpsData.count
        )

        guard let headerJSON = try? JSONEncoder().encode(header) else { return nil }

        let payloadSize = 4 + 1 + 4 + headerJSON.count + vpsData.count + spsData.count + ppsData.count + encodedFrame.payload.count
        let totalSize = (includeLengthPrefix ? 4 : 0) + payloadSize
        var data = Data(capacity: totalSize)

        if includeLengthPrefix {
            var payloadLength = UInt32(payloadSize).bigEndian
            withUnsafeBytes(of: &payloadLength) { data.append(contentsOf: $0) }
        }

        // Magic
        var magic = NetworkProtocol.binaryMagic.bigEndian
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }

        // Reserved byte (for future use)
        data.append(0)

        // Header length
        var headerLen = UInt32(headerJSON.count).bigEndian
        withUnsafeBytes(of: &headerLen) { data.append(contentsOf: $0) }

        // Header JSON
        data.append(headerJSON)

        // VPS bytes (HEVC only, may be empty)
        data.append(vpsData)

        // SPS bytes (if any)
        data.append(spsData)

        // PPS bytes (if any)
        data.append(ppsData)

        // Payload (HEVC/H.264 NALUs or raw BGRA)
        data.append(encodedFrame.payload)

        return data
    }

    /// Deserialize binary wire format back into components needed for decoding.
    static func deserialize(data: Data) -> (header: BinaryFrameHeader, vps: Data?, sps: Data?, pps: Data?, payload: Data)? {
        guard data.count >= 9 else { return nil }
        let start = data.startIndex

        // Check magic
        guard let magic = NetworkProtocol.readUInt32BigEndian(from: data, atOffset: 0) else { return nil }
        guard magic == NetworkProtocol.binaryMagic else { return nil }

        // Skip reserved byte (index 4)

        // Header length
        guard let headerLen = NetworkProtocol.readUInt32BigEndian(from: data, atOffset: 5).map(Int.init) else {
            return nil
        }
        let headerStart = start + 9
        guard data.count >= 9 + headerLen else { return nil }

        let headerData = data[headerStart ..< headerStart + headerLen]
        guard let header = try? JSONDecoder().decode(BinaryFrameHeader.self, from: headerData) else { return nil }

        let vpsLen = header.vpsLength ?? 0
        let afterHeader = headerStart + headerLen
        let expectedTotal = 9 + headerLen + vpsLen + header.spsLength + header.ppsLength + header.payloadLength
        guard data.count >= expectedTotal else { return nil }

        let vps: Data? = vpsLen > 0 ? data[afterHeader ..< afterHeader + vpsLen] : nil
        let afterVPS = afterHeader + vpsLen
        let sps: Data? = header.spsLength > 0 ? data[afterVPS ..< afterVPS + header.spsLength] : nil
        let afterSPS = afterVPS + header.spsLength
        let pps: Data? = header.ppsLength > 0 ? data[afterSPS ..< afterSPS + header.ppsLength] : nil
        let afterPPS = afterSPS + header.ppsLength
        let payload = data[afterPPS ..< afterPPS + header.payloadLength]

        return (header, vps, sps, pps, payload)
    }
}
