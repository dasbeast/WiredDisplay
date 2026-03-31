import Foundation
import Network

/// Network.framework transport for outgoing envelopes over wired networking.
final class TransportService {
    struct QueueDebugSnapshot {
        let pendingFrames: Int
        let pendingControlFrames: Int
        let pendingCursorFrames: Int
        let pendingAudioFrames: Int
        let pendingVideoFrames: Int
        let networkInFlightCount: Int
        let droppedVideoFrames: UInt64
        let droppedCursorFrames: UInt64
    }

    private let queue = DispatchQueue(label: "wireddisplay.sender.transport")
    private let queueKey = DispatchSpecificKey<UInt8>()

    private(set) var isConnected = false

    private var connection: NWConnection?
    private var nextSequenceNumber: UInt64 = 1
    private var receiveBuffer = Data()

    private struct OutboundFrame {
        let data: Data
        let kind: OutboundFrameKind
        let isKeyFrame: Bool
    }

    private enum OutboundFrameKind {
        case control
        case cursor
        case audio
        case video
    }

    private var pendingOutboundFrames: [OutboundFrame] = []
    private var awaitingKeyFrameAfterDrop = false
    private var networkInFlightCount = 0
    private let maxNetworkInFlight = 2
    private var droppedCursorStateCount: UInt64 = 0
    private(set) var droppedOutboundFrameCount: UInt64 = 0 {
        didSet { onDroppedFrameCountChange?(droppedOutboundFrameCount) }
    }

    var onStateChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onEnvelope: ((NetworkEnvelope) -> Void)?
    var onDroppedFrameCountChange: ((UInt64) -> Void)?

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

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

            let outbound = OutboundFrame(
                data: framedData,
                kind: .video,
                isKeyFrame: encodedFrame.isKeyFrame
            )
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

            let outbound = OutboundFrame(
                data: framedData,
                kind: .audio,
                isKeyFrame: false
            )
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
                renderedFrameSenderEncodeTimestampNanoseconds: nil,
                renderedFrameReceiverArrivalTimestampNanoseconds: nil,
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

    func sendCursorState(_ cursorState: CursorStatePayload) {
        queue.async { [weak self] in
            guard let self else { return }

            do {
                let envelope = try NetworkEnvelope.make(
                    type: .cursorState,
                    sequenceNumber: self.nextSequenceNumber,
                    payload: cursorState
                )
                self.nextSequenceNumber += 1
                try self.queueEnvelopeForSend(envelope, kind: .cursor, isKeyFrame: false)
            } catch {
                self.onError?(error)
            }
        }
    }

    func debugSnapshot() -> QueueDebugSnapshot {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return makeQueueDebugSnapshotLocked()
        }

        return queue.sync {
            makeQueueDebugSnapshotLocked()
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
        networkInFlightCount = 0
        droppedCursorStateCount = 0
        droppedOutboundFrameCount = 0

        isConnected = false
        onStateChange?(false)
    }

    private func queueEnvelopeForSend(
        _ envelope: NetworkEnvelope,
        kind: OutboundFrameKind = .control,
        isKeyFrame: Bool
    ) throws {
        let encoded = try JSONEncoder().encode(envelope)
        guard encoded.count <= NetworkProtocol.maximumEnvelopeBytes else {
            throw TransportServiceError.messageTooLarge
        }

        let framedData = wrapLengthPrefix(encoded)
        enqueueOutboundFrame(
            OutboundFrame(
                data: framedData,
                kind: kind,
                isKeyFrame: isKeyFrame
            )
        )
        flushPendingIfPossible()
    }

