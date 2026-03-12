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

    var onStateChange: ((Bool) -> Void)?
    var onEnvelope: ((NetworkEnvelope) -> Void)?
    var onBinaryVideoFrame: ((BinaryFrameHeader, Data?, Data?, Data?, Data) -> Void)?
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

        listener?.cancel()
        listener = nil

        isListening = false
        onStateChange?(false)
    }

    func sendHelloAck(accepted: Bool, reason: String?) {
        let payload = HelloAckPayload(
            accepted: accepted,
            acceptedProtocolVersion: NetworkProtocol.protocolVersion,
            receiverName: Host.current().localizedName ?? "DisplayReceiver",
            reason: reason
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
        renderedFrameReceiverTimestampNanoseconds: UInt64?
    ) {
        let payload = HeartbeatPayload(
            transmitTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            originTimestampNanoseconds: originTimestampNanoseconds,
            receiveTimestampNanoseconds: receiveTimestampNanoseconds,
            renderedFrameIndex: renderedFrameIndex,
            renderedFrameSenderTimestampNanoseconds: renderedFrameSenderTimestampNanoseconds,
            renderedFrameReceiverTimestampNanoseconds: renderedFrameReceiverTimestampNanoseconds
        )

        do {
            let envelope = try NetworkEnvelope.make(type: .heartbeat, sequenceNumber: 0, payload: payload)
            try sendEnvelope(envelope)
        } catch {
            onError?(error)
        }
    }

    private func activate(connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        receiveBuffer.removeAll(keepingCapacity: false)

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
        while true {
            guard receiveBuffer.count >= 4 else { return }
            let length = Int(readLengthPrefix(from: receiveBuffer))
            guard length <= NetworkProtocol.maximumMessageBytes else {
                receiveBuffer.removeAll(keepingCapacity: false)
                onError?(ListenerServiceError.messageTooLarge)
                return
            }

            let totalLength = 4 + length
            guard receiveBuffer.count >= totalLength else { return }

            let payload = receiveBuffer[4..<totalLength]
            receiveBuffer.removeSubrange(0..<totalLength)

            // Check if this is a binary video frame (starts with magic bytes)
            if payload.count >= 4 {
                if NetworkProtocol.readUInt32BigEndian(from: payload, atOffset: 0) == NetworkProtocol.binaryMagic {
                    if let result = BinaryFrameWire.deserialize(data: payload) {
                        onBinaryVideoFrame?(result.header, result.vps, result.sps, result.pps, result.payload)
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
