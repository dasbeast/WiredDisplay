import Foundation

/// Coordinates sender-side capture, encoding, and transport lifecycle.
@MainActor
final class SenderSessionCoordinator {
    enum SessionState: Equatable {
        case idle
        case connecting
        case waitingForAck
        case connected
        case running
        case failed(String)
    }

    private let captureService: CaptureService
    private let encoderService: EncoderService
    private let transportService: TransportService
    private let videoDatagramTransportService: VideoDatagramTransportService
    private let virtualDisplayService = VirtualDisplayService()
    private let wiredPathMonitor = WiredPathStatusMonitor()

    private(set) var state: SessionState = .idle {
        didSet {
            frameDispatchGate.setRunning(state == .running)
            onChange?()
        }
    }
    private(set) var receiverHost: String = "" { didSet { onChange?() } }
    private(set) var targetWidth: Int = 2560 { didSet { onChange?() } }
    private(set) var targetHeight: Int = 1440 { didSet { onChange?() } }
    private(set) var sentFrameCount: UInt64 = 0 { didSet { onChange?() } }
    private(set) var droppedOutboundFrameCount: UInt64 = 0 { didSet { onChange?() } }
    private(set) var lastErrorMessage: String? { didSet { onChange?() } }
    private(set) var sentFramesPerSecond: Double? { didSet { onChange?() } }
    private(set) var sentMegabitsPerSecond: Double? { didSet { onChange?() } }
    private(set) var heartbeatRoundTripMilliseconds: Double? { didSet { onChange?() } }
    private(set) var estimatedDisplayLatencyMilliseconds: Double? { didSet { onChange?() } }
    private(set) var requestedVideoTransportMode: NetworkProtocol.VideoTransportMode = .tcp { didSet { onChange?() } }
    private(set) var negotiatedVideoTransportMode: NetworkProtocol.VideoTransportMode = .tcp { didSet { onChange?() } }

    private(set) var configuredEndpointSummary: String = "-" { didSet { onChange?() } }
    private(set) var wiredPathAvailable = false { didSet { onChange?() } }
    private(set) var localInterfaceDescriptions: [String] = [] { didSet { onChange?() } }
    /// All modes macOS exposes on the active virtual display (populated after session starts).
    private(set) var availableDisplayModes: [VirtualDisplayMode] = [] { didSet { onChange?() } }
    /// The mode macOS actually has active on the virtual display (read back after creation/change).
    private(set) var activeDisplayMode: VirtualDisplayMode? { didSet { onChange?() } }
    var canStartSession: Bool { state == .connected }
    var isSessionActive: Bool {
        switch state {
        case .connecting, .waitingForAck, .connected, .running:
            return true
        default:
            return false
        }
    }

    var onChange: (() -> Void)?

    private var desiredHost: String?
    private var desiredPort: UInt16 = NetworkProtocol.defaultPort
    private var shouldMaintainConnection = false

    private var heartbeatTimer: Timer?
    private var heartbeatTimeoutTimer: Timer?
    private var lastInboundHeartbeatAt: Date?
    private var estimatedReceiverClockOffsetNanoseconds: Int64?
    private var lastRecoveryKeyFrameRequestAt: Date?
    private var targetUsesHiDPI = true
    /// Receiver's advertised logical dimensions, used to auto-select the best virtual display mode.
    private var receiverLogicalWidth: Int = 0
    private var receiverLogicalHeight: Int = 0
    private var awaitingUDPReadyToStart = false
    private var awaitingFirstRenderedFrame = false
    private var outboundWindowStartNanoseconds: UInt64?
    private var outboundWindowFrameCount: UInt64 = 0
    private var outboundWindowPayloadBytes: UInt64 = 0
    private let frameDispatchGate = SenderFrameDispatchGate()

