import AppKit
import Foundation

/// Coordinates sender-side capture, encoding, and transport lifecycle.
@MainActor
final class SenderSessionCoordinator {
    private enum CursorHandoffEdge: String {
        case left
        case right
        case top
        case bottom
    }

    enum SessionState: Equatable {
        case idle
        case connecting
        case waitingForAck
        case connected
        case running
        case failed(String)
    }

    enum DisplayResolutionPreference: String, CaseIterable, Identifiable {
        case matchReceiver
        case fixedPreset

        var id: String { rawValue }

        var label: String {
            switch self {
            case .matchReceiver:
                return "Match Receiver"
            case .fixedPreset:
                return "Fixed Preset"
            }
        }
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
    private(set) var captureToEncodeLatencyMilliseconds: Double? { didSet { onChange?() } }
    private(set) var encodeToReceiveLatencyMilliseconds: Double? { didSet { onChange?() } }
    private(set) var receiveToRenderLatencyMilliseconds: Double? { didSet { onChange?() } }
    private(set) var requestedVideoTransportMode: NetworkProtocol.VideoTransportMode = .tcp { didSet { onChange?() } }
    private(set) var negotiatedVideoTransportMode: NetworkProtocol.VideoTransportMode = .tcp { didSet { onChange?() } }
    private(set) var streamingPipelinePreference: NetworkProtocol.StreamingPipelinePreference = .automatic { didSet { onChange?() } }
    private(set) var resolvedStreamingPipelineMode: NetworkProtocol.StreamingPipelineMode =
        NetworkProtocol.resolvedStreamingPipelineMode(for: .automatic) { didSet { onChange?() } }
    private(set) var displayResolutionPreference: DisplayResolutionPreference = .matchReceiver { didSet { onChange?() } }
    private(set) var preferredDisplayPreset: VirtualDisplayPreset = .defaultFixed { didSet { onChange?() } }

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
    private var cursorTrackingRefreshTimer: DispatchSourceTimer?
    private var localCursorEventMonitor: Any?
    private var globalCursorEventMonitor: Any?
    private var lastSentCursorState: CursorStatePayload?
    private var lastSentCursorAppearanceSignature: UInt64?
    private var cachedCursorAppearance: CursorAppearancePayload?
    private var nextCursorAppearanceRefreshNanoseconds: UInt64 = 0
    private var lastCursorDebugStatus: String?
    private var lastVisibleCursorNormalizedPosition: CGPoint?
    private var lastVisibleCursorTimestampNanoseconds: UInt64?
    private var lastCursorHandoffEdge: CursorHandoffEdge?

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
        encoderService.setPreferredKeyFrameIntervalFrames(NetworkProtocol.keyFrameIntervalFrames(for: videoTransportMode))
        sentFrameCount = 0
        droppedOutboundFrameCount = 0
        lastErrorMessage = nil
        sentFramesPerSecond = nil
        sentMegabitsPerSecond = nil
        heartbeatRoundTripMilliseconds = nil
        estimatedDisplayLatencyMilliseconds = nil
        captureToEncodeLatencyMilliseconds = nil
        encodeToReceiveLatencyMilliseconds = nil
        receiveToRenderLatencyMilliseconds = nil
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
        stopCursorTracking(sendHiddenState: false)
        captureService.stopCapture()
        // Wait until the receiver explicitly negotiates UDP before opening the datagram path.
        // Pre-connecting here can fail before the handshake finishes and strand the sender
        // in a connected-but-never-starting state.
        videoDatagramTransportService.disconnect()
        transportService.connect(host: receiverHost, port: port)
    }

    /// Starts capture and frame transport after handshake succeeds.
    /// Creates a virtual display for the extended desktop, applies the configured startup mode,
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
        let displayUsesHiDPI = effectiveDisplayUsesHiDPI()

