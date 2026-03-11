import Foundation

/// Coordinates receiver-side listener, decode, and render lifecycle.
@MainActor
final class ReceiverSessionCoordinator {
    enum SessionState: Equatable {
        case idle
        case listening
        case running
        case failed(String)
    }

    private let listenerService: ListenerService
    private let decoderService: DecoderService
    private let renderService: RenderService
    private let wiredPathMonitor = WiredPathStatusMonitor()

    private(set) var state: SessionState = .idle { didSet { onChange?() } }
    private(set) var listeningPort: UInt16 = NetworkProtocol.defaultPort { didSet { onChange?() } }
    private(set) var peerName: String = "" { didSet { onChange?() } }
    private(set) var receivedFrameCount: UInt64 = 0 { didSet { onChange?() } }
    private(set) var lastHeartbeatNanoseconds: UInt64? { didSet { onChange?() } }
    private(set) var lastErrorMessage: String? { didSet { onChange?() } }
    private(set) var latestFrameLatencyMilliseconds: Double? { didSet { onChange?() } }
    private(set) var averageFrameIntervalMilliseconds: Double? { didSet { onChange?() } }
    private(set) var estimatedJitterMilliseconds: Double? { didSet { onChange?() } }
    private(set) var receivedFramesPerSecond: Double? { didSet { onChange?() } }
    private(set) var receivedMegabitsPerSecond: Double? { didSet { onChange?() } }
    private(set) var renderSourceDescription: String = "-" { didSet { onChange?() } }
    private(set) var replacedBeforeRenderCount: UInt64 = 0 { didSet { onChange?() } }

    private(set) var configuredEndpointSummary: String = "-" { didSet { onChange?() } }
    private(set) var wiredPathAvailable = false { didSet { onChange?() } }
    private(set) var localInterfaceDescriptions: [String] = [] { didSet { onChange?() } }

    var onChange: (() -> Void)?
    private var lastFrameArrivalNanoseconds: UInt64?
    private var smoothedIntervalMilliseconds: Double?
    private var smoothedJitterMilliseconds: Double?
    private var inboundWindowStartNanoseconds: UInt64?
    private var inboundWindowFrameCount: UInt64 = 0
    private var inboundWindowPayloadBytes: UInt64 = 0

