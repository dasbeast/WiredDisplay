import AppKit
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
    private let videoDatagramListenerService: VideoDatagramListenerService
    private let decoderService: DecoderService
    private let renderService: RenderService
    private let audioPlaybackService: AudioPlaybackService
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
    private var lastRenderedFrameTelemetry: ReceiverRenderedFrameTelemetry?
    private var lastRecoveryKeyFrameRequestAt: Date?

    init(
        listenerService: ListenerService = ListenerService(),
        videoDatagramListenerService: VideoDatagramListenerService = VideoDatagramListenerService(),
        decoderService: DecoderService = DecoderService(),
        renderService: RenderService = RenderService(),
        audioPlaybackService: AudioPlaybackService? = nil
    ) {
        self.listenerService = listenerService
        self.videoDatagramListenerService = videoDatagramListenerService
        self.decoderService = decoderService
        self.renderService = renderService
        self.audioPlaybackService = audioPlaybackService ?? AudioPlaybackService()
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

        decoderService.onNeedsKeyFrame = { [weak self] metadata, codec in
            guard codec != .rawBGRA else { return }
            Task { @MainActor [weak self] in
                self?.requestRecoveryKeyFrame(
                    failedFrameIndex: metadata.frameIndex,
                    reason: "decoder lost reference state"
                )
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
                    self.audioPlaybackService.stop()
                    self.state = .idle
                }
            }
        }

        listenerService.onConnectionClosed = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.audioPlaybackService.stop()
                self.frameDecodePipeline.reset()
                RenderFrameStore.shared.reset()
                if case .running = self.state {
                    self.state = .listening
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

        listenerService.onBinaryAudioFrame = { [weak self] header, payload in
            guard let self else { return }
            Task { @MainActor in
                self.audioPlaybackService.play(header: header, payload: payload)
            }
        }

        videoDatagramListenerService.onBinaryVideoFrame = { [weak self] header, vps, sps, pps, payload in
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

        videoDatagramListenerService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.lastErrorMessage = "UDP video listener: \(error.localizedDescription)"
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
        lastRenderedFrameTelemetry = nil
        lastFrameArrivalNanoseconds = nil
        smoothedIntervalMilliseconds = nil
        smoothedJitterMilliseconds = nil
        inboundWindowStartNanoseconds = nil
        inboundWindowFrameCount = 0
        inboundWindowPayloadBytes = 0
        lastRecoveryKeyFrameRequestAt = nil
        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()
        frameDecodePipeline.reset()
        RenderFrameStore.shared.reset()

        renderService.prepareRenderer()
        audioPlaybackService.prepare()
        videoDatagramListenerService.startListening(port: port)
        listenerService.startListening(port: port)
    }

    /// Stops listener and returns receiver pipeline to idle state.
    func stopListening() {
        frameDecodePipeline.reset()
        audioPlaybackService.stop()
        listenerService.stopListening()
        videoDatagramListenerService.stopListening()
        state = .idle
    }

    private func handle(envelope: NetworkEnvelope) {
        do {
            switch envelope.type {
            case .hello:
                frameDecodePipeline.reset()
                RenderFrameStore.shared.reset()
                let hello = try envelope.decodePayload(as: HelloPayload.self)
                peerName = hello.senderName
                if hello.requestedProtocolVersion == NetworkProtocol.protocolVersion {
                    let requestedTransport = hello.preferredVideoTransport ?? .tcp
                    let negotiatedTransport = NetworkProtocol.negotiatedVideoTransport(
                        requested: requestedTransport,
                        canAcceptDatagrams: videoDatagramListenerService.canAcceptDatagrams
                    )
                    listenerService.sendHelloAck(
                        accepted: true,
                        reason: nil,
                        displayMetrics: currentDisplayMetrics(),
                        negotiatedVideoTransport: negotiatedTransport
                    )
                    state = .running
                } else {
                    listenerService.sendHelloAck(accepted: false, reason: "unsupported protocol version")
                    state = .failed("unsupported protocol version")
                }
            case .helloAck:
                // Receiver does not currently expect helloAck in this direction.
                break
            case .heartbeat:
                let receiveTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
                let heartbeat = try envelope.decodePayload(as: HeartbeatPayload.self)
                lastHeartbeatNanoseconds = heartbeat.transmitTimestampNanoseconds
                listenerService.sendHeartbeatReply(
                    originTimestampNanoseconds: heartbeat.transmitTimestampNanoseconds,
                    receiveTimestampNanoseconds: receiveTimestampNanoseconds,
                    renderedFrameIndex: lastRenderedFrameTelemetry?.frameIndex,
                    renderedFrameSenderTimestampNanoseconds: lastRenderedFrameTelemetry?.senderTimestampNanoseconds,
                    renderedFrameReceiverTimestampNanoseconds: lastRenderedFrameTelemetry?.receiverRenderTimestampNanoseconds
                )
            case .videoFrame:
                break
            case .requestKeyFrame:
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
        lastRenderedFrameTelemetry = ReceiverRenderedFrameTelemetry(
            frameIndex: update.metadata.frameIndex,
            senderTimestampNanoseconds: update.metadata.timestampNanoseconds,
            receiverRenderTimestampNanoseconds: update.renderTimestampNanoseconds
        )
        receivedFrameCount += 1
    }

    private func requestRecoveryKeyFrame(failedFrameIndex: UInt64?, reason: String) {
        let now = Date()
        if let lastRecoveryKeyFrameRequestAt,
           now.timeIntervalSince(lastRecoveryKeyFrameRequestAt) < NetworkProtocol.udpRecoveryRequestThrottleSeconds {
            return
        }

        lastRecoveryKeyFrameRequestAt = now
        listenerService.sendKeyFrameRequest(
            failedFrameIndex: failedFrameIndex,
            reason: reason
        )
    }

    private func updateFrameTimingMetrics(from metadata: FrameMetadata, arrivalNanoseconds: UInt64) {
        _ = metadata
        latestFrameLatencyMilliseconds = nil

        let timingSnapshot = NetworkProtocol.nextReceiverFrameTimingSnapshot(
            previousArrivalNanoseconds: lastFrameArrivalNanoseconds,
            previousSmoothedIntervalMilliseconds: smoothedIntervalMilliseconds,
            previousSmoothedJitterMilliseconds: smoothedJitterMilliseconds,
            arrivalNanoseconds: arrivalNanoseconds
        )

        lastFrameArrivalNanoseconds = arrivalNanoseconds
        smoothedIntervalMilliseconds = timingSnapshot.averageFrameIntervalMilliseconds
        smoothedJitterMilliseconds = timingSnapshot.estimatedJitterMilliseconds
        averageFrameIntervalMilliseconds = timingSnapshot.averageFrameIntervalMilliseconds
        estimatedJitterMilliseconds = timingSnapshot.estimatedJitterMilliseconds
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

    private func currentDisplayMetrics() -> ReceiverDisplayMetrics? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }

        let logicalFrame = screen.frame
        let backingFrame = screen.convertRectToBacking(logicalFrame)
        let logicalWidth = max(1, Int(logicalFrame.width.rounded()))
        let logicalHeight = max(1, Int(logicalFrame.height.rounded()))
        let pixelWidth = max(1, Int(backingFrame.width.rounded()))
        let pixelHeight = max(1, Int(backingFrame.height.rounded()))

        let refreshRateHz: Double?
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(screenNumber.uint32Value)) {
            let reportedRefreshRate = mode.refreshRate
            refreshRateHz = reportedRefreshRate > 0 ? reportedRefreshRate : nil
        } else {
            refreshRateHz = nil
        }

        return ReceiverDisplayMetrics(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            backingScaleFactor: Double(screen.backingScaleFactor),
            refreshRateHz: refreshRateHz
        )
    }
}

