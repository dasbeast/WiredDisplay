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
    private let frameDecodePipeline: ReceiverFrameDecodePipeline
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
        self.frameDecodePipeline = ReceiverFrameDecodePipeline(
            decoderService: decoderService,
            renderService: renderService
        )

        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        frameDecodePipeline.onFrameReady = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.applyFrameUpdate(update)
            }
        }

        frameDecodePipeline.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastErrorMessage = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
        }

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

        let frameDecodePipeline = self.frameDecodePipeline
        listenerService.onEnvelope = { [weak self] envelope in
            if envelope.type == .videoFrame {
                frameDecodePipeline.enqueueVideoEnvelope(
                    envelope,
                    arrivalNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
                return
            }

            guard let self else { return }
            Task { @MainActor in
                self.handle(envelope: envelope)
            }
        }

        listenerService.onBinaryVideoFrame = { [weak self] header, vps, sps, pps, payload in
            guard self != nil else { return }
            frameDecodePipeline.enqueueBinaryVideoFrame(
                header: header,
                vps: vps,
                sps: sps,
                pps: pps,
                payload: payload,
                arrivalNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
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
        frameDecodePipeline.reset()
        RenderFrameStore.shared.reset()

        renderService.prepareRenderer()
        listenerService.startListening(port: port)
    }

    /// Stops listener and returns receiver pipeline to idle state.
    func stopListening() {
        frameDecodePipeline.reset()
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
                break
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func applyFrameUpdate(_ update: ReceiverFrameProcessingUpdate) {
        updateFrameTimingMetrics(from: update.metadata, arrivalNanoseconds: update.arrivalNanoseconds)
        updateInboundMetrics(payloadByteCount: update.payloadByteCount, atNanoseconds: update.arrivalNanoseconds)
        renderSourceDescription = update.renderSource
        replacedBeforeRenderCount = update.replacedBeforeRenderCount
        receivedFrameCount += 1
    }

    private func updateFrameTimingMetrics(from metadata: FrameMetadata, arrivalNanoseconds: UInt64) {
        if arrivalNanoseconds >= metadata.timestampNanoseconds {
            latestFrameLatencyMilliseconds = Double(arrivalNanoseconds - metadata.timestampNanoseconds) / 1_000_000.0
        } else {
            latestFrameLatencyMilliseconds = 0
        }

        if let previousArrival = lastFrameArrivalNanoseconds, arrivalNanoseconds >= previousArrival {
            let intervalMs = Double(arrivalNanoseconds - previousArrival) / 1_000_000.0
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

        lastFrameArrivalNanoseconds = arrivalNanoseconds
        averageFrameIntervalMilliseconds = smoothedIntervalMilliseconds
        estimatedJitterMilliseconds = smoothedJitterMilliseconds
    }

    private func updateInboundMetrics(payloadByteCount: Int, atNanoseconds now: UInt64) {
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
}

private struct ReceiverFrameProcessingUpdate: Sendable {
    let metadata: FrameMetadata
    let payloadByteCount: Int
    let renderSource: String
    let replacedBeforeRenderCount: UInt64
    let arrivalNanoseconds: UInt64
}

private struct ReceiverRenderResult {
    let renderSource: String
    let replacedBeforeRenderCount: UInt64
    let hasPixelBuffer: Bool
    let hasPixelData: Bool
    let bytesPerRow: Int
}

private final class ReceiverFrameDecodePipeline {
    private let decoderService: DecoderService
    private let renderService: RenderService
    private let queue = DispatchQueue(label: "wireddisplay.receiver.decode", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation: UInt64 = 0

    var onFrameReady: ((ReceiverFrameProcessingUpdate) -> Void)?
    var onError: ((Error) -> Void)?

    init(decoderService: DecoderService, renderService: RenderService) {
        self.decoderService = decoderService
        self.renderService = renderService
    }

    func enqueueVideoEnvelope(_ envelope: NetworkEnvelope, arrivalNanoseconds: UInt64) {
        let generation = currentGeneration()
        queue.async { [weak self] in
            self?.processVideoEnvelope(
                envelope,
                arrivalNanoseconds: arrivalNanoseconds,
                generation: generation
            )
        }
    }

    func enqueueBinaryVideoFrame(
        header: BinaryFrameHeader,
        vps: Data?,
        sps: Data?,
        pps: Data?,
        payload: Data,
        arrivalNanoseconds: UInt64
    ) {
        let generation = currentGeneration()
        queue.async { [weak self] in
            self?.processBinaryVideoFrame(
                header: header,
                vps: vps,
                sps: sps,
                pps: pps,
                payload: payload,
                arrivalNanoseconds: arrivalNanoseconds,
                generation: generation
            )
        }
    }

    func reset() {
        generationLock.lock()
        generation &+= 1
        generationLock.unlock()
    }

    private func processVideoEnvelope(
        _ envelope: NetworkEnvelope,
        arrivalNanoseconds: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation) else { return }

        do {
            let packet = try envelope.decodePayload(as: VideoPacket.self)
            let decodedFrame = decoderService.decode(packet: packet)
            guard isCurrentGeneration(generation) else { return }

            let renderResult = renderDecodedFrame(decodedFrame)
            guard isCurrentGeneration(generation) else { return }

            onFrameReady?(
                ReceiverFrameProcessingUpdate(
                    metadata: packet.metadata,
                    payloadByteCount: packet.payload.count,
                    renderSource: renderResult.renderSource,
                    replacedBeforeRenderCount: renderResult.replacedBeforeRenderCount,
                    arrivalNanoseconds: arrivalNanoseconds
                )
            )
        } catch {
            guard isCurrentGeneration(generation) else { return }
            onError?(error)
        }
    }

    private func processBinaryVideoFrame(
        header: BinaryFrameHeader,
        vps: Data?,
        sps: Data?,
        pps: Data?,
        payload: Data,
        arrivalNanoseconds: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation) else { return }

        let metadata = FrameMetadata(
            frameIndex: header.frameIndex,
            timestampNanoseconds: header.timestampNanoseconds,
            width: header.width,
            height: header.height,
            isKeyFrame: header.isKeyFrame
        )

        if header.frameIndex % 30 == 0 {
            print(
                "[Receiver] Binary frame \(header.frameIndex): \(header.width)x\(header.height), " +
                "codec=\(header.codec), payload=\(payload.count) bytes, vps=\(vps?.count ?? 0), " +
                "sps=\(sps?.count ?? 0), pps=\(pps?.count ?? 0)"
            )
        }

        let encodedFrame = makeEncodedFrame(
            metadata: metadata,
            header: header,
            vps: vps,
            sps: sps,
            pps: pps,
            payload: payload
        )
        let decodedFrame = decoderService.decodeEncodedFrame(encodedFrame)
        guard isCurrentGeneration(generation) else { return }

        let renderResult = renderDecodedFrame(decodedFrame)
        guard isCurrentGeneration(generation) else { return }

        if header.frameIndex % 30 == 0 {
            print(
                "[Receiver] Rendered frame \(header.frameIndex): source=\(renderResult.renderSource), " +
                "hasPB=\(renderResult.hasPixelBuffer), hasData=\(renderResult.hasPixelData), " +
                "bpr=\(renderResult.bytesPerRow)"
            )
        }

        onFrameReady?(
            ReceiverFrameProcessingUpdate(
                metadata: metadata,
                payloadByteCount: payload.count,
                renderSource: renderResult.renderSource,
                replacedBeforeRenderCount: renderResult.replacedBeforeRenderCount,
                arrivalNanoseconds: arrivalNanoseconds
            )
        )
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

    private func renderDecodedFrame(_ decodedFrame: DecodedFrame) -> ReceiverRenderResult {
        let (renderableFrame, renderSource) = makeRenderableFrame(from: decodedFrame)
        renderService.render(frame: renderableFrame)

        return ReceiverRenderResult(
            renderSource: renderSource,
            replacedBeforeRenderCount: RenderFrameStore.shared.replacedFramesCount(),
            hasPixelBuffer: renderableFrame.pixelBuffer != nil,
            hasPixelData: renderableFrame.pixelData != nil,
            bytesPerRow: renderableFrame.bytesPerRow
        )
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

    private func currentGeneration() -> UInt64 {
        generationLock.lock()
        let currentGeneration = generation
        generationLock.unlock()
        return currentGeneration
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        generationLock.lock()
        let isCurrent = generation == candidate
        generationLock.unlock()
        return isCurrent
    }
}