    init(
        listenerService: ListenerService = ListenerService(),
        decoderService: DecoderService = DecoderService(),
        renderService: RenderService = RenderService()
    ) {
        self.listenerService = listenerService
        self.decoderService = decoderService
        self.renderService = renderService

        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        wiredPathMonitor.onUpdate = { [weak self] isAvailable in
            guard let self else { return }
            Task { @MainActor in
                self.wiredPathAvailable = isAvailable
            }
        }
        wiredPathMonitor.start()

        listenerService.onStateChange = { [weak self] isListening in
            guard let self else { return }
            Task { @MainActor in
                if isListening {
                    if case .idle = self.state {
                        self.state = .listening
                    }
                } else {
                    self.state = .idle
                }
            }
        }

        listenerService.onEnvelope = { [weak self] envelope in
            guard let self else { return }
            Task { @MainActor in
                self.handle(envelope: envelope)
            }
        }

        listenerService.onBinaryVideoFrame = { [weak self] header, vps, sps, pps, payload in
            guard let self else { return }
            Task { @MainActor in
                self.handleBinaryVideoFrame(header: header, vps: vps, sps: sps, pps: pps, payload: payload)
            }
        }

        listenerService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.lastErrorMessage = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    deinit {
        wiredPathMonitor.stop()
    }

    /// Starts listening for sender handshake/heartbeat/frame envelopes.
    func startListening(port: UInt16 = NetworkProtocol.defaultPort) {
        listeningPort = port
        configuredEndpointSummary = "0.0.0.0:\(port)"
        receivedFrameCount = 0
        peerName = ""
        lastHeartbeatNanoseconds = nil
        lastErrorMessage = nil
        latestFrameLatencyMilliseconds = nil
        averageFrameIntervalMilliseconds = nil
        estimatedJitterMilliseconds = nil
        receivedFramesPerSecond = nil
        receivedMegabitsPerSecond = nil
        renderSourceDescription = "-"
        replacedBeforeRenderCount = 0
        lastFrameArrivalNanoseconds = nil
        smoothedIntervalMilliseconds = nil
        smoothedJitterMilliseconds = nil
        inboundWindowStartNanoseconds = nil
        inboundWindowFrameCount = 0
        inboundWindowPayloadBytes = 0
        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()
        RenderFrameStore.shared.reset()

        renderService.prepareRenderer()
        listenerService.startListening(port: port)
    }

    /// Stops listener and returns receiver pipeline to idle state.
    func stopListening() {
        listenerService.stopListening()
        state = .idle
    }

    private func handle(envelope: NetworkEnvelope) {
        do {
            switch envelope.type {
            case .hello:
                let hello = try envelope.decodePayload(as: HelloPayload.self)
                peerName = hello.senderName
                if hello.requestedProtocolVersion == NetworkProtocol.protocolVersion {
                    listenerService.sendHelloAck(accepted: true, reason: nil)
                    state = .running
                } else {
                    listenerService.sendHelloAck(accepted: false, reason: "unsupported protocol version")
                    state = .failed("unsupported protocol version")
                }
            case .helloAck:
                // Receiver does not currently expect helloAck in this direction.
                break
            case .heartbeat:
                let heartbeat = try envelope.decodePayload(as: HeartbeatPayload.self)
                lastHeartbeatNanoseconds = heartbeat.timestampNanoseconds
                listenerService.sendHeartbeat()
            case .videoFrame:
                let packet = try envelope.decodePayload(as: VideoPacket.self)
                updateFrameTimingMetrics(from: packet.metadata)
                updateInboundMetrics(payloadByteCount: packet.payload.count)
                let decodedFrame = decoderService.decode(packet: packet)
                renderDecodedFrame(decodedFrame)
                receivedFrameCount += 1
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func handleBinaryVideoFrame(header: BinaryFrameHeader, vps: Data?, sps: Data?, pps: Data?, payload: Data) {
        let metadata = FrameMetadata(
            frameIndex: header.frameIndex,
            timestampNanoseconds: header.timestampNanoseconds,
            width: header.width,
            height: header.height,
            isKeyFrame: header.isKeyFrame
        )

        if header.frameIndex % 30 == 0 {
            print("[Receiver] Binary frame \(header.frameIndex): \(header.width)x\(header.height), codec=\(header.codec), payload=\(payload.count) bytes, vps=\(vps?.count ?? 0), sps=\(sps?.count ?? 0), pps=\(pps?.count ?? 0)")
        }

        updateFrameTimingMetrics(from: metadata)
        updateInboundMetrics(payloadByteCount: payload.count)

        let encodedFrame = makeEncodedFrame(
            metadata: metadata,
            header: header,
            vps: vps,
            sps: sps,
            pps: pps,
            payload: payload
        )

        let decodedFrame = decoderService.decodeEncodedFrame(encodedFrame)
        let renderSource = renderDecodedFrame(decodedFrame)

        if header.frameIndex % 30 == 0 {
            let renderableFrame = RenderFrameStore.shared.snapshot()
            print(
                "[Receiver] Rendered frame \(header.frameIndex): source=\(renderSource), " +
                "hasPB=\(renderableFrame?.pixelBuffer != nil), hasData=\(renderableFrame?.pixelData != nil), " +
                "bpr=\(renderableFrame?.bytesPerRow ?? 0)"
            )
        }
        receivedFrameCount += 1
    }

    private func makeEncodedFrame(
        metadata: FrameMetadata,
        header: BinaryFrameHeader,
        vps: Data?,
        sps: Data?,
        pps: Data?,
        payload: Data
    ) -> EncodedFrame {
        EncodedFrame(
            metadata: metadata,
            codec: header.codec,
            payload: payload,
            isKeyFrame: header.isKeyFrame,
            sourceBytesPerRow: header.bytesPerRow,
            sourcePixelFormat: header.pixelFormat,
            targetBitrateKbps: 20_000,
            targetFramesPerSecond: NetworkProtocol.targetFramesPerSecond,
            h264SPS: sps,
            h264PPS: pps,
            hevcVPS: vps
        )
    }

    @discardableResult
    private func renderDecodedFrame(_ decodedFrame: DecodedFrame) -> String {
        let (renderableFrame, renderSource) = makeRenderableFrame(from: decodedFrame)
        renderService.render(frame: renderableFrame)
        renderSourceDescription = renderSource
        replacedBeforeRenderCount = RenderFrameStore.shared.replacedFramesCount()
        return renderSource
    }

    private func updateFrameTimingMetrics(from metadata: FrameMetadata) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= metadata.timestampNanoseconds {
            latestFrameLatencyMilliseconds = Double(now - metadata.timestampNanoseconds) / 1_000_000.0
        } else {
            latestFrameLatencyMilliseconds = 0
        }

        if let previousArrival = lastFrameArrivalNanoseconds, now >= previousArrival {
            let intervalMs = Double(now - previousArrival) / 1_000_000.0
            let alpha = 0.12

            if let current = smoothedIntervalMilliseconds {
                let next = (alpha * intervalMs) + ((1.0 - alpha) * current)
                smoothedIntervalMilliseconds = next
            } else {
                smoothedIntervalMilliseconds = intervalMs
            }

            if let smoothed = smoothedIntervalMilliseconds {
                let absoluteDeviation = abs(intervalMs - smoothed)
                if let currentJitter = smoothedJitterMilliseconds {
                    smoothedJitterMilliseconds = (alpha * absoluteDeviation) + ((1.0 - alpha) * currentJitter)
                } else {
                    smoothedJitterMilliseconds = absoluteDeviation
                }
            }
        }

        lastFrameArrivalNanoseconds = now
        averageFrameIntervalMilliseconds = smoothedIntervalMilliseconds
        estimatedJitterMilliseconds = smoothedJitterMilliseconds
    }

    private func updateInboundMetrics(payloadByteCount: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        if inboundWindowStartNanoseconds == nil {
            inboundWindowStartNanoseconds = now
        }

        inboundWindowFrameCount += 1
        inboundWindowPayloadBytes += UInt64(max(0, payloadByteCount))

        guard let windowStart = inboundWindowStartNanoseconds, now >= windowStart else { return }
        let elapsedNanoseconds = now - windowStart
        guard elapsedNanoseconds >= 1_000_000_000 else { return }

        let elapsedSeconds = Double(elapsedNanoseconds) / 1_000_000_000.0
        receivedFramesPerSecond = Double(inboundWindowFrameCount) / elapsedSeconds
        receivedMegabitsPerSecond = (Double(inboundWindowPayloadBytes) * 8.0) / elapsedSeconds / 1_000_000.0

        inboundWindowStartNanoseconds = now
        inboundWindowFrameCount = 0
        inboundWindowPayloadBytes = 0
    }

    private func makeRenderableFrame(from frame: DecodedFrame) -> (DecodedFrame, String) {
        if frame.pixelBuffer != nil {
            return (frame, "decoded_pixel_buffer")
        }

        let requiredBytes = max(0, frame.bytesPerRow * frame.metadata.height)
        if let pixelData = frame.pixelData, frame.bytesPerRow > 0, requiredBytes > 0, pixelData.count >= requiredBytes {
            _ = pixelData
            return (frame, "decoded_bytes")
        }

        return (makeDiagnosticFallbackFrame(from: frame.metadata), "fallback_diagnostic")
    }

    private func makeDiagnosticFallbackFrame(from metadata: FrameMetadata) -> DecodedFrame {
        let targetWidth = max(160, min(640, metadata.width))
        let targetHeight = max(90, min(360, metadata.height))
        let bytesPerRow = targetWidth * 4
        var pixels = Data(count: bytesPerRow * targetHeight)

        let phase = UInt8(metadata.frameIndex % 255)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for y in 0..<targetHeight {
                let yComponent = UInt8((y * 255) / max(1, targetHeight - 1))
                for x in 0..<targetWidth {
                    let offset = (y * bytesPerRow) + (x * 4)
                    let xComponent = UInt8((x * 255) / max(1, targetWidth - 1))
                    let movingBar = (x / 24 + Int(metadata.frameIndex / 3)) % 2 == 0
                    base[offset + 0] = movingBar ? phase : xComponent      // B
                    base[offset + 1] = movingBar ? xComponent : yComponent // G
                    base[offset + 2] = movingBar ? yComponent : phase      // R
                    base[offset + 3] = 255                                 // A
                }
            }
        }

        let fallbackMetadata = FrameMetadata(
            frameIndex: metadata.frameIndex,
            timestampNanoseconds: metadata.timestampNanoseconds,
            width: targetWidth,
            height: targetHeight,
            isKeyFrame: metadata.isKeyFrame
        )

        return DecodedFrame(
            metadata: fallbackMetadata,
            pixelBuffer: nil,
            pixelData: pixels,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8
        )
    }
}
