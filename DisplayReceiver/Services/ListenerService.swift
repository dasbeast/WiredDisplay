import Foundation
import Network

/// Network.framework listener for incoming frame/control envelopes over wired networking.
final class ListenerService {
    private let queue = DispatchQueue(label: "wireddisplay.receiver.listener")

    private(set) var isListening = false
    private(set) var listeningPort: UInt16 = NetworkProtocol.defaultPort

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var receiveBuffer = Data()
    /// Logical start of unconsumed data within receiveBuffer.
    /// Avoids O(n) memmove on every consumed frame; the buffer is compacted
    /// periodically once the consumed prefix exceeds a threshold.
    private var receiveBufferReadOffset = 0

    var onStateChange: ((Bool) -> Void)?
    var onConnectionClosed: (() -> Void)?
    var onEnvelope: ((NetworkEnvelope) -> Void)?
    var onBinaryVideoFrame: ((BinaryFrameHeader, Data?, Data?, Data?, Data) -> Void)?
    var onBinaryAudioFrame: ((BinaryAudioHeader, Data) -> Void)?
    var onError: ((Error) -> Void)?

    func startListening(port: UInt16 = NetworkProtocol.defaultPort) {
        stopListening()

        do {
            let nwPort = try NWEndpoint.Port(rawValue: port).unwrapOrThrow()
            let parameters = NetworkDiagnostics.lowLatencyTCPParameters()

            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener
            self.listeningPort = port

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                    self.onStateChange?(true)
                case .failed(let error):
                    self.isListening = false
                    self.onStateChange?(false)
                    self.onError?(error)
                case .cancelled:
                    self.isListening = false
                    self.onStateChange?(false)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.activate(connection: connection)
            }

            listener.start(queue: queue)
        } catch {
            isListening = false
            onStateChange?(false)
            onError?(error)
        }
    }

    func stopListening() {
        activeConnection?.cancel()
        activeConnection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        receiveBufferReadOffset = 0

        listener?.cancel()
        listener = nil

        isListening = false
        onStateChange?(false)
    }

    func sendHelloAck(
        accepted: Bool,
        reason: String?,
        displayMetrics: ReceiverDisplayMetrics? = nil,
        negotiatedVideoTransport: NetworkProtocol.VideoTransportMode = .tcp
    ) {
        let payload = HelloAckPayload(
            accepted: accepted,
            acceptedProtocolVersion: NetworkProtocol.protocolVersion,
            receiverName: Host.current().localizedName ?? "DisplayReceiver",
            reason: reason,
            displayMetrics: displayMetrics,
            negotiatedVideoTransport: negotiatedVideoTransport
        )

        do {
            let envelope = try NetworkEnvelope.make(type: .helloAck, sequenceNumber: 0, payload: payload)
            try sendEnvelope(envelope)
        } catch {
            onError?(error)
        }
    }

    func sendHeartbeatReply(
        originTimestampNanoseconds: UInt64,
        receiveTimestampNanoseconds: UInt64,
        renderedFrameIndex: UInt64?,
        renderedFrameSenderTimestampNanoseconds: UInt64?,
        renderedFrameSenderEncodeTimestampNanoseconds: UInt64?,
        renderedFrameReceiverArrivalTimestampNanoseconds: UInt64?,
        renderedFrameReceiverTimestampNanoseconds: UInt64?
    ) {
        let payload = HeartbeatPayload(
            transmitTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            originTimestampNanoseconds: originTimestampNanoseconds,
            receiveTimestampNanoseconds: receiveTimestampNanoseconds,
            renderedFrameIndex: renderedFrameIndex,
            renderedFrameSenderTimestampNanoseconds: renderedFrameSenderTimestampNanoseconds,
            renderedFrameSenderEncodeTimestampNanoseconds: renderedFrameSenderEncodeTimestampNanoseconds,
            renderedFrameReceiverArrivalTimestampNanoseconds: renderedFrameReceiverArrivalTimestampNanoseconds,
            renderedFrameReceiverTimestampNanoseconds: renderedFrameReceiverTimestampNanoseconds
        )

        do {
            let envelope = try NetworkEnvelope.make(type: .heartbeat, sequenceNumber: 0, payload: payload)
            try sendEnvelope(envelope)
        } catch {
            onError?(error)
        }
    }

    func sendKeyFrameRequest(failedFrameIndex: UInt64?, reason: String?) {
        let payload = KeyFrameRequestPayload(
            failedFrameIndex: failedFrameIndex,
            reason: reason,
            requestedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )

        do {
            let envelope = try NetworkEnvelope.make(type: .requestKeyFrame, sequenceNumber: 0, payload: payload)
            try sendEnvelope(envelope)
        } catch {
            onError?(error)
        }
    }

    private func activate(connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        receiveBuffer.removeAll(keepingCapacity: false)
        receiveBufferReadOffset = 0

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.onError?(error)
            }
        }

        connection.start(queue: queue)
        receiveNextChunk(on: connection)
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
                self.activeConnection = nil
                self.receiveBuffer.removeAll(keepingCapacity: false)
                self.receiveBufferReadOffset = 0
                self.onConnectionClosed?()
                return
            }

            self.receiveNextChunk(on: connection)
        }
    }

    private func sendEnvelope(_ envelope: NetworkEnvelope) throws {
        guard let activeConnection else {
            throw ListenerServiceError.noActiveConnection
        }

        let encoded = try JSONEncoder().encode(envelope)
        guard encoded.count <= NetworkProtocol.maximumEnvelopeBytes else {
            throw ListenerServiceError.messageTooLarge
        }

        let framed = wrapLengthPrefix(encoded)
        activeConnection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onError?(error)
            }
        })
    }

    private func drainBufferedEnvelopes() {
        // Use receiveBufferReadOffset to avoid O(n) memmove on every consumed frame.
        // The buffer is only physically compacted once the unconsumed prefix reaches
        // 4 MB, amortising the shift cost across thousands of frames instead of
        // paying it on every single consume.
        let compactThreshold = 4 * 1024 * 1024

        while true {
            let available = receiveBuffer.count - receiveBufferReadOffset
            guard available >= 4 else { return }

            let length = Int(
                NetworkProtocol.readUInt32BigEndian(from: receiveBuffer, atOffset: receiveBufferReadOffset) ?? 0
            )
            guard length <= NetworkProtocol.maximumMessageBytes else {
                receiveBuffer.removeAll(keepingCapacity: false)
                receiveBufferReadOffset = 0
                onError?(ListenerServiceError.messageTooLarge)
                return
            }

            let totalLength = 4 + length
            guard available >= totalLength else { return }

            let payloadStart = receiveBufferReadOffset + 4
            let payloadEnd   = receiveBufferReadOffset + totalLength
            let payload = receiveBuffer[payloadStart..<payloadEnd]
            receiveBufferReadOffset += totalLength

            // Compact the backing buffer once enough prefix has been consumed.
            if receiveBufferReadOffset >= compactThreshold {
                receiveBuffer.removeSubrange(0..<receiveBufferReadOffset)
                receiveBufferReadOffset = 0
            }

            // Check if this is a binary video frame (starts with magic bytes)
            if payload.count >= 4 {
                if NetworkProtocol.readUInt32BigEndian(from: payload, atOffset: 0) == NetworkProtocol.binaryMagic {
                    if let result = BinaryFrameWire.deserialize(data: payload) {
                        onBinaryVideoFrame?(result.header, result.vps, result.sps, result.pps, result.payload)
                    }
                    continue
                }

                if NetworkProtocol.readUInt32BigEndian(from: payload, atOffset: 0) == NetworkProtocol.binaryAudioMagic {
                    if let result = BinaryAudioWire.deserialize(data: payload) {
                        onBinaryAudioFrame?(result.header, result.payload)
                    }
                    continue
                }
            }

            // Otherwise it's a JSON envelope (hello, heartbeat, etc.)
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

private extension Optional {
    func unwrapOrThrow() throws -> Wrapped {
        guard let value = self else {
            throw ListenerServiceError.invalidEndpoint
        }
        return value
    }
}

enum ListenerServiceError: Error {
    case invalidEndpoint
    case noActiveConnection
    case messageTooLarge
}

/// UDP listener for low-latency binary video datagrams.
final class VideoDatagramListenerService {
    private let queue = DispatchQueue(label: "wireddisplay.receiver.videoDatagram")
    private let reassembler = VideoDatagramReassembler()

    private(set) var isListening = false
    private(set) var listeningPort: UInt16 = NetworkProtocol.defaultPort
    /// Only advertise UDP once the listener is actually ready on the socket.
    var canAcceptDatagrams: Bool { isListening }

    private var listener: NWListener?
    private var activeConnection: NWConnection?

    var onStateChange: ((Bool) -> Void)?
    var onBinaryVideoFrame: ((BinaryFrameHeader, Data?, Data?, Data?, Data) -> Void)?
    var onCursorState: ((CursorStatePayload) -> Void)?
    var onError: ((Error) -> Void)?

    func startListening(port: UInt16 = NetworkProtocol.defaultPort) {
        stopListening()

        do {
            let nwPort = try NWEndpoint.Port(rawValue: port).unwrapOrThrow()
            let parameters = NetworkDiagnostics.lowLatencyUDPParameters()

            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener
            self.listeningPort = port

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                    self.onStateChange?(true)
                case .failed(let error):
                    self.isListening = false
                    self.onStateChange?(false)
                    self.onError?(error)
                case .cancelled:
                    self.isListening = false
                    self.onStateChange?(false)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.activate(connection: connection)
            }

            listener.start(queue: queue)
        } catch {
            isListening = false
            onStateChange?(false)
            onError?(error)
        }
    }

    func stopListening() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        reassembler.reset()
        isListening = false
        onStateChange?(false)
    }

    private func activate(connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        reassembler.reset()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.onError?(error)
            }
        }

        connection.start(queue: queue)
        receiveNextMessage(on: connection)
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }

            if let error {
                self.onError?(error)
                return
            }

            if let content, !content.isEmpty {
                self.handle(datagram: content)
            }

            self.receiveNextMessage(on: connection)
        }
    }

    private func handle(datagram: Data) {
        if let chunk = VideoDatagramWire.deserialize(datagram: datagram) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let frameData = reassembler.insert(
                frameIndex: chunk.frameIndex,
                chunkIndex: chunk.chunkIndex,
                chunkCount: chunk.chunkCount,
                payload: chunk.payload,
                arrivalNanoseconds: now
            ) else {
                return
            }

            guard let result = BinaryFrameWire.deserialize(data: frameData) else {
                return
            }

            onBinaryVideoFrame?(result.header, result.vps, result.sps, result.pps, result.payload)
            return
        }

        guard let envelope = try? JSONDecoder().decode(NetworkEnvelope.self, from: datagram) else {
            return
        }
        guard envelope.type == .cursorState else { return }

        do {
            let cursorState = try envelope.decodePayload(as: CursorStatePayload.self)
            onCursorState?(cursorState)
        } catch {
            onError?(error)
        }
    }
}

