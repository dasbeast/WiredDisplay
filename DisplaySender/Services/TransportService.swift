import Foundation
import Network

/// Network.framework transport for outgoing envelopes over wired networking.
final class TransportService {
    private let queue = DispatchQueue(label: "wireddisplay.sender.transport")

    private(set) var isConnected = false

    private var connection: NWConnection?
    private var nextSequenceNumber: UInt64 = 1
    private var receiveBuffer = Data()

    private struct OutboundFrame {
        let data: Data
        let isKeyFrame: Bool
    }

    private var pendingOutboundFrames: [OutboundFrame] = []
    private var awaitingKeyFrameAfterDrop = false
    private var sendInFlight = false
    private(set) var droppedOutboundFrameCount: UInt64 = 0 {
        didSet { onDroppedFrameCountChange?(droppedOutboundFrameCount) }
    }

    var onStateChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onEnvelope: ((NetworkEnvelope) -> Void)?
    var onDroppedFrameCountChange: ((UInt64) -> Void)?

    func connect(host: String, port: UInt16 = NetworkProtocol.defaultPort) {
        queue.async { [weak self] in
            guard let self else { return }

            self.disconnectLocked()

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.onError?(TransportServiceError.invalidEndpoint)
                return
            }

            let parameters = NetworkDiagnostics.lowLatencyTCPParameters()

            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.onStateChange?(true)
                    self.receiveBuffer.removeAll(keepingCapacity: false)
                    self.receiveNextChunk(on: connection)
                    self.flushPendingIfPossible()
                case .failed(let error):
                    self.isConnected = false
                    self.onStateChange?(false)
                    self.onError?(error)
                case .cancelled:
                    self.isConnected = false
                    self.onStateChange?(false)
                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }
    }

    /// Sends an encoded video frame using the binary wire format (no JSON/base64 for payload data).
    /// Thread-safe: the frame is serialized and queued entirely on the transport queue.
    func sendVideoFrame(_ encodedFrame: EncodedFrame) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let framedData = BinaryFrameWire.serializeFramed(encodedFrame: encodedFrame) else {
                print("[Transport] Failed to serialize frame \(encodedFrame.metadata.frameIndex)")
                self.onError?(TransportServiceError.serializationFailed)
                return
            }

            let wirePayloadBytes = framedData.count - 4
            guard wirePayloadBytes <= NetworkProtocol.maximumMessageBytes else {
                print(
                    "[Transport] Frame \(encodedFrame.metadata.frameIndex) too large: " +
                    "\(wirePayloadBytes) bytes (limit: \(NetworkProtocol.maximumMessageBytes))"
                )
                self.onError?(TransportServiceError.messageTooLarge)
                return
            }

            if encodedFrame.metadata.frameIndex % 30 == 0 {
                print(
                    "[Transport] Sending frame \(encodedFrame.metadata.frameIndex): " +
                    "codec=\(encodedFrame.codec), wireSize=\(wirePayloadBytes) bytes, connected=\(self.isConnected)"
                )
            }

            let outbound = OutboundFrame(data: framedData, isKeyFrame: encodedFrame.isKeyFrame)
            self.enqueueOutboundFrame(outbound)
            self.flushPendingIfPossible()
        }
    }

    func sendAudioPacket(_ audioPacket: AudioPacket) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let framedData = BinaryAudioWire.serializeFramed(audioPacket: audioPacket) else {
                self.onError?(TransportServiceError.serializationFailed)
                return
            }

            let wirePayloadBytes = framedData.count - 4
            guard wirePayloadBytes <= NetworkProtocol.maximumMessageBytes else {
                self.onError?(TransportServiceError.messageTooLarge)
                return
            }

            let outbound = OutboundFrame(data: framedData, isKeyFrame: true)
            self.enqueueOutboundFrame(outbound)
            self.flushPendingIfPossible()
        }
    }

    func sendHello(
        senderName: String,
        preferredVideoTransport: NetworkProtocol.VideoTransportMode,
        targetWidth: Int,
        targetHeight: Int
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            let payload = HelloPayload(
                senderName: senderName,
                requestedProtocolVersion: NetworkProtocol.protocolVersion,
                preferredVideoTransport: preferredVideoTransport,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )

            do {
                let envelope = try NetworkEnvelope.make(
                    type: .hello,
                    sequenceNumber: self.nextSequenceNumber,
                    payload: payload
                )
                self.nextSequenceNumber += 1
                try self.queueEnvelopeForSend(envelope, isKeyFrame: true)
            } catch {
                self.onError?(error)
            }
        }
    }

    func sendHeartbeat() {
        queue.async { [weak self] in
            guard let self else { return }

            let payload = HeartbeatPayload(
                transmitTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                originTimestampNanoseconds: nil,
                receiveTimestampNanoseconds: nil,
                renderedFrameIndex: nil,
                renderedFrameSenderTimestampNanoseconds: nil,
                renderedFrameReceiverTimestampNanoseconds: nil
            )

            do {
                let envelope = try NetworkEnvelope.make(
                    type: .heartbeat,
                    sequenceNumber: self.nextSequenceNumber,
                    payload: payload
                )
                self.nextSequenceNumber += 1
                try self.queueEnvelopeForSend(envelope, isKeyFrame: true)
            } catch {
                self.onError?(error)
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.disconnectLocked()
        }
    }

    private func disconnectLocked() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        pendingOutboundFrames.removeAll(keepingCapacity: false)
        awaitingKeyFrameAfterDrop = false
        sendInFlight = false
        droppedOutboundFrameCount = 0

        isConnected = false
        onStateChange?(false)
    }

    private func queueEnvelopeForSend(_ envelope: NetworkEnvelope, isKeyFrame: Bool) throws {
        let encoded = try JSONEncoder().encode(envelope)
        guard encoded.count <= NetworkProtocol.maximumEnvelopeBytes else {
            throw TransportServiceError.messageTooLarge
        }

        let framedData = wrapLengthPrefix(encoded)
        enqueueOutboundFrame(OutboundFrame(data: framedData, isKeyFrame: isKeyFrame))
        flushPendingIfPossible()
    }

    private func enqueueOutboundFrame(_ frame: OutboundFrame) {
        if awaitingKeyFrameAfterDrop && !frame.isKeyFrame {
            droppedOutboundFrameCount += 1
            return
        }

        if frame.isKeyFrame {
            awaitingKeyFrameAfterDrop = false
        }

        // When the queue is full, shed the oldest non-keyframes instead of dropping everything.
        // This preserves recent frames and avoids the costly "drop-all → await keyframe" cascade.
        while pendingOutboundFrames.count >= NetworkProtocol.maxPendingOutboundFrames {
            if let dropIndex = pendingOutboundFrames.firstIndex(where: { !$0.isKeyFrame }) {
                pendingOutboundFrames.remove(at: dropIndex)
                droppedOutboundFrameCount += 1
            } else {
                // All pending frames are keyframes — drop the oldest one.
                pendingOutboundFrames.removeFirst()
                droppedOutboundFrameCount += 1
            }
        }

        pendingOutboundFrames.append(frame)
    }

    private func flushPendingIfPossible() {
        guard isConnected else { return }
        guard !sendInFlight else { return }
        guard let connection else { return }
        guard !pendingOutboundFrames.isEmpty else { return }

        sendInFlight = true
        let frame = pendingOutboundFrames.removeFirst()

        connection.send(content: frame.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sendInFlight = false

            if let error {
                self.onError?(error)
                return
            }

            self.flushPendingIfPossible()
        })
    }

    private func receiveNextChunk(on connection: NWConnection) {
        // Smaller receive chunks reduce burst buffering and help interactive pacing.
        connection.receive(minimumIncompleteLength: 1, maximumLength: NetworkProtocol.transportReceiveChunkBytes) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.onError?(error)
                return
            }

            if let content, !content.isEmpty {
                self.receiveBuffer.append(content)
                self.drainBufferedEnvelopes()
            }

            if isComplete {
                connection.cancel()
                self.receiveBuffer.removeAll(keepingCapacity: false)
                self.isConnected = false
                self.onStateChange?(false)
                return
            }

            self.receiveNextChunk(on: connection)
        }
    }

    private func drainBufferedEnvelopes() {
        while true {
            guard receiveBuffer.count >= 4 else { return }
            let length = Int(readLengthPrefix(from: receiveBuffer))
            guard length <= NetworkProtocol.maximumMessageBytes else {
                receiveBuffer.removeAll(keepingCapacity: false)
                onError?(TransportServiceError.messageTooLarge)
                return
            }

            let totalFrameLength = 4 + length
            guard receiveBuffer.count >= totalFrameLength else { return }

            let payload = receiveBuffer.subdata(in: 4..<totalFrameLength)
            receiveBuffer.removeSubrange(0..<totalFrameLength)

            do {
                let envelope = try JSONDecoder().decode(NetworkEnvelope.self, from: payload)
                try NetworkProtocol.validate(version: envelope.version)
                onEnvelope?(envelope)
            } catch {
                onError?(error)
            }
        }
    }

    private func wrapLengthPrefix(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    private func readLengthPrefix(from data: Data) -> UInt32 {
        NetworkProtocol.readUInt32BigEndian(from: data, atOffset: 0) ?? 0
    }
}