private struct ReceiverFrameProcessingUpdate: Sendable {
    let metadata: FrameMetadata
    let payloadByteCount: Int
    let renderSource: String
    let replacedBeforeRenderCount: UInt64
    let arrivalNanoseconds: UInt64
    let renderTimestampNanoseconds: UInt64
}

private struct ReceiverRenderResult {
    let renderSource: String
    let replacedBeforeRenderCount: UInt64
    let hasPixelBuffer: Bool
    let hasPixelData: Bool
    let bytesPerRow: Int
}

private struct ReceiverRenderedFrameTelemetry {
    let frameIndex: UInt64
    let senderTimestampNanoseconds: UInt64
    let receiverRenderTimestampNanoseconds: UInt64
}

private struct PendingCompressedBinaryFrame {
    let header: BinaryFrameHeader
    let vps: Data?
    let sps: Data?
    let pps: Data?
    let payload: Data
    let arrivalNanoseconds: UInt64
}

private final class ReceiverFrameDecodePipeline {
    private let decoderService: DecoderService
    private let renderService: RenderService
    private let queue = DispatchQueue(label: "wireddisplay.receiver.decode", qos: .userInteractive)
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    /// Tracks the highest enqueued frame index so the decode worker can skip stale P-frames.
    private let latestEnqueuedFrameIndex = LatestFrameIndex()
    private var pendingCompressedFrames: [UInt64: PendingCompressedBinaryFrame] = [:]
    private var nextExpectedCompressedFrameIndex: UInt64?
    private var blockedCompressedFrameAtNanoseconds: UInt64?

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
        latestEnqueuedFrameIndex.update(header.frameIndex)
        queue.async { [weak self] in
            self?.routeBinaryVideoFrame(
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
        latestEnqueuedFrameIndex.reset()
        queue.async { [weak self] in
            self?.pendingCompressedFrames.removeAll(keepingCapacity: false)
            self?.nextExpectedCompressedFrameIndex = nil
            self?.blockedCompressedFrameAtNanoseconds = nil
        }
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

            guard let renderResult = renderDecodedFrame(decodedFrame) else {
                if packet.metadata.frameIndex % 30 == 0 {
                    print("[Receiver] Holding last rendered frame for undecodable frame \(packet.metadata.frameIndex)")
                }
                return
            }
            guard isCurrentGeneration(generation) else { return }

            let renderTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds

            onFrameReady?(
                ReceiverFrameProcessingUpdate(
                    metadata: packet.metadata,
                    payloadByteCount: packet.payload.count,
                    renderSource: renderResult.renderSource,
                    replacedBeforeRenderCount: renderResult.replacedBeforeRenderCount,
                    arrivalNanoseconds: arrivalNanoseconds,
                    renderTimestampNanoseconds: renderTimestampNanoseconds
                )
            )
        } catch {
            guard isCurrentGeneration(generation) else { return }
            onError?(error)
        }
    }