private final class VideoDatagramReassembler {
    private struct Assembly {
        let firstArrivalNanoseconds: UInt64
        let chunkCount: Int
        var chunks: [Data?]
        var receivedChunkCount: Int
    }

    private let lock = NSLock()
    private var assemblies: [UInt64: Assembly] = [:]
    private var newestFrameIndex: UInt64 = 0

    func reset() {
        lock.lock()
        assemblies.removeAll(keepingCapacity: false)
        newestFrameIndex = 0
        lock.unlock()
    }

    func insert(
        frameIndex: UInt64,
        chunkIndex: Int,
        chunkCount: Int,
        payload: Data,
        arrivalNanoseconds: UInt64
    ) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        pruneExpiredAssemblies(now: arrivalNanoseconds)

        if frameIndex > newestFrameIndex {
            newestFrameIndex = frameIndex
            let oldestAllowedFrameIndex = frameIndex > UInt64(NetworkProtocol.videoDatagramMaxOutstandingFrames - 1)
                ? frameIndex - UInt64(NetworkProtocol.videoDatagramMaxOutstandingFrames - 1)
                : 0
            assemblies = assemblies.filter { $0.key >= oldestAllowedFrameIndex }
        }

        var assembly = assemblies[frameIndex] ?? Assembly(
            firstArrivalNanoseconds: arrivalNanoseconds,
            chunkCount: chunkCount,
            chunks: Array(repeating: nil, count: chunkCount),
            receivedChunkCount: 0
        )