enum TransportServiceError: Error {
    case invalidEndpoint
    case notConnected
    case messageTooLarge
    case serializationFailed
}

/// UDP transport for low-latency encoded video delivery.
final class VideoDatagramTransportService {
    private let queue = DispatchQueue(label: "wireddisplay.sender.videoDatagram")

    private(set) var isConnected = false

    private var connection: NWConnection?
    private var connectedHost: String?
    private var connectedPort: UInt16?
    private var sendInFlight = false
    private var pendingFrames: [EncodedFrame] = []
    private var awaitingKeyFrameAfterDrop = false
    private var droppedOutboundFrameCount: UInt64 = 0

    var onStateChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onDroppedFrameCountChange: ((UInt64) -> Void)?

    func connect(host: String, port: UInt16 = NetworkProtocol.defaultPort) {
        if connection != nil, connectedHost == host, connectedPort == port {
            return
        }

        disconnect()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onError?(TransportServiceError.invalidEndpoint)
            return
        }

        let parameters = NetworkDiagnostics.lowLatencyUDPParameters()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection
        connectedHost = host
        connectedPort = port

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.onStateChange?(true)
                self.flushPendingFrameIfPossible()
            case .failed(let error):
                self.isConnected = false
                self.onStateChange?(false)
                self.onError?(error)
            case .cancelled:
                self.isConnected = false
                self.onStateChange?(false)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connectedHost = nil
        connectedPort = nil
        isConnected = false
        sendInFlight = false
        pendingFrames.removeAll(keepingCapacity: false)
        awaitingKeyFrameAfterDrop = false
        droppedOutboundFrameCount = 0
        onStateChange?(false)
    }

    func sendVideoFrame(_ encodedFrame: EncodedFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            self.enqueueOutboundFrame(encodedFrame)
            self.flushPendingFrameIfPossible()
        }
    }

    /// The UDP path only carries interframes in hybrid mode. When the sender emits a
    /// recovery keyframe over TCP, clear stale UDP deltas and allow the next post-keyframe
    /// interframes to flow again.
    func noteKeyFrameBoundary() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFrames.removeAll(keepingCapacity: false)
            self.awaitingKeyFrameAfterDrop = false
        }
    }

    private func enqueueOutboundFrame(_ encodedFrame: EncodedFrame) {
        if awaitingKeyFrameAfterDrop && !encodedFrame.isKeyFrame {
            droppedOutboundFrameCount += 1
            onDroppedFrameCountChange?(droppedOutboundFrameCount)
            return
        }

        if encodedFrame.isKeyFrame {
            awaitingKeyFrameAfterDrop = false
        }

        while pendingFrames.count >= NetworkProtocol.maxPendingOutboundFrames {
            if let dropIndex = pendingFrames.firstIndex(where: { !$0.isKeyFrame }) {
                pendingFrames.remove(at: dropIndex)
            } else {
                pendingFrames.removeFirst()
            }
            droppedOutboundFrameCount += 1
            awaitingKeyFrameAfterDrop = true
            onDroppedFrameCountChange?(droppedOutboundFrameCount)
        }

        pendingFrames.append(encodedFrame)
    }

    private func flushPendingFrameIfPossible() {
        guard isConnected else { return }
        guard !sendInFlight else { return }
        guard let connection, !pendingFrames.isEmpty else { return }
        let frameToSend = pendingFrames.removeFirst()
        guard let datagrams = VideoDatagramWire.serialize(encodedFrame: frameToSend) else {
            onError?(TransportServiceError.serializationFailed)
            return
        }

        sendInFlight = true

        if frameToSend.metadata.frameIndex % 30 == 0 {
            print(
                "[VideoDatagramTransport] Sending frame \(frameToSend.metadata.frameIndex): " +
                "codec=\(frameToSend.codec), datagrams=\(datagrams.count)"
            )
        }

        let transmissionCount = frameToSend.isKeyFrame
            ? max(1, NetworkProtocol.udpKeyFrameSendRedundancy)
            : 1

        connection.batch {
            for transmissionIndex in 0..<transmissionCount {
                for (index, datagram) in datagrams.enumerated() {
                    let isLastDatagram = transmissionIndex == transmissionCount - 1 && index == datagrams.count - 1
                    let completion: NWConnection.SendCompletion = isLastDatagram
                        ? .contentProcessed { [weak self] error in
                            guard let self else { return }
                            self.queue.async {
                                self.sendInFlight = false
                                if let error {
                                    self.onError?(error)
                                    return
                                }
                                self.flushPendingFrameIfPossible()
                            }
                        }
                        : .idempotent
                    connection.send(content: datagram, completion: completion)
                }
            }
        }
    }
}