        print("[Sender] Starting session: \(captureWidth)x\(captureHeight)")
        print(
            "[Sender] Streaming pipeline: preference=\(streamingPipelinePreference.rawValue), " +
            "resolved=\(resolvedStreamingPipelineMode.rawValue), " +
            "tier=\(NetworkProtocol.detectedVideoHardwareTier.rawValue), " +
            "chip=\"\(NetworkProtocol.currentChipBrandString)\""
        )
        print(
            "[Sender] Display resolution: preference=\(displayResolutionPreference.rawValue), " +
            "preset=\(preferredDisplayPreset.id)"
        )

        // Create virtual display so macOS extends the desktop onto it.
        let virtualDisplayID = virtualDisplayService.createDisplay(
            width: captureWidth,
            height: captureHeight,
            refreshRate: Double(NetworkProtocol.captureFramesPerSecond),
            hiDPI: displayUsesHiDPI
        )

        print("[Sender] Virtual display created with ID: \(virtualDisplayID)")

        // Point capture at the virtual display (or fall back to main display).
        captureService.targetDisplayID = virtualDisplayID
        if NetworkProtocol.enableReceiverSideCursorOverlay {
            startCursorTracking(for: virtualDisplayID)
        }

        // Stage 1 (0.25s): CGDisplayCopyAllDisplayModes needs a moment after virtual display
        // creation before it returns the advertised modes. Query modes here and apply the
        // configured startup mode to override whatever macOS restored from its display prefs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, case .running = self.state else { return }
            guard virtualDisplayID != 0 else { return }

            let modes = self.virtualDisplayService.availableModes()
            self.availableDisplayModes = modes
            print("[Sender] Virtual display exposed \(modes.count) modes")