        if assembly.chunkCount != chunkCount {
            assembly = Assembly(
                firstArrivalNanoseconds: arrivalNanoseconds,
                chunkCount: chunkCount,
                chunks: Array(repeating: nil, count: chunkCount),
                receivedChunkCount: 0
            )
        }

        if assembly.chunks[chunkIndex] == nil {
            assembly.chunks[chunkIndex] = payload
            assembly.receivedChunkCount += 1
        }

        assemblies[frameIndex] = assembly

        trimAssemblyWindow()

        guard assembly.receivedChunkCount == chunkCount else {
            return nil
        }

        assemblies.removeValue(forKey: frameIndex)

        let totalBytes = assembly.chunks.reduce(0) { partial, chunk in
            partial + (chunk?.count ?? 0)
        }
        var frameData = Data(capacity: totalBytes)
        for chunk in assembly.chunks {
            guard let chunk else { return nil }
            frameData.append(chunk)
        }
        return frameData
    }

    private func pruneExpiredAssemblies(now: UInt64) {
        assemblies = assemblies.filter { _, assembly in
            let age = now >= assembly.firstArrivalNanoseconds ? now - assembly.firstArrivalNanoseconds : 0
            return age <= NetworkProtocol.videoDatagramAssemblyTimeoutNanoseconds
        }
    }

    private func trimAssemblyWindow() {
        guard assemblies.count > NetworkProtocol.videoDatagramMaxOutstandingFrames else {
            return
        }

        let sortedKeys = assemblies.keys.sorted()
        let keysToRemove = sortedKeys.prefix(max(0, sortedKeys.count - NetworkProtocol.videoDatagramMaxOutstandingFrames))
        for key in keysToRemove {
            assemblies.removeValue(forKey: key)
        }
    }
}
