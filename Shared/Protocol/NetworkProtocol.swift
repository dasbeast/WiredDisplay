import Foundation

/// Defines wire-level messages and protocol validation shared by sender and receiver.
enum NetworkProtocol {
    static let protocolVersion: UInt16 = 1
    static let defaultPort: UInt16 = 50999
    static let maximumEnvelopeBytes: Int = 16_777_216  // 16 MB – H.264 key frames can be large
    static let heartbeatIntervalSeconds: TimeInterval = 1.0
    static let heartbeatTimeoutSeconds: TimeInterval = 5.0
    static let reconnectDelaySeconds: TimeInterval = 2.0
    static let maxPendingOutboundFrames: Int = 4
    static let targetFramesPerSecond: Int = 30
    static let keyFrameIntervalSeconds: Int = 2
    static let captureFramesPerSecond: Int = 30
    static let allowLoopbackForLocalTesting: Bool = true
    static let preferRawFrameTransportForDiagnostics: Bool = false
    static let rawDiagnosticsMaxWidth: Int = 320
    static let rawDiagnosticsMaxHeight: Int = 180
    static let forceSyntheticCaptureForDiagnostics: Bool = false

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