    private func enqueueOutboundFrame(_ frame: OutboundFrame) {
        if frame.kind == .video {
            if awaitingKeyFrameAfterDrop && !frame.isKeyFrame {
                droppedOutboundFrameCount += 1
                return
            }

            if frame.isKeyFrame {
                awaitingKeyFrameAfterDrop = false
            }
        }

        if frame.kind == .cursor,
           coalesceQueuedCursorFrame(with: frame) {
            return
        }

        guard makeQueueSpaceIfNeeded(for: frame) else {
            if frame.kind == .video {
                droppedOutboundFrameCount += 1
                awaitingKeyFrameAfterDrop = true
            } else if frame.kind == .cursor {
                droppedCursorStateCount += 1
                if droppedCursorStateCount == 1 || droppedCursorStateCount.isMultiple(of: 60) {
                    print(
                        "[Transport] Dropped \(droppedCursorStateCount) cursor updates " +
                        "due to outbound queue pressure"
                    )
                }
            }
            return
        }

        pendingOutboundFrames.append(frame)
    }

    private func makeQueueSpaceIfNeeded(for frame: OutboundFrame) -> Bool {
        while pendingOutboundFrames.count >= NetworkProtocol.maxPendingOutboundFrames {
            switch frame.kind {
            case .audio:
                if dropQueuedFrame(where: { $0.kind == .cursor }, countAsVideoDrop: false) {
                    continue
                }
                // Audio should never evict video or control traffic. If we're congested,
                // replace older queued audio packets with the newest one and otherwise drop it.
                guard dropQueuedFrame(where: { $0.kind == .audio }, countAsVideoDrop: false) else {
                    return false
                }
            case .video:
                if dropQueuedFrame(where: { $0.kind == .cursor }, countAsVideoDrop: false) {
                    continue
                }
                if dropQueuedFrame(where: { $0.kind == .audio }, countAsVideoDrop: false) {
                    continue
                }
                if dropQueuedFrame(where: { $0.kind == .video && !$0.isKeyFrame }, countAsVideoDrop: true) {
                    awaitingKeyFrameAfterDrop = true
                    continue
                }
                if dropQueuedFrame(where: { $0.kind == .video }, countAsVideoDrop: true) {
                    awaitingKeyFrameAfterDrop = true
                    continue
                }
                return false
            case .control:
                if dropQueuedFrame(where: { $0.kind == .cursor }, countAsVideoDrop: false) {
                    continue
                }
                if dropQueuedFrame(where: { $0.kind == .audio }, countAsVideoDrop: false) {
                    continue
                }
                if dropQueuedFrame(where: { $0.kind == .video && !$0.isKeyFrame }, countAsVideoDrop: true) {
                    awaitingKeyFrameAfterDrop = true
                    continue
                }
                if dropQueuedFrame(where: { $0.kind == .video }, countAsVideoDrop: true) {
                    awaitingKeyFrameAfterDrop = true
                    continue
                }
                guard dropQueuedFrame(where: { $0.kind == .control }, countAsVideoDrop: false) else {
                    return false
                }
            case .cursor:
                if dropQueuedFrame(where: { $0.kind == .cursor }, countAsVideoDrop: false) {
                    continue
                }
                return false
            }
        }

        return true
    }

    private func coalesceQueuedCursorFrame(with frame: OutboundFrame) -> Bool {
        let originalCount = pendingOutboundFrames.count
        pendingOutboundFrames.removeAll { $0.kind == .cursor }
        guard pendingOutboundFrames.count != originalCount else {
            return false
        }

        pendingOutboundFrames.append(frame)
        return true
    }

    private func dropQueuedFrame(
        where shouldDrop: (OutboundFrame) -> Bool,
        countAsVideoDrop: Bool
    ) -> Bool {
        guard let dropIndex = pendingOutboundFrames.firstIndex(where: shouldDrop) else {
            return false
        }

        pendingOutboundFrames.remove(at: dropIndex)
        if countAsVideoDrop {
            droppedOutboundFrameCount += 1
        }
        return true
    }

