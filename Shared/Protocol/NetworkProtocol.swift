import Foundation

/// Defines wire-level messages and protocol validation shared by sender and receiver.
enum NetworkProtocol {
    static let protocolVersion: UInt16 = 1
    static let defaultPort: UInt16 = 50999
    static let maximumEnvelopeBytes: Int = 16_777_216  // 16 MB – H.264 key frames can be large
    static let maximumMessageBytes: Int = 33_554_432  // 32 MB – binary framed messages
    static let heartbeatIntervalSeconds: TimeInterval = 1.0
    static let heartbeatTimeoutSeconds: TimeInterval = 5.0
    static let reconnectDelaySeconds: TimeInterval = 2.0
    static let maxPendingOutboundFrames: Int = 4
    static let targetFramesPerSecond: Int = 30
    static let keyFrameIntervalSeconds: Int = 4
    static let captureFramesPerSecond: Int = 30
    static let targetVideoBitrateBps: Int = 40_000_000
    static let allowLoopbackForLocalTesting: Bool = true
    static let preferRawFrameTransportForDiagnostics: Bool = false
    static let rawDiagnosticsMaxWidth: Int = 320
    static let rawDiagnosticsMaxHeight: Int = 180
    static let forceSyntheticCaptureForDiagnostics: Bool = false

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
    let targetWidth: Int
    let targetHeight: Int
}

/// Receiver -> sender handshake acknowledgement payload.
struct HelloAckPayload: Codable, Sendable {
    let accepted: Bool
    let acceptedProtocolVersion: UInt16
    let receiverName: String
    let reason: String?
}

/// Bidirectional keepalive payload to detect stale links.
struct HeartbeatPayload: Codable, Sendable {
    let timestampNanoseconds: UInt64
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
}

/// Helpers to serialize/deserialize the binary wire format.
enum BinaryFrameWire {
    /// Serialize an EncodedFrame into binary wire format (no base64).
    /// Layout: [4-byte magic][1-byte reserved][4-byte header-length][header-JSON][SPS-bytes][PPS-bytes][payload-bytes]
    static func serialize(encodedFrame: EncodedFrame) -> Data? {
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
            ppsLength: ppsData.count
        )

        guard let headerJSON = try? JSONEncoder().encode(header) else { return nil }

        // Total: 4 magic + 1 reserved + 4 header-length + headerJSON + sps + pps + payload
        let totalSize = 4 + 1 + 4 + headerJSON.count + spsData.count + ppsData.count + encodedFrame.payload.count
        var data = Data(capacity: totalSize)

        // Magic
        var magic = NetworkProtocol.binaryMagic.bigEndian
        data.append(Data(bytes: &magic, count: 4))

        // Reserved byte (for future use)
        data.append(0)

        // Header length
        var headerLen = UInt32(headerJSON.count).bigEndian
        data.append(Data(bytes: &headerLen, count: 4))

        // Header JSON
        data.append(headerJSON)

        // SPS bytes (if any)
        data.append(spsData)

        // PPS bytes (if any)
        data.append(ppsData)

        // Payload (H.264 NALUs or raw BGRA)
        data.append(encodedFrame.payload)

        return data
    }

    /// Deserialize binary wire format back into components needed for decoding.
    static func deserialize(data: Data) -> (header: BinaryFrameHeader, sps: Data?, pps: Data?, payload: Data)? {
        guard data.count >= 9 else { return nil }

        // Check magic
        let magic = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard magic == NetworkProtocol.binaryMagic else { return nil }

        // Skip reserved byte (index 4)

        // Header length
        let headerLen = Int(Data(data[5..<9]).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        let headerStart = 9
        guard data.count >= headerStart + headerLen else { return nil }

        let headerData = Data(data[headerStart ..< headerStart + headerLen])
        guard let header = try? JSONDecoder().decode(BinaryFrameHeader.self, from: headerData) else { return nil }

        let afterHeader = headerStart + headerLen
        let expectedTotal = afterHeader + header.spsLength + header.ppsLength + header.payloadLength
        guard data.count >= expectedTotal else { return nil }

        let sps: Data? = header.spsLength > 0 ? Data(data[afterHeader ..< afterHeader + header.spsLength]) : nil
        let afterSPS = afterHeader + header.spsLength
        let pps: Data? = header.ppsLength > 0 ? Data(data[afterSPS ..< afterSPS + header.ppsLength]) : nil
        let afterPPS = afterSPS + header.ppsLength
        let payload = Data(data[afterPPS ..< afterPPS + header.payloadLength])

        return (header, sps, pps, payload)
    }
}