    private func routeBinaryVideoFrame(
        header: BinaryFrameHeader,
        vps: Data?,
        sps: Data?,
        pps: Data?,
        payload: Data,
        arrivalNanoseconds: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation) else { return }

        if header.codec == .rawBGRA {
            _ = processBinaryVideoFrame(
                header: header,
                vps: vps,
                sps: sps,
                pps: pps,
                payload: payload,
                arrivalNanoseconds: arrivalNanoseconds,
                generation: generation
            )
            return
        }

        enqueueCompressedBinaryVideoFrame(
            PendingCompressedBinaryFrame(
                header: header,
                vps: vps,
                sps: sps,
                pps: pps,
                payload: payload,
                arrivalNanoseconds: arrivalNanoseconds
            ),
            generation: generation
        )
    }

    private func enqueueCompressedBinaryVideoFrame(
        _ frame: PendingCompressedBinaryFrame,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation) else { return }

        if let nextExpectedCompressedFrameIndex,
           frame.header.frameIndex < nextExpectedCompressedFrameIndex {
            return
        }

        if pendingCompressedFrames[frame.header.frameIndex] == nil,
           pendingCompressedFrames.count >= NetworkProtocol.udpDecodeMaxPendingFrames {
            trimPendingCompressedFrames()
        }

        pendingCompressedFrames[frame.header.frameIndex] = frame

        if frame.header.isKeyFrame,
           nextExpectedCompressedFrameIndex == nil {
            nextExpectedCompressedFrameIndex = frame.header.frameIndex
        }

        drainPendingCompressedFrames(generation: generation)
    }

    private func drainPendingCompressedFrames(generation: UInt64) {
        guard isCurrentGeneration(generation) else { return }

        while true {
            if nextExpectedCompressedFrameIndex == nil {
                guard let firstKeyFrameIndex = pendingCompressedFrames
                    .values
                    .filter({ $0.header.isKeyFrame })
                    .map(\.header.frameIndex)
                    .min() else {
                    return
                }
                nextExpectedCompressedFrameIndex = firstKeyFrameIndex
            }

            guard let expectedFrameIndex = nextExpectedCompressedFrameIndex else {
                return
            }

            if let frame = pendingCompressedFrames.removeValue(forKey: expectedFrameIndex) {
                blockedCompressedFrameAtNanoseconds = nil

                let wasRendered = processBinaryVideoFrame(
                    header: frame.header,
                    vps: frame.vps,
                    sps: frame.sps,
                    pps: frame.pps,
                    payload: frame.payload,
                    arrivalNanoseconds: frame.arrivalNanoseconds,
                    generation: generation
                )

                guard isCurrentGeneration(generation) else { return }

                if wasRendered {
                    nextExpectedCompressedFrameIndex = expectedFrameIndex &+ 1
                } else {
                    // After a compressed-frame decode failure, keep only future keyframes
                    // so the pipeline can restart cleanly on the next reference frame.
                    pendingCompressedFrames = pendingCompressedFrames.filter { $0.value.header.isKeyFrame }
                    nextExpectedCompressedFrameIndex = nil
                    blockedCompressedFrameAtNanoseconds = nil
                    return
                }

                continue
            }

            let newestArrival = pendingCompressedFrames.values.map(\.arrivalNanoseconds).max() ?? DispatchTime.now().uptimeNanoseconds
            if blockedCompressedFrameAtNanoseconds == nil {
                blockedCompressedFrameAtNanoseconds = newestArrival
            }

            guard let blockedAtNanoseconds = blockedCompressedFrameAtNanoseconds else {
                return
            }

            let waitedNanoseconds = newestArrival >= blockedAtNanoseconds
                ? newestArrival - blockedAtNanoseconds
                : 0

            guard waitedNanoseconds >= NetworkProtocol.udpDecodeReorderWaitNanoseconds else {
                return
            }

            guard let recoveryKeyFrameIndex = pendingCompressedFrames
                .values
                .filter({ $0.header.isKeyFrame && $0.header.frameIndex > expectedFrameIndex })
                .map(\.header.frameIndex)
                .min() else {
                return
            }

            pendingCompressedFrames = pendingCompressedFrames.filter { $0.key >= recoveryKeyFrameIndex }
            nextExpectedCompressedFrameIndex = recoveryKeyFrameIndex
            self.blockedCompressedFrameAtNanoseconds = nil
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
    ) -> Bool {
        guard isCurrentGeneration(generation) else { return false }

        // Compressed interframes depend on earlier reference frames, so dropping them
        // before decode corrupts the reference chain. Only short-circuit stale raw frames.
        if header.codec == .rawBGRA,
           !header.isKeyFrame,
           header.frameIndex < latestEnqueuedFrameIndex.current() {
            return false
        }

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
        guard isCurrentGeneration(generation) else { return false }

        guard let renderResult = renderDecodedFrame(decodedFrame) else {
            if header.frameIndex % 30 == 0 {
                print("[Receiver] Holding last rendered frame for undecodable frame \(header.frameIndex)")
            }
            return false
        }
        guard isCurrentGeneration(generation) else { return false }

        let renderTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds

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
                arrivalNanoseconds: arrivalNanoseconds,
                renderTimestampNanoseconds: renderTimestampNanoseconds
            )
        )
        return true
    }

    private func trimPendingCompressedFrames() {
        guard pendingCompressedFrames.count >= NetworkProtocol.udpDecodeMaxPendingFrames else {
            return
        }

        let sortedFrameIndices = pendingCompressedFrames.keys.sorted()
        let frameIndicesToRemove = sortedFrameIndices.prefix(
            max(0, sortedFrameIndices.count - (NetworkProtocol.udpDecodeMaxPendingFrames - 1))
        )
        for frameIndex in frameIndicesToRemove {
            pendingCompressedFrames.removeValue(forKey: frameIndex)
        }
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

    private func renderDecodedFrame(_ decodedFrame: DecodedFrame) -> ReceiverRenderResult? {
        guard let (renderableFrame, renderSource) = makeRenderableFrame(from: decodedFrame) else {
            return nil
        }
        renderService.render(frame: renderableFrame)

        return ReceiverRenderResult(
            renderSource: renderSource,
            replacedBeforeRenderCount: RenderFrameStore.shared.replacedFramesCount(),
            hasPixelBuffer: renderableFrame.pixelBuffer != nil,
            hasPixelData: renderableFrame.pixelData != nil,
            bytesPerRow: renderableFrame.bytesPerRow
        )
    }

    private func makeRenderableFrame(from frame: DecodedFrame) -> (DecodedFrame, String)? {
        if frame.pixelBuffer != nil {
            return (frame, "decoded_pixel_buffer")
        }

        let requiredBytes = max(0, frame.bytesPerRow * frame.metadata.height)
        if let pixelData = frame.pixelData, frame.bytesPerRow > 0, requiredBytes > 0, pixelData.count >= requiredBytes {
            _ = pixelData
            return (frame, "decoded_bytes")
        }

        return nil
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

/// Lock-free latest-frame-index tracker for stale-frame skipping.
private final class LatestFrameIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    func update(_ frameIndex: UInt64) {
        lock.lock()
        if frameIndex > value { value = frameIndex }
        lock.unlock()
    }

    func current() -> UInt64 {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }
}