    init(
        captureService: CaptureService = CaptureService(),
        encoderService: EncoderService = EncoderService(),
        transportService: TransportService = TransportService(),
        videoDatagramTransportService: VideoDatagramTransportService = VideoDatagramTransportService()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.transportService = transportService
        self.videoDatagramTransportService = videoDatagramTransportService

        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        let encoder = self.encoderService
        let frameDispatchGate = self.frameDispatchGate
        encoderService.onEncodedFrame = { [weak self] encodedFrame in
            guard let self else { return }
            guard frameDispatchGate.isRunning else { return }

            // Route directly on the encoder thread — both transport services dispatch internally.
            switch frameDispatchGate.negotiatedMode {
            case .tcp:
                self.transportService.sendVideoFrame(encodedFrame)
            case .udp:
                if encodedFrame.isKeyFrame {
                    self.videoDatagramTransportService.noteKeyFrameBoundary()
                    self.transportService.sendVideoFrame(encodedFrame)
                } else {
                    if frameDispatchGate.awaitingFirstRenderedFrame {
                        Task { @MainActor [weak self] in
                            self?.requestRecoveryKeyFrameIfNeeded(
                                minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
                            )
                        }
                        return
                    }
                    self.videoDatagramTransportService.sendVideoFrame(encodedFrame)
                }
            }

            // Only the metrics counter requires MainActor.
            Task { @MainActor [weak self] in
                self?.recordOutboundFrame(encodedFrame)
            }
        }

        encoderService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.lastErrorMessage = error.localizedDescription
            }
        }

        captureService.onCapturedFrame = { [weak self] frame in
            guard self != nil else { return }
            guard frameDispatchGate.isRunning else { return }

            if frame.metadata.frameIndex % 30 == 0 {
                print("[Sender] Captured frame \(frame.metadata.frameIndex): \(frame.metadata.width)x\(frame.metadata.height), hasPB=\(frame.pixelBuffer != nil)")
            }

            _ = encoder.encode(frame: frame)
        }

        captureService.onCapturedAudio = { [weak self] audioPacket in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state == .running else { return }
                self.transportService.sendAudioPacket(audioPacket)
            }
        }

        captureService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.lastErrorMessage = error.localizedDescription
            }
        }

        wiredPathMonitor.onUpdate = { [weak self] isAvailable in
            guard let self else { return }
            Task { @MainActor in
                self.wiredPathAvailable = isAvailable
            }
        }
        wiredPathMonitor.start()

        transportService.onStateChange = { [weak self] isConnected in
            guard let self else { return }
            Task { @MainActor in
                if isConnected {
                    self.state = .waitingForAck
                    self.sendHello()
                } else {
                    self.captureService.stopCapture()

                    // Ignore the synthetic disconnect emitted by TransportService.connect()
                    // when it clears a previous connection before starting a new one.
                    if self.state == .connecting || self.state == .idle {
                        return
                    }

                    if self.shouldMaintainConnection {
                        self.scheduleReconnect(reason: "connection closed")
                    } else {
                        self.state = .idle
                    }
                }
            }
        }

        transportService.onEnvelope = { [weak self] envelope in
            guard let self else { return }
            Task { @MainActor in
                self.handle(envelope: envelope)
            }
        }

        transportService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.lastErrorMessage = error.localizedDescription
                if self.shouldMaintainConnection {
                    self.scheduleReconnect(reason: error.localizedDescription)
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }

        transportService.onDroppedFrameCountChange = { [weak self] count in
            guard let self else { return }
            Task { @MainActor in
                if self.negotiatedVideoTransportMode == .tcp, count > self.droppedOutboundFrameCount {
                    self.requestRecoveryKeyFrameIfNeeded()
                }
                self.droppedOutboundFrameCount = count
            }
        }

        videoDatagramTransportService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.lastErrorMessage = "UDP video transport: \(error.localizedDescription)"
                if self.shouldMaintainConnection,
                   self.negotiatedVideoTransportMode == .udp,
                   (self.state == .connected || self.state == .running) {
                    self.scheduleReconnect(reason: error.localizedDescription)
                }
            }
        }

        videoDatagramTransportService.onStateChange = { [weak self] isConnected in
            guard let self else { return }
            Task { @MainActor in
                guard self.negotiatedVideoTransportMode == .udp else { return }

                if isConnected {
                    if self.awaitingUDPReadyToStart, self.state == .connected {
                        self.awaitingUDPReadyToStart = false
                        self.startSession()
                    } else if self.state == .running {
                        self.requestRecoveryKeyFrameIfNeeded()
                    }
                }
            }
        }

        videoDatagramTransportService.onDroppedFrameCountChange = { [weak self] count in
            guard let self else { return }
            Task { @MainActor in
                guard self.negotiatedVideoTransportMode == .udp else { return }
                if count > self.droppedOutboundFrameCount {
                    self.requestRecoveryKeyFrameIfNeeded(
                        minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
                    )
                }
                self.droppedOutboundFrameCount = count
            }
        }
    }

    deinit {
        wiredPathMonitor.stop()
    }

    /// Connects to receiver and performs handshake only.
    /// `targetWidth` / `targetHeight` are retained as a fallback when the receiver cannot report display metrics.
    func connect(
        receiverHost: String,
        port: UInt16 = NetworkProtocol.defaultPort,
        videoTransportMode: NetworkProtocol.VideoTransportMode = .tcp,
        targetWidth: Int = 2560,
        targetHeight: Int = 1440
    ) {
        desiredHost = receiverHost
        desiredPort = port
        shouldMaintainConnection = true

        self.receiverHost = receiverHost
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        requestedVideoTransportMode = videoTransportMode
        negotiatedVideoTransportMode = videoTransportMode
        frameDispatchGate.setNegotiatedMode(videoTransportMode)
        encoderService.setPreferredKeyFrameIntervalFrames(keyFrameIntervalFrames(for: videoTransportMode))
        sentFrameCount = 0
        droppedOutboundFrameCount = 0
        lastErrorMessage = nil
        sentFramesPerSecond = nil
        sentMegabitsPerSecond = nil
        heartbeatRoundTripMilliseconds = nil
        estimatedDisplayLatencyMilliseconds = nil
        estimatedReceiverClockOffsetNanoseconds = nil
        lastRecoveryKeyFrameRequestAt = nil
        outboundWindowStartNanoseconds = nil
        outboundWindowFrameCount = 0
        outboundWindowPayloadBytes = 0
        targetUsesHiDPI = true
        awaitingUDPReadyToStart = false
        awaitingFirstRenderedFrame = false
        configuredEndpointSummary = "\(receiverHost):\(port) [\(videoTransportMode.rawValue.uppercased())]"
        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        state = .connecting
        captureService.stopCapture()
        if videoTransportMode == .udp {
            videoDatagramTransportService.connect(host: receiverHost, port: port)
        } else {
            videoDatagramTransportService.disconnect()
        }
        transportService.connect(host: receiverHost, port: port)
    }

    /// Starts capture and frame transport after handshake succeeds.
    /// Creates a virtual display for the extended desktop, applies the best matching mode,
    /// reads back the actual live mode, then starts capture.
    func startSession() {
        guard canStartSession else { return }
        state = .running
        awaitingFirstRenderedFrame = negotiatedVideoTransportMode == .udp
        frameDispatchGate.setAwaitingFirstRenderedFrame(awaitingFirstRenderedFrame)
        availableDisplayModes = []
        activeDisplayMode = nil

        if negotiatedVideoTransportMode == .udp {
            requestRecoveryKeyFrameIfNeeded(minimumIntervalSeconds: 0)
        }

        let captureWidth = effectiveCaptureWidth()
        let captureHeight = effectiveCaptureHeight()

        print("[Sender] Starting session: \(captureWidth)x\(captureHeight)")

        // Create virtual display so macOS extends the desktop onto it.
        let virtualDisplayID = virtualDisplayService.createDisplay(
            width: captureWidth,
            height: captureHeight,
            refreshRate: Double(NetworkProtocol.captureFramesPerSecond),
            hiDPI: targetUsesHiDPI
        )

        print("[Sender] Virtual display created with ID: \(virtualDisplayID)")

        // Point capture at the virtual display (or fall back to main display).
        captureService.targetDisplayID = virtualDisplayID

        // Stage 1 (0.25s): CGDisplayCopyAllDisplayModes needs a moment after virtual display
        // creation before it returns the advertised modes. Query modes here and apply the
        // receiver-matched default to override whatever macOS restored from its display prefs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, case .running = self.state else { return }
            guard virtualDisplayID != 0 else { return }

            let modes = self.virtualDisplayService.availableModes()
            self.availableDisplayModes = modes
            print("[Sender] Virtual display exposed \(modes.count) modes")

            if let best = self.bestMatchingMode(
                from: modes,
                logicalWidth: self.receiverLogicalWidth,
                logicalHeight: self.receiverLogicalHeight
            ) {
                print("[Sender] Auto-applying receiver-matched mode: \(best.label)")
                self.virtualDisplayService.apply(mode: best)
            } else {
                print("[Sender] No matching mode found; macOS will use its remembered mode")
            }

            // Stage 2 (0.35s later): mode change has settled; read back live mode and start capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, case .running = self.state else { return }

                let liveMode = self.virtualDisplayService.activeMode()
                self.activeDisplayMode = liveMode

                if let liveMode {
                    print(
                        "[Sender] Active display mode: \(liveMode.shortDescription)" +
                        (liveMode.pixelWidth != captureWidth || liveMode.pixelHeight != captureHeight
                            ? " (requested \(captureWidth)×\(captureHeight))"
                            : "")
                    )
                }

                print("[Sender] Starting capture on display \(virtualDisplayID)")
                self.captureService.startCapture(
                    width: liveMode?.pixelWidth ?? captureWidth,
                    height: liveMode?.pixelHeight ?? captureHeight,
                    framesPerSecond: NetworkProtocol.captureFramesPerSecond
                )
            }
        }
    }

    /// Applies a new display mode while the session is running.
    /// Stops capture, applies the mode, waits for it to settle, then restarts capture.
    func changeDisplayMode(_ mode: VirtualDisplayMode) {
        guard state == .running, virtualDisplayService.isActive else { return }

        print("[Sender] User changing display mode to: \(mode.label)")
        captureService.stopCapture()
        virtualDisplayService.apply(mode: mode)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, case .running = self.state else { return }

            let liveMode = self.virtualDisplayService.activeMode()
            self.activeDisplayMode = liveMode
            let live = liveMode ?? mode

            print("[Sender] Mode change settled: \(live.shortDescription)")
            self.captureService.startCapture(
                width: live.pixelWidth,
                height: live.pixelHeight,
                framesPerSecond: NetworkProtocol.captureFramesPerSecond
            )
        }
    }

    /// Stops sender session and resets services to idle placeholders.
    func stopSession() {
        shouldMaintainConnection = false
        stopHeartbeatTimers()
        captureService.stopCapture()
        virtualDisplayService.destroyDisplay()
        videoDatagramTransportService.disconnect()
        transportService.disconnect()
        state = .idle
        sentFramesPerSecond = nil
        sentMegabitsPerSecond = nil
        heartbeatRoundTripMilliseconds = nil
        estimatedDisplayLatencyMilliseconds = nil
        estimatedReceiverClockOffsetNanoseconds = nil
        lastRecoveryKeyFrameRequestAt = nil
        awaitingUDPReadyToStart = false
        awaitingFirstRenderedFrame = false
        frameDispatchGate.setAwaitingFirstRenderedFrame(false)
        droppedOutboundFrameCount = 0
        outboundWindowStartNanoseconds = nil
        outboundWindowFrameCount = 0
        outboundWindowPayloadBytes = 0
        availableDisplayModes = []
        activeDisplayMode = nil
    }

    /// Sends one manual synthetic frame for pipeline smoke testing.
    func sendPlaceholderFrame() {
        let metadata = FrameMetadata(
            frameIndex: sentFrameCount,
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            width: targetWidth,
            height: targetHeight,
            isKeyFrame: sentFrameCount == 0
        )
        let bytesPerRow = max(1, targetWidth * 4)
        let byteCount = bytesPerRow * targetHeight
        let synthetic = CapturedFrame(
            metadata: metadata,
            rawData: Data(repeating: 0x7F, count: max(0, byteCount)),
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8
        )
        _ = encoderService.encode(frame: synthetic)
    }

    // MARK: - Frame Pipeline

    private func pushEncodedFrame(_ encodedFrame: EncodedFrame) {
        switch negotiatedVideoTransportMode {
        case .tcp:
            transportService.sendVideoFrame(encodedFrame)
        case .udp:
            if encodedFrame.isKeyFrame {
                videoDatagramTransportService.noteKeyFrameBoundary()
                transportService.sendVideoFrame(encodedFrame)
            } else {
                if awaitingFirstRenderedFrame {
                    requestRecoveryKeyFrameIfNeeded(
                        minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
                    )
                    return
                }
                videoDatagramTransportService.sendVideoFrame(encodedFrame)
            }
        }
        recordOutboundFrame(encodedFrame)
    }

    private func recordOutboundFrame(_ encodedFrame: EncodedFrame) {
        sentFrameCount += 1
        updateOutboundMetrics(payloadByteCount: encodedFrame.payload.count)
    }

    private func updateOutboundMetrics(payloadByteCount: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        if outboundWindowStartNanoseconds == nil {
            outboundWindowStartNanoseconds = now
        }

        outboundWindowFrameCount += 1
        outboundWindowPayloadBytes += UInt64(max(0, payloadByteCount))

        guard let windowStart = outboundWindowStartNanoseconds, now >= windowStart else { return }
        let elapsedNanoseconds = now - windowStart
        guard elapsedNanoseconds >= 1_000_000_000 else { return }

        let elapsedSeconds = Double(elapsedNanoseconds) / 1_000_000_000.0
        sentFramesPerSecond = Double(outboundWindowFrameCount) / elapsedSeconds
        sentMegabitsPerSecond = (Double(outboundWindowPayloadBytes) * 8.0) / elapsedSeconds / 1_000_000.0

        outboundWindowStartNanoseconds = now
        outboundWindowFrameCount = 0
        outboundWindowPayloadBytes = 0
    }

    private func sendHello() {
        transportService.sendHello(
            senderName: Host.current().localizedName ?? "DisplaySender",
            preferredVideoTransport: requestedVideoTransportMode,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
    }

    private func handle(envelope: NetworkEnvelope) {
        do {
            switch envelope.type {
            case .helloAck:
                let ack = try envelope.decodePayload(as: HelloAckPayload.self)
                if ack.accepted {
                    applyReceiverDisplayMetrics(ack.displayMetrics)
                    applyNegotiatedVideoTransport(ack.negotiatedVideoTransport ?? requestedVideoTransportMode)
                    state = .connected
                    lastInboundHeartbeatAt = Date()
                    startHeartbeatTimers()
                    // Auto-start once both the handshake and the selected video transport are ready.
                    if negotiatedVideoTransportMode == .udp && !videoDatagramTransportService.isConnected {
                        awaitingUDPReadyToStart = true
                    } else {
                        startSession()
                    }
                } else {
                    state = .failed(ack.reason ?? "receiver rejected handshake")
                    shouldMaintainConnection = false
                    captureService.stopCapture()
                    videoDatagramTransportService.disconnect()
                    transportService.disconnect()
                }
            case .heartbeat:
                let heartbeat = try envelope.decodePayload(as: HeartbeatPayload.self)
                lastInboundHeartbeatAt = Date()
                updateLatencyMetrics(
                    from: heartbeat,
                    localReceiveTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            case .requestKeyFrame:
                _ = try envelope.decodePayload(as: KeyFrameRequestPayload.self)
                requestRecoveryKeyFrameIfNeeded(minimumIntervalSeconds: 0)
            default:
                break
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func startHeartbeatTimers() {
        stopHeartbeatTimers()

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: NetworkProtocol.heartbeatIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.transportService.sendHeartbeat()
            }
        }

        heartbeatTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHeartbeatTimeout()
            }
        }
    }

    private func stopHeartbeatTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        heartbeatTimeoutTimer?.invalidate()
        heartbeatTimeoutTimer = nil
    }

    private func checkHeartbeatTimeout() {
        guard shouldMaintainConnection else { return }
        guard state == .running || state == .connected else { return }
        guard let lastInboundHeartbeatAt else { return }

        let elapsed = Date().timeIntervalSince(lastInboundHeartbeatAt)
        if elapsed > NetworkProtocol.heartbeatTimeoutSeconds {
            scheduleReconnect(reason: "heartbeat timeout")
        }
    }

    private func scheduleReconnect(reason: String) {
        lastErrorMessage = reason
        state = .connecting
        heartbeatRoundTripMilliseconds = nil
        estimatedDisplayLatencyMilliseconds = nil
        estimatedReceiverClockOffsetNanoseconds = nil
        lastRecoveryKeyFrameRequestAt = nil
        awaitingUDPReadyToStart = false
        awaitingFirstRenderedFrame = false
        frameDispatchGate.setAwaitingFirstRenderedFrame(false)
        availableDisplayModes = []
        activeDisplayMode = nil
        stopHeartbeatTimers()
        captureService.stopCapture()
        virtualDisplayService.destroyDisplay()
        videoDatagramTransportService.disconnect()
        transportService.disconnect()

        guard shouldMaintainConnection, let host = desiredHost else { return }

        Timer.scheduledTimer(withTimeInterval: NetworkProtocol.reconnectDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldMaintainConnection else { return }
                if self.requestedVideoTransportMode == .udp {
                    self.videoDatagramTransportService.connect(host: host, port: self.desiredPort)
                }
                self.transportService.connect(host: host, port: self.desiredPort)
            }
        }
    }

    private func effectiveCaptureWidth() -> Int {
        if NetworkProtocol.preferRawFrameTransportForDiagnostics {
            return min(targetWidth, NetworkProtocol.rawDiagnosticsMaxWidth)
        }
        return targetWidth
    }

    private func effectiveCaptureHeight() -> Int {
        if NetworkProtocol.preferRawFrameTransportForDiagnostics {
            return min(targetHeight, NetworkProtocol.rawDiagnosticsMaxHeight)
        }
        return targetHeight
    }

    private func applyReceiverDisplayMetrics(_ displayMetrics: ReceiverDisplayMetrics?) {
        guard let displayMetrics else {
            print("[Sender] Receiver did not advertise display metrics; using fallback \(targetWidth)x\(targetHeight)")
            receiverLogicalWidth = targetWidth
            receiverLogicalHeight = targetHeight
            return
        }

        let negotiatedWidth = max(1, displayMetrics.logicalWidth)
        let negotiatedHeight = max(1, displayMetrics.logicalHeight)
        targetWidth = negotiatedWidth
        targetHeight = negotiatedHeight
        targetUsesHiDPI = displayMetrics.backingScaleFactor > 1.0
        receiverLogicalWidth = negotiatedWidth
        receiverLogicalHeight = negotiatedHeight

        print(
            "[Sender] Using receiver display metrics: logical=\(negotiatedWidth)x\(negotiatedHeight), " +
            "pixels=\(displayMetrics.pixelWidth)x\(displayMetrics.pixelHeight), " +
            "scale=\(String(format: "%.2f", displayMetrics.backingScaleFactor)), " +
            "hiDPI=\(targetUsesHiDPI)"
        )
    }

    /// Selects the best mode from the available list that matches the receiver's logical resolution.
    /// Falls back to the closest by pixel area if no exact logical match is found.
    private func bestMatchingMode(from modes: [VirtualDisplayMode], logicalWidth: Int, logicalHeight: Int) -> VirtualDisplayMode? {
        guard !modes.isEmpty else { return nil }

        // Prefer an exact logical-dimension match (receiver's native resolution at Retina scale).
        if let exact = modes.first(where: { $0.logicalWidth == logicalWidth && $0.logicalHeight == logicalHeight }) {
            return exact
        }

        // Fall back: pick the mode whose pixel area is closest to the receiver's pixel area.
        let targetPixelArea = logicalWidth * logicalHeight * (targetUsesHiDPI ? 4 : 1)
        return modes.min(by: {
            abs($0.pixelWidth * $0.pixelHeight - targetPixelArea) <
            abs($1.pixelWidth * $1.pixelHeight - targetPixelArea)
        })
    }

    private func applyNegotiatedVideoTransport(_ videoTransportMode: NetworkProtocol.VideoTransportMode) {
        negotiatedVideoTransportMode = videoTransportMode
        frameDispatchGate.setNegotiatedMode(videoTransportMode)
        encoderService.setPreferredKeyFrameIntervalFrames(keyFrameIntervalFrames(for: videoTransportMode))
        if videoTransportMode == .udp {
            if let desiredHost {
                videoDatagramTransportService.connect(host: desiredHost, port: desiredPort)
            }
        } else {
            awaitingUDPReadyToStart = false
            awaitingFirstRenderedFrame = false
            videoDatagramTransportService.disconnect()
        }
    }

    private func requestRecoveryKeyFrameIfNeeded(
        minimumIntervalSeconds: TimeInterval = Double(NetworkProtocol.keyFrameIntervalSeconds)
    ) {
        let now = Date()
        if let lastRecoveryKeyFrameRequestAt,
           now.timeIntervalSince(lastRecoveryKeyFrameRequestAt) < minimumIntervalSeconds {
            return
        }

        lastRecoveryKeyFrameRequestAt = now
        encoderService.requestKeyFrame()
    }

    private func keyFrameIntervalFrames(for videoTransportMode: NetworkProtocol.VideoTransportMode) -> Int {
        switch videoTransportMode {
        case .tcp:
            return NetworkProtocol.targetFramesPerSecond * NetworkProtocol.keyFrameIntervalSeconds
        case .udp:
            return NetworkProtocol.udpKeyFrameIntervalFrames
        }
    }

    private func updateLatencyMetrics(
        from heartbeat: HeartbeatPayload,
        localReceiveTimestampNanoseconds: UInt64
    ) {
        guard let originTimestampNanoseconds = heartbeat.originTimestampNanoseconds,
              let receiveTimestampNanoseconds = heartbeat.receiveTimestampNanoseconds else {
            return
        }

        let receiverProcessingNanoseconds = max(
            0,
            Int64(heartbeat.transmitTimestampNanoseconds) - Int64(receiveTimestampNanoseconds)
        )
        let localElapsedNanoseconds = max(
            0,
            Int64(localReceiveTimestampNanoseconds) - Int64(originTimestampNanoseconds)
        )
        let roundTripNanoseconds = max(0, localElapsedNanoseconds - receiverProcessingNanoseconds)
        heartbeatRoundTripMilliseconds = smoothMetric(
            current: heartbeatRoundTripMilliseconds,
            sample: Double(roundTripNanoseconds) / 1_000_000.0,
            alpha: 0.20
        )

        let receiverClockOffsetNanoseconds =
            ((Int64(receiveTimestampNanoseconds) - Int64(originTimestampNanoseconds))
             + (Int64(heartbeat.transmitTimestampNanoseconds) - Int64(localReceiveTimestampNanoseconds))) / 2
        estimatedReceiverClockOffsetNanoseconds = receiverClockOffsetNanoseconds

        if negotiatedVideoTransportMode == .udp {
            if heartbeat.renderedFrameIndex != nil {
                awaitingFirstRenderedFrame = false
                frameDispatchGate.setAwaitingFirstRenderedFrame(false)
            } else if awaitingFirstRenderedFrame {
                requestRecoveryKeyFrameIfNeeded(
                    minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
                )
            }
        }

        guard let renderedFrameSenderTimestampNanoseconds = heartbeat.renderedFrameSenderTimestampNanoseconds,
              let renderedFrameReceiverTimestampNanoseconds = heartbeat.renderedFrameReceiverTimestampNanoseconds else {
            return
        }

        let senderTimestampOnReceiverClock =
            Int64(renderedFrameSenderTimestampNanoseconds) + receiverClockOffsetNanoseconds
        let displayLatencyNanoseconds =
            Int64(renderedFrameReceiverTimestampNanoseconds) - senderTimestampOnReceiverClock
        guard displayLatencyNanoseconds >= 0 else { return }

        estimatedDisplayLatencyMilliseconds = smoothMetric(
            current: estimatedDisplayLatencyMilliseconds,
            sample: Double(displayLatencyNanoseconds) / 1_000_000.0,
            alpha: 0.15
        )
    }

    private func smoothMetric(current: Double?, sample: Double, alpha: Double) -> Double {
        guard sample.isFinite else { return current ?? 0 }
        guard let current else { return sample }
        return (alpha * sample) + ((1.0 - alpha) * current)
    }
}

private final class SenderFrameDispatchGate {
    private let lock = NSLock()
    private var _running = false
    private var _negotiatedMode: NetworkProtocol.VideoTransportMode = .tcp
    private var _awaitingFirstRenderedFrame = false

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _running
    }

    /// The negotiated video transport mode, safe to read from any thread.
    var negotiatedMode: NetworkProtocol.VideoTransportMode {
        lock.lock(); defer { lock.unlock() }
        return _negotiatedMode
    }

    /// Whether the pipeline is waiting for the first UDP frame to reach the renderer.
    var awaitingFirstRenderedFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        return _awaitingFirstRenderedFrame
    }

    func setRunning(_ value: Bool) {
        lock.lock(); _running = value; lock.unlock()
    }

    func setNegotiatedMode(_ value: NetworkProtocol.VideoTransportMode) {
        lock.lock(); _negotiatedMode = value; lock.unlock()
    }

    func setAwaitingFirstRenderedFrame(_ value: Bool) {
        lock.lock(); _awaitingFirstRenderedFrame = value; lock.unlock()
    }
}