            if let preferred = self.preferredStartupMode(from: modes) {
                switch self.displayResolutionPreference {
                case .matchReceiver:
                    print("[Sender] Auto-applying receiver-matched mode: \(preferred.label)")
                case .fixedPreset:
                    print("[Sender] Auto-applying fixed startup mode: \(preferred.label)")
                }
                self.virtualDisplayService.apply(mode: preferred)
            } else {
                print("[Sender] No preferred startup mode found; macOS will use its remembered mode")
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
                    framesPerSecond: NetworkProtocol.captureFramesPerSecond,
                    streamingPipelineMode: self.resolvedStreamingPipelineMode,
                    showsCursor: NetworkProtocol.showSenderCursorFallbackWhileTestingOverlay || !NetworkProtocol.enableReceiverSideCursorOverlay
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
                framesPerSecond: NetworkProtocol.captureFramesPerSecond,
                streamingPipelineMode: self.resolvedStreamingPipelineMode,
                showsCursor: NetworkProtocol.showSenderCursorFallbackWhileTestingOverlay || !NetworkProtocol.enableReceiverSideCursorOverlay
            )
        }
    }

    /// Stops sender session and resets services to idle placeholders.
    func stopSession() {
        shouldMaintainConnection = false
        stopHeartbeatTimers()
        stopCursorTracking(sendHiddenState: true)
        captureService.stopCapture()
        virtualDisplayService.destroyDisplay()
        videoDatagramTransportService.disconnect()
        transportService.disconnect()
        state = .idle
        sentFramesPerSecond = nil
        sentMegabitsPerSecond = nil
        heartbeatRoundTripMilliseconds = nil
        estimatedDisplayLatencyMilliseconds = nil
        captureToEncodeLatencyMilliseconds = nil
        encodeToReceiveLatencyMilliseconds = nil
        receiveToRenderLatencyMilliseconds = nil
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
                    state = .connected
                    lastInboundHeartbeatAt = Date()
                    startHeartbeatTimers()
                    applyNegotiatedVideoTransport(ack.negotiatedVideoTransport ?? requestedVideoTransportMode)
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
            case .cursorState:
                break
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
        captureToEncodeLatencyMilliseconds = nil
        encodeToReceiveLatencyMilliseconds = nil
        receiveToRenderLatencyMilliseconds = nil
        estimatedReceiverClockOffsetNanoseconds = nil
        lastRecoveryKeyFrameRequestAt = nil
        awaitingUDPReadyToStart = false
        awaitingFirstRenderedFrame = false
        frameDispatchGate.setAwaitingFirstRenderedFrame(false)
        availableDisplayModes = []
        activeDisplayMode = nil
        stopHeartbeatTimers()
        stopCursorTracking(sendHiddenState: false)
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
            let preferredWidth = displayResolutionPreference == .fixedPreset ? preferredDisplayPreset.pixelWidth : targetWidth
            return min(preferredWidth, NetworkProtocol.rawDiagnosticsMaxWidth)
        }
        if displayResolutionPreference == .fixedPreset {
            return preferredDisplayPreset.pixelWidth
        }
        return targetWidth
    }

    private func effectiveCaptureHeight() -> Int {
        if NetworkProtocol.preferRawFrameTransportForDiagnostics {
            let preferredHeight = displayResolutionPreference == .fixedPreset ? preferredDisplayPreset.pixelHeight : targetHeight
            return min(preferredHeight, NetworkProtocol.rawDiagnosticsMaxHeight)
        }
        if displayResolutionPreference == .fixedPreset {
            return preferredDisplayPreset.pixelHeight
        }
        return targetHeight
    }

    private func effectiveDisplayUsesHiDPI() -> Bool {
        if displayResolutionPreference == .fixedPreset {
            return preferredDisplayPreset.usesHiDPI
        }
        return targetUsesHiDPI
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

    private func preferredStartupMode(from modes: [VirtualDisplayMode]) -> VirtualDisplayMode? {
        guard !modes.isEmpty else { return nil }

        switch displayResolutionPreference {
        case .matchReceiver:
            return bestMatchingMode(
                from: modes,
                logicalWidth: receiverLogicalWidth,
                logicalHeight: receiverLogicalHeight
            )
        case .fixedPreset:
            if let exact = modes.first(where: {
                $0.pixelWidth == preferredDisplayPreset.pixelWidth &&
                $0.pixelHeight == preferredDisplayPreset.pixelHeight &&
                $0.isRetina == preferredDisplayPreset.usesHiDPI
            }) {
                return exact
            }

            if let exactPixelSize = modes.first(where: {
                $0.pixelWidth == preferredDisplayPreset.pixelWidth &&
                $0.pixelHeight == preferredDisplayPreset.pixelHeight
            }) {
                return exactPixelSize
            }

            let targetPixelArea = preferredDisplayPreset.pixelWidth * preferredDisplayPreset.pixelHeight
            return modes.min(by: {
                abs($0.pixelWidth * $0.pixelHeight - targetPixelArea) <
                abs($1.pixelWidth * $1.pixelHeight - targetPixelArea)
            })
        }
    }

    private func applyPreferredDisplayModeIfRunning() {
        guard state == .running, virtualDisplayService.isActive else { return }
        let modes = availableDisplayModes.isEmpty ? virtualDisplayService.availableModes() : availableDisplayModes
        availableDisplayModes = modes
        guard let preferred = preferredStartupMode(from: modes) else { return }
        guard activeDisplayMode != preferred else { return }
        changeDisplayMode(preferred)
    }

    private func applyNegotiatedVideoTransport(_ videoTransportMode: NetworkProtocol.VideoTransportMode) {
        negotiatedVideoTransportMode = videoTransportMode
        frameDispatchGate.setNegotiatedMode(videoTransportMode)
        encoderService.setPreferredKeyFrameIntervalFrames(NetworkProtocol.keyFrameIntervalFrames(for: videoTransportMode))
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

    func setStreamingPipelinePreference(_ preference: NetworkProtocol.StreamingPipelinePreference) {
        guard preference != streamingPipelinePreference else { return }
        streamingPipelinePreference = preference
        resolvedStreamingPipelineMode = NetworkProtocol.resolvedStreamingPipelineMode(for: preference)
    }

    func setDisplayResolutionPreference(_ preference: DisplayResolutionPreference) {
        guard preference != displayResolutionPreference else { return }
        displayResolutionPreference = preference
        applyPreferredDisplayModeIfRunning()
    }

    func setPreferredDisplayPreset(_ preset: VirtualDisplayPreset) {
        guard preset != preferredDisplayPreset else { return }
        preferredDisplayPreset = preset
        applyPreferredDisplayModeIfRunning()
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

    private func updateLatencyMetrics(
        from heartbeat: HeartbeatPayload,
        localReceiveTimestampNanoseconds: UInt64
    ) {
        guard let evaluation = NetworkProtocol.evaluateSenderHeartbeat(
            heartbeat,
            localReceiveTimestampNanoseconds: localReceiveTimestampNanoseconds,
            negotiatedVideoTransportMode: negotiatedVideoTransportMode,
            awaitingFirstRenderedFrame: awaitingFirstRenderedFrame
        ) else {
            return
        }

        heartbeatRoundTripMilliseconds = smoothMetric(
            current: heartbeatRoundTripMilliseconds,
            sample: evaluation.roundTripMilliseconds,
            alpha: 0.20
        )

        estimatedReceiverClockOffsetNanoseconds = evaluation.receiverClockOffsetNanoseconds

        if evaluation.shouldClearAwaitingFirstRenderedFrame {
            awaitingFirstRenderedFrame = false
            frameDispatchGate.setAwaitingFirstRenderedFrame(false)
        } else if evaluation.shouldRequestRecoveryKeyFrame {
            requestRecoveryKeyFrameIfNeeded(
                minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
            )
        }

        if let displayLatencyMilliseconds = evaluation.displayLatencyMilliseconds {
            estimatedDisplayLatencyMilliseconds = smoothMetric(
                current: estimatedDisplayLatencyMilliseconds,
                sample: displayLatencyMilliseconds,
                alpha: 0.15
            )
        }

        if let captureToEncodeMilliseconds = evaluation.captureToEncodeMilliseconds {
            self.captureToEncodeLatencyMilliseconds = smoothMetric(
                current: self.captureToEncodeLatencyMilliseconds,
                sample: captureToEncodeMilliseconds,
                alpha: 0.18
            )
        }

        if let encodeToReceiveMilliseconds = evaluation.encodeToReceiveMilliseconds {
            self.encodeToReceiveLatencyMilliseconds = smoothMetric(
                current: self.encodeToReceiveLatencyMilliseconds,
                sample: encodeToReceiveMilliseconds,
                alpha: 0.18
            )
        }

        if let receiveToRenderMilliseconds = evaluation.receiveToRenderMilliseconds {
            self.receiveToRenderLatencyMilliseconds = smoothMetric(
                current: self.receiveToRenderLatencyMilliseconds,
                sample: receiveToRenderMilliseconds,
                alpha: 0.18
            )
        }
    }

    private func smoothMetric(current: Double?, sample: Double, alpha: Double) -> Double {
        guard sample.isFinite else { return current ?? 0 }
        guard let current else { return sample }
        return (alpha * sample) + ((1.0 - alpha) * current)
    }

    private func startCursorTracking(for displayID: CGDirectDisplayID) {
        stopCursorTracking(sendHiddenState: false)
        guard displayID != 0 else { return }

        lastSentCursorState = nil
        lastSentCursorAppearanceSignature = nil
        cachedCursorAppearance = nil
        nextCursorAppearanceRefreshNanoseconds = 0
        lastCursorDebugStatus = nil
        lastVisibleCursorNormalizedPosition = nil
        lastVisibleCursorTimestampNanoseconds = nil
        lastCursorHandoffEdge = nil
        logCursorDebug("tracking started for display \(displayID)")
        installCursorEventMonitors(for: displayID)
        startCursorRefreshTimer(for: displayID)
        pollCursorState(for: displayID)
    }

    private func stopCursorTracking(sendHiddenState: Bool) {
        cursorTrackingRefreshTimer?.setEventHandler {}
        cursorTrackingRefreshTimer?.cancel()
        cursorTrackingRefreshTimer = nil
        removeCursorEventMonitors()

        if sendHiddenState,
           NetworkProtocol.enableReceiverSideCursorOverlay,
           state == .running || state == .connected {
            logCursorDebug("sending hidden cursor state while stopping tracking")
            transportService.sendCursorState(
                CursorStatePayload(
                    timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    normalizedX: 0,
                    normalizedY: 0,
                    isVisible: false,
                    ownershipIntent: .hidden,
                    appearance: nil
                )
            )
        }

        lastSentCursorState = nil
        lastSentCursorAppearanceSignature = nil
        cachedCursorAppearance = nil
        nextCursorAppearanceRefreshNanoseconds = 0
        lastVisibleCursorNormalizedPosition = nil
        lastVisibleCursorTimestampNanoseconds = nil
        lastCursorHandoffEdge = nil
    }

    private func installCursorEventMonitors(for displayID: CGDirectDisplayID) {
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        localCursorEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.pollCursorState(for: displayID)
            }
            return event
        }

        globalCursorEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCursorState(for: displayID)
            }
        }
    }

    private func removeCursorEventMonitors() {
        if let localCursorEventMonitor {
            NSEvent.removeMonitor(localCursorEventMonitor)
            self.localCursorEventMonitor = nil
        }

        if let globalCursorEventMonitor {
            NSEvent.removeMonitor(globalCursorEventMonitor)
            self.globalCursorEventMonitor = nil
        }
    }

    private func startCursorRefreshTimer(for displayID: CGDirectDisplayID) {
        let refreshFramesPerSecond = max(1, NetworkProtocol.cursorAppearanceRefreshFramesPerSecond)
        let intervalNanoseconds = Int(1_000_000_000 / refreshFramesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .nanoseconds(intervalNanoseconds),
            repeating: .nanoseconds(intervalNanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.pollCursorState(for: displayID)
            }
        }
        timer.activate()
        cursorTrackingRefreshTimer = timer
    }

    private func pollCursorState(for displayID: CGDirectDisplayID) {
        guard NetworkProtocol.enableReceiverSideCursorOverlay else { return }
        guard state == .running else { return }
        guard virtualDisplayService.displayID == displayID else { return }

        let nextState = currentCursorState(for: displayID)
        guard shouldSendCursorState(nextState) else { return }
        if let lastSentCursorState {
            if lastSentCursorState.ownershipIntent != nextState.ownershipIntent ||
                lastSentCursorState.isVisible != nextState.isVisible {
                logCursorDebug(
                    String(
                        format: "sending %@ cursor packet for display %u at %.4f, %.4f",
                        nextState.ownershipIntent.rawValue,
                        displayID,
                        nextState.normalizedX,
                        nextState.normalizedY
                    )
                )
            }
        } else {
            logCursorDebug(
                String(
                    format: "sending initial %@ cursor packet for display %u at %.4f, %.4f",
                    nextState.ownershipIntent.rawValue,
                    displayID,
                    nextState.normalizedX,
                    nextState.normalizedY
                )
            )
        }
        if let appearance = nextState.appearance {
            logCursorDebug(
                "sending cursor appearance signature \(appearance.signature) " +
                "size=\(Int(appearance.widthPoints))x\(Int(appearance.heightPoints))"
            )
        }
        lastSentCursorState = nextState
        if let appearance = nextState.appearance {
            lastSentCursorAppearanceSignature = appearance.signature
        }
        transportService.sendCursorState(nextState)
    }

    private func currentCursorState(for displayID: CGDirectDisplayID) -> CursorStatePayload {
        let now = DispatchTime.now().uptimeNanoseconds
        let hiddenState = CursorStatePayload(
            timestampNanoseconds: now,
            normalizedX: 0,
            normalizedY: 0,
            isVisible: false,
            ownershipIntent: .hidden,
            appearance: nil
        )

        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == displayID
        }) else {
            updateCursorDebugStatus("display \(displayID) screen unavailable")
            return hiddenState
        }

        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else {
            updateCursorDebugStatus("display \(displayID) has invalid frame \(NSStringFromRect(frame))")
            return hiddenState
        }

        let mouseLocation = NSEvent.mouseLocation
        guard frame.contains(mouseLocation) else {
            let ownershipIntent = hiddenCursorOwnershipIntent(
                at: now,
                mouseLocation: mouseLocation,
                in: frame
            )
            let lastVisibleCursorNormalizedPosition = self.lastVisibleCursorNormalizedPosition
            updateCursorDebugStatus(
                String(
                    format: "cursor outside display %u mouse=(%.1f, %.1f) frame=%@ ownership=%@",
                    displayID,
                    mouseLocation.x,
                    mouseLocation.y,
                    NSStringFromRect(frame),
                    ownershipIntent.rawValue
                )
            )
            return CursorStatePayload(
                timestampNanoseconds: now,
                normalizedX: Double(lastVisibleCursorNormalizedPosition?.x ?? CGFloat(hiddenState.normalizedX)),
                normalizedY: Double(lastVisibleCursorNormalizedPosition?.y ?? CGFloat(hiddenState.normalizedY)),
                isVisible: false,
                ownershipIntent: ownershipIntent,
                appearance: nil
            )
        }

        let normalizedX = max(0, min(1, (mouseLocation.x - frame.minX) / frame.width))
        let normalizedY = max(0, min(1, (frame.maxY - mouseLocation.y) / frame.height))
        let normalizedPosition = CGPoint(x: normalizedX, y: normalizedY)
        lastVisibleCursorNormalizedPosition = normalizedPosition
        lastVisibleCursorTimestampNanoseconds = now
        let ownershipIntent = visibleCursorOwnershipIntent(
            at: normalizedPosition,
            in: frame,
            nowNanoseconds: now
        )
        if ownershipIntent == .remote {
            lastCursorHandoffEdge = nil
        }
        updateCursorDebugStatus(
            String(
                format: "cursor visible on display %u mouse=(%.1f, %.1f) normalized=(%.4f, %.4f) ownership=%@",
                displayID,
                mouseLocation.x,
                mouseLocation.y,
                normalizedX,
                normalizedY,
                ownershipIntent.rawValue
            )
        )
        guard ownershipIntent == .remote else {
            return CursorStatePayload(
                timestampNanoseconds: now,
                normalizedX: normalizedX,
                normalizedY: normalizedY,
                isVisible: false,
                ownershipIntent: .localHandoff,
                appearance: nil
            )
        }
        let appearance = currentCursorAppearance(forceRefresh: lastSentCursorState == nil)
        let appearanceToSend: CursorAppearancePayload?
        if let appearance,
           lastSentCursorState == nil || appearance.signature != lastSentCursorAppearanceSignature {
            appearanceToSend = appearance
        } else {
            appearanceToSend = nil
        }

        return CursorStatePayload(
            timestampNanoseconds: now,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            isVisible: true,
            ownershipIntent: .remote,
            appearance: appearanceToSend
        )
    }

    private func shouldSendCursorState(_ nextState: CursorStatePayload) -> Bool {
        if nextState.appearance != nil {
            return true
        }

        guard let lastSentCursorState else { return true }
        guard lastSentCursorState.ownershipIntent == nextState.ownershipIntent else { return true }
        guard lastSentCursorState.isVisible == nextState.isVisible else { return true }
        guard nextState.isVisible else { return false }

        let deltaX = abs(lastSentCursorState.normalizedX - nextState.normalizedX)
        let deltaY = abs(lastSentCursorState.normalizedY - nextState.normalizedY)
        return deltaX >= 0.00002 || deltaY >= 0.00002
    }

    private func hiddenCursorOwnershipIntent(
        at nowNanoseconds: UInt64,
        mouseLocation: CGPoint,
        in frame: CGRect
    ) -> CursorOwnershipIntent {
        let recentEdgeHandoffCandidate = wasRecentEdgeHandoffCandidate(at: nowNanoseconds)

        if recentEdgeHandoffCandidate,
           let handoffEdge = cursorHandoffEdgeJustOutside(mouseLocation, in: frame) {
            lastCursorHandoffEdge = handoffEdge
            return .localHandoff
        }

        if recentEdgeHandoffCandidate {
            lastCursorHandoffEdge = lastCursorHandoffEdge ?? recentCursorHandoffEdge()
            return .localHandoff
        }

        lastCursorHandoffEdge = nil
        return .hidden
    }

    private func visibleCursorOwnershipIntent(
        at normalizedPosition: CGPoint,
        in frame: CGRect,
        nowNanoseconds: UInt64
    ) -> CursorOwnershipIntent {
        let recentEdgeHandoffCandidate = wasRecentEdgeHandoffCandidate(at: nowNanoseconds)
        let handoffEdge = lastCursorHandoffEdge ?? recentCursorHandoffEdge()

        if recentEdgeHandoffCandidate,
           lastSentCursorState?.ownershipIntent == .localHandoff {
            return canReacquireRemoteCursor(
                at: normalizedPosition,
                through: handoffEdge,
                in: frame
            ) ? .remote : .localHandoff
        }

        if lastSentCursorState?.ownershipIntent == .hidden,
           recentEdgeHandoffCandidate,
           !canReacquireRemoteCursor(
               at: normalizedPosition,
               through: handoffEdge,
               in: frame
           ) {
            return .localHandoff
        }

        return .remote
    }

    private func wasRecentEdgeHandoffCandidate(at nowNanoseconds: UInt64) -> Bool {
        guard let lastVisibleCursorNormalizedPosition,
              let lastVisibleCursorTimestampNanoseconds,
              nowNanoseconds >= lastVisibleCursorTimestampNanoseconds,
              (nowNanoseconds - lastVisibleCursorTimestampNanoseconds) <= NetworkProtocol.cursorHandoffDetectionWindowNanoseconds,
              isNearCursorHandoffEdge(lastVisibleCursorNormalizedPosition) else {
            return false
        }

        return true
    }

    private func isNearCursorHandoffEdge(_ normalizedPosition: CGPoint) -> Bool {
        let threshold = NetworkProtocol.cursorHandoffEdgeThresholdNormalized
        return normalizedPosition.x <= threshold ||
            normalizedPosition.x >= (1.0 - threshold) ||
            normalizedPosition.y <= threshold ||
            normalizedPosition.y >= (1.0 - threshold)
    }

    private func canReacquireRemoteCursor(
        at normalizedPosition: CGPoint,
        through handoffEdge: CursorHandoffEdge?,
        in frame: CGRect
    ) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return true }
        let horizontalThreshold = NetworkProtocol.cursorHandoffReacquireInsetPoints / frame.width
        let verticalThreshold = NetworkProtocol.cursorHandoffReacquireInsetPoints / frame.height
        switch handoffEdge {
        case .left:
            return normalizedPosition.x > horizontalThreshold
        case .right:
            return normalizedPosition.x < (1.0 - horizontalThreshold)
        case .top:
            return normalizedPosition.y > verticalThreshold
        case .bottom:
            return normalizedPosition.y < (1.0 - verticalThreshold)
        case .none:
            return true
        }
    }

    private func cursorHandoffEdgeJustOutside(
        _ mouseLocation: CGPoint,
        in frame: CGRect
    ) -> CursorHandoffEdge? {
        guard frame.width > 0, frame.height > 0 else { return nil }

        let horizontalTolerance = frame.width * NetworkProtocol.cursorHandoffEdgeThresholdNormalized
        let verticalTolerance = frame.height * NetworkProtocol.cursorHandoffEdgeThresholdNormalized

        let horizontallyAligned =
            mouseLocation.x >= (frame.minX - horizontalTolerance) &&
            mouseLocation.x <= (frame.maxX + horizontalTolerance)
        let verticallyAligned =
            mouseLocation.y >= (frame.minY - verticalTolerance) &&
            mouseLocation.y <= (frame.maxY + verticalTolerance)

        let nearLeftEdge =
            verticallyAligned &&
            mouseLocation.x <= frame.minX &&
            mouseLocation.x >= (frame.minX - horizontalTolerance)
        let nearRightEdge =
            verticallyAligned &&
            mouseLocation.x >= frame.maxX &&
            mouseLocation.x <= (frame.maxX + horizontalTolerance)
        let nearBottomEdge =
            horizontallyAligned &&
            mouseLocation.y <= frame.minY &&
            mouseLocation.y >= (frame.minY - verticalTolerance)
        let nearTopEdge =
            horizontallyAligned &&
            mouseLocation.y >= frame.maxY &&
            mouseLocation.y <= (frame.maxY + verticalTolerance)

        if nearLeftEdge { return .left }
        if nearRightEdge { return .right }
        if nearTopEdge { return .top }
        if nearBottomEdge { return .bottom }
        return nil
    }

    private func recentCursorHandoffEdge() -> CursorHandoffEdge? {
        guard let lastVisibleCursorNormalizedPosition else { return nil }
        return cursorHandoffEdge(near: lastVisibleCursorNormalizedPosition)
    }

    private func cursorHandoffEdge(near normalizedPosition: CGPoint) -> CursorHandoffEdge? {
        let threshold = NetworkProtocol.cursorHandoffEdgeThresholdNormalized
        var candidates: [(edge: CursorHandoffEdge, distance: CGFloat)] = []

        if normalizedPosition.x <= threshold {
            candidates.append((.left, normalizedPosition.x))
        }
        if normalizedPosition.x >= (1.0 - threshold) {
            candidates.append((.right, 1.0 - normalizedPosition.x))
        }
        if normalizedPosition.y <= threshold {
            candidates.append((.top, normalizedPosition.y))
        }
        if normalizedPosition.y >= (1.0 - threshold) {
            candidates.append((.bottom, 1.0 - normalizedPosition.y))
        }

        return candidates.min(by: { $0.distance < $1.distance })?.edge
    }

    private func currentCursorAppearance(forceRefresh: Bool) -> CursorAppearancePayload? {
        let now = DispatchTime.now().uptimeNanoseconds
        if !forceRefresh,
           nextCursorAppearanceRefreshNanoseconds > now,
           let cachedCursorAppearance {
            return cachedCursorAppearance
        }

        let intervalNanoseconds = UInt64(
            1_000_000_000 / max(1, NetworkProtocol.cursorAppearanceRefreshFramesPerSecond)
        )
        nextCursorAppearanceRefreshNanoseconds = now + intervalNanoseconds

        guard let appearance = sampleCurrentCursorAppearance() else {
            return cachedCursorAppearance
        }

        cachedCursorAppearance = appearance
        return appearance
    }

    private func sampleCurrentCursorAppearance() -> CursorAppearancePayload? {
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let image = cursor.image
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let hotSpot = cursor.hotSpot
        return CursorAppearancePayload(
            signature: cursorAppearanceSignature(pngData: pngData, size: image.size, hotSpot: hotSpot),
            pngData: pngData,
            widthPoints: image.size.width,
            heightPoints: image.size.height,
            hotSpotX: hotSpot.x,
            hotSpotY: hotSpot.y
        )
    }

    private func cursorAppearanceSignature(pngData: Data, size: CGSize, hotSpot: CGPoint) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        mix(pngData)

        var widthPoints = Double(size.width).bitPattern.bigEndian
        withUnsafeBytes(of: &widthPoints) { mix($0) }

        var heightPoints = Double(size.height).bitPattern.bigEndian
        withUnsafeBytes(of: &heightPoints) { mix($0) }

        var hotSpotX = Double(hotSpot.x).bitPattern.bigEndian
        withUnsafeBytes(of: &hotSpotX) { mix($0) }

        var hotSpotY = Double(hotSpot.y).bitPattern.bigEndian
        withUnsafeBytes(of: &hotSpotY) { mix($0) }

        return hash
    }

    private func logCursorDebug(_ message: String) {
        guard NetworkProtocol.enableCursorDebugLogging else { return }
        print("[Sender][Cursor] \(message)")
    }

    private func updateCursorDebugStatus(_ message: String) {
        guard NetworkProtocol.enableCursorDebugLogging else { return }
        guard lastCursorDebugStatus != message else { return }
        lastCursorDebugStatus = message
        print("[Sender][Cursor] \(message)")
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