    private func flushPendingIfPossible() {
        guard isConnected, let connection else { return }
        guard !pendingOutboundFrames.isEmpty else { return }
        // Batch all eligible frames so the OS coalesces them over the Thunderbolt bridge.
        // networkInFlightCount caps concurrent in-kernel sends to prevent kernel buffer bloat
        // (bufferbloat) that causes latency spikes under sustained 5K HEVC load.
        connection.batch {
            while !pendingOutboundFrames.isEmpty && networkInFlightCount < maxNetworkInFlight {
                guard let frame = dequeueNextOutboundFrame() else { break }
                networkInFlightCount += 1
                connection.send(content: frame.data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.networkInFlightCount -= 1
                    if let error { self.onError?(error) }
                    self.flushPendingIfPossible()
                })
            }
        }
    }

    private func dequeueNextOutboundFrame() -> OutboundFrame? {
        guard !pendingOutboundFrames.isEmpty else { return nil }

        let priorityOrder: [OutboundFrameKind] = [.control, .cursor, .audio, .video]
        for kind in priorityOrder {
            if let index = pendingOutboundFrames.firstIndex(where: { $0.kind == kind }) {
                return pendingOutboundFrames.remove(at: index)
            }
        }

        return pendingOutboundFrames.removeFirst()
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

    private func makeQueueDebugSnapshotLocked() -> QueueDebugSnapshot {
        var pendingControlFrames = 0
        var pendingCursorFrames = 0
        var pendingAudioFrames = 0
        var pendingVideoFrames = 0

        for frame in pendingOutboundFrames {
            switch frame.kind {
            case .control:
                pendingControlFrames += 1
            case .cursor:
                pendingCursorFrames += 1
            case .audio:
                pendingAudioFrames += 1
            case .video:
                pendingVideoFrames += 1
            }
        }

        return QueueDebugSnapshot(
            pendingFrames: pendingOutboundFrames.count,
            pendingControlFrames: pendingControlFrames,
            pendingCursorFrames: pendingCursorFrames,
            pendingAudioFrames: pendingAudioFrames,
            pendingVideoFrames: pendingVideoFrames,
            networkInFlightCount: networkInFlightCount,
            droppedVideoFrames: droppedOutboundFrameCount,
            droppedCursorFrames: droppedCursorStateCount
        )
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
    private var pendingFrames: [EncodedFrame] = []
    private var awaitingKeyFrameAfterDrop = false
    private var networkInFlightCount = 0
    private let maxNetworkInFlight = 2
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
        pendingFrames.removeAll(keepingCapacity: false)
        awaitingKeyFrameAfterDrop = false
        networkInFlightCount = 0
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

    /// Clear stale queued deltas at each keyframe boundary so the next UDP keyframe establishes
    /// a fresh decode baseline for subsequent interframes.
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
        guard isConnected, let connection else { return }
        // networkInFlightCount caps concurrent datagram bursts to prevent kernel buffer bloat
        // under high-motion 5K HEVC load. Each frame's batch counts as one in-flight unit.
        while !pendingFrames.isEmpty && networkInFlightCount < maxNetworkInFlight {
            let frameToSend = pendingFrames.removeFirst()
            guard let datagrams = VideoDatagramWire.serialize(encodedFrame: frameToSend) else {
                onError?(TransportServiceError.serializationFailed)
                continue
            }

            if frameToSend.metadata.frameIndex % 30 == 0 {
                print(
                    "[VideoDatagramTransport] Sending frame \(frameToSend.metadata.frameIndex): " +
                    "codec=\(frameToSend.codec), datagrams=\(datagrams.count)"
                )
            }

            let transmissionCount = frameToSend.isKeyFrame
                ? max(1, NetworkProtocol.udpKeyFrameSendRedundancy)
                : 1

            networkInFlightCount += 1
            connection.batch {
                for transmissionIndex in 0..<transmissionCount {
                    for (index, datagram) in datagrams.enumerated() {
                        let isLastDatagram = transmissionIndex == transmissionCount - 1 && index == datagrams.count - 1
                        let completion: NWConnection.SendCompletion = isLastDatagram
                            ? .contentProcessed { [weak self] error in
                                guard let self else { return }
                                self.queue.async {
                                    self.networkInFlightCount -= 1
                                    if let error { self.onError?(error) }
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
}
