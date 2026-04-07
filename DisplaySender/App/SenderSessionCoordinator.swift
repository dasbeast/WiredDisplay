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

    private struct CursorAppearanceDescriptor: Equatable {
        let objectIdentifier: ObjectIdentifier
        let widthPoints: CGFloat
        let heightPoints: CGFloat
        let hotSpotX: CGFloat
        let hotSpotY: CGFloat
    }

    private enum InputTelemetry {
        static let holdTimerIntervalMilliseconds = 50
        static let minimumHoldDurationNanoseconds: UInt64 = 500_000_000
        static let holdProgressLogIntervalNanoseconds: UInt64 = 1_000_000_000
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
    private let cursorDatagramTransportService: CursorDatagramTransportService
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
    private(set) var tcpVideoFramesSent: UInt64 = 0 { didSet { onChange?() } }
    private(set) var tcpVideoFramesDropped: UInt64 = 0 { didSet { onChange?() } }
    private(set) var tcpCursorFramesSent: UInt64 = 0 { didSet { onChange?() } }
    private(set) var cursorDatagramMotionPacketsSent: UInt64 = 0 { didSet { onChange?() } }
    private(set) var cursorDatagramQueuedPacketsSent: UInt64 = 0 { didSet { onChange?() } }
    private(set) var cursorDatagramQueuedPacketsDropped: UInt64 = 0 { didSet { onChange?() } }
    private(set) var cursorDatagramPendingPackets: Int = 0 { didSet { onChange?() } }
    private(set) var cursorDatagramSendErrors: UInt64 = 0 { didSet { onChange?() } }
    private(set) var streamingPipelinePreference: NetworkProtocol.StreamingPipelinePreference = .automatic { didSet { onChange?() } }
    private(set) var resolvedStreamingPipelineMode: NetworkProtocol.StreamingPipelineMode =
        NetworkProtocol.resolvedStreamingPipelineMode(for: .automatic) { didSet { onChange?() } }
    private(set) var useReceiverSideCursorOverlay = false { didSet { onChange?() } }
    private(set) var useDynamicCursorAppearanceMirroring = NetworkProtocol.enableDynamicCursorAppearanceMirroring { didSet { onChange?() } }
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

    private var desiredHosts: [String] = []
    private var currentDesiredHostIndex = 0
    private var desiredPort: UInt16 = NetworkProtocol.defaultPort
    private var shouldMaintainConnection = false
    private var currentHostCompletedHandshake = false

    private var heartbeatTimer: Timer?
    private var heartbeatTimeoutTimer: Timer?
    private var transportTelemetryTimer: Timer?
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
    private var inputHoldTelemetryTimer: DispatchSourceTimer?
    private var inputLoggingDisplayID: CGDirectDisplayID?
    private var activeMouseHoldStartNanoseconds: UInt64?
    private var lastObservedMouseButtonsMask: UInt64 = 0
    private var lastMouseHoldProgressLogNanoseconds: UInt64 = 0
    private var lastSentCursorState: CursorStatePayload?
    private var lastSentCursorAppearanceSignature: UInt64?
    private var prevSentCursorAppearanceSignature: UInt64?
    private var lastSentCursorAppearanceNanoseconds: UInt64 = 0
    private var cachedCursorAppearance: CursorAppearancePayload?
    private var cachedCursorAppearanceDescriptor: CursorAppearanceDescriptor?
    private var cachedArrowCursorAppearance: CursorAppearancePayload?
    private var frozenCursorAppearanceWhileButtonPressed: CursorAppearancePayload?
    private var nextCursorAppearanceRefreshNanoseconds: UInt64 = 0
    private var wasMouseButtonPressed = false
    private var lastCursorDebugStatus: String?
    private var lastCursorDebugLogNanoseconds: UInt64 = 0
    private var lastVisibleCursorNormalizedPosition: CGPoint?
    private var lastVisibleCursorTimestampNanoseconds: UInt64?
    private var lastCursorHandoffEdge: CursorHandoffEdge?
    private var pendingCursorPollWorkItem: DispatchWorkItem?
    private var pendingCursorPollDisplayID: CGDirectDisplayID?
    private var lastCursorPollTimestampNanoseconds: UInt64 = 0
    private var cursorPollRequestCount: UInt64 = 0
    private var cursorPollCoalescedCount: UInt64 = 0
    private var cursorPollExecutionCount: UInt64 = 0
    private var cursorPacketSentCount: UInt64 = 0
    private var cursorPacketSuppressedCount: UInt64 = 0
    private var lastCursorTelemetryLogNanoseconds: UInt64 = 0
    private var lastTransportTelemetryLogNanoseconds: UInt64 = 0

    init(
        captureService: CaptureService = CaptureService(),
        encoderService: EncoderService = EncoderService(),
        transportService: TransportService = TransportService(),
        videoDatagramTransportService: VideoDatagramTransportService = VideoDatagramTransportService(),
        cursorDatagramTransportService: CursorDatagramTransportService = CursorDatagramTransportService()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.transportService = transportService
        self.videoDatagramTransportService = videoDatagramTransportService
        self.cursorDatagramTransportService = cursorDatagramTransportService

        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()
        startTransportTelemetryTimer()

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
                if !encodedFrame.isKeyFrame && frameDispatchGate.awaitingFirstRenderedFrame {
                    Task { @MainActor [weak self] in
                        self?.requestRecoveryKeyFrameIfNeeded(
                            minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
                        )
                    }
                    return
                }

                if encodedFrame.isKeyFrame {
                    self.videoDatagramTransportService.noteKeyFrameBoundary()
                }
                self.videoDatagramTransportService.sendVideoFrame(encodedFrame)
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
                    self.stopInputEventLogging()

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

        cursorDatagramTransportService.onError = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.logCursorDebug("cursor UDP transport error: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        transportTelemetryTimer?.invalidate()
        wiredPathMonitor.stop()
    }

    /// Connects to receiver and performs handshake only.
    /// `targetWidth` / `targetHeight` are retained as a fallback when the receiver cannot report display metrics.
    func connect(
        receiverHost: String,
        alternateReceiverHosts: [String] = [],
        port: UInt16 = NetworkProtocol.defaultPort,
        videoTransportMode: NetworkProtocol.VideoTransportMode = .tcp,
        targetWidth: Int = 2560,
        targetHeight: Int = 1440
    ) {
        _ = videoTransportMode
        desiredHosts = orderedUniqueHosts(
            primaryHost: receiverHost,
            alternateHosts: alternateReceiverHosts
        )
        currentDesiredHostIndex = 0
        desiredPort = port
        shouldMaintainConnection = true
        currentHostCompletedHandshake = false

        self.receiverHost = desiredHosts.first ?? receiverHost
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        let resolvedVideoTransportMode: NetworkProtocol.VideoTransportMode = .tcp
        requestedVideoTransportMode = resolvedVideoTransportMode
        negotiatedVideoTransportMode = resolvedVideoTransportMode
        frameDispatchGate.setNegotiatedMode(resolvedVideoTransportMode)
        encoderService.setPreferredKeyFrameIntervalFrames(
            NetworkProtocol.keyFrameIntervalFrames(for: resolvedVideoTransportMode)
        )
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
        refreshTransportTelemetry()
        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        state = .connecting
        stopCursorTracking(sendHiddenState: false)
        stopInputEventLogging()
        captureService.stopCapture()
        // Wait until the receiver explicitly negotiates UDP before opening the datagram path.
        // Pre-connecting here can fail before the handshake finishes and strand the sender
        // in a connected-but-never-starting state.
        videoDatagramTransportService.disconnect()
        cursorDatagramTransportService.disconnect()
        beginConnectionAttempt()
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
        print(
            "[Sender] Cursor mode: " +
            "\(useReceiverSideCursorOverlay ? "side-overlay" : "native-captured"), " +
            "shapes=\(useDynamicCursorAppearanceMirroring ? "mirrored" : "arrow-only")"
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
        startInputEventLogging(for: virtualDisplayID)
        if useReceiverSideCursorOverlay {
            startCursorTracking(for: virtualDisplayID)
        } else {
            stopCursorTracking(sendHiddenState: true)
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
                    showsCursor: self.shouldShowSenderCursorInCapture
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
                showsCursor: self.shouldShowSenderCursorInCapture
            )
        }
    }

    /// Stops sender session and resets services to idle placeholders.
    func stopSession() {
        shouldMaintainConnection = false
        desiredHosts = []
        currentDesiredHostIndex = 0
        currentHostCompletedHandshake = false
        stopHeartbeatTimers()
        stopCursorTracking(sendHiddenState: true)
        stopInputEventLogging()
        captureService.stopCapture()
        virtualDisplayService.destroyDisplay()
        videoDatagramTransportService.disconnect()
        cursorDatagramTransportService.disconnect()
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
        refreshTransportTelemetry()
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
            if !encodedFrame.isKeyFrame && awaitingFirstRenderedFrame {
                requestRecoveryKeyFrameIfNeeded(
                    minimumIntervalSeconds: NetworkProtocol.udpStartupRecoveryIntervalSeconds
                )
                return
            }
            if encodedFrame.isKeyFrame {
                videoDatagramTransportService.noteKeyFrameBoundary()
            }
            videoDatagramTransportService.sendVideoFrame(encodedFrame)
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
                    currentHostCompletedHandshake = true
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
        stopInputEventLogging()
        captureService.stopCapture()
        virtualDisplayService.destroyDisplay()
        videoDatagramTransportService.disconnect()
        cursorDatagramTransportService.disconnect()
        transportService.disconnect()

        let shouldRotateHost = !currentHostCompletedHandshake
        currentHostCompletedHandshake = false
        if shouldRotateHost {
            rotateToAlternateHost(after: reason)
        }

        guard shouldMaintainConnection, currentDesiredHost != nil else { return }

        Timer.scheduledTimer(withTimeInterval: NetworkProtocol.reconnectDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldMaintainConnection else { return }
                self.beginConnectionAttempt()
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
        let resolvedVideoTransportMode: NetworkProtocol.VideoTransportMode = .tcp
        _ = videoTransportMode
        negotiatedVideoTransportMode = resolvedVideoTransportMode
        frameDispatchGate.setNegotiatedMode(resolvedVideoTransportMode)
        encoderService.setPreferredKeyFrameIntervalFrames(
            NetworkProtocol.keyFrameIntervalFrames(for: resolvedVideoTransportMode)
        )
        awaitingUDPReadyToStart = false
        awaitingFirstRenderedFrame = false
        videoDatagramTransportService.disconnect()
    }

    private var currentDesiredHost: String? {
        guard desiredHosts.indices.contains(currentDesiredHostIndex) else { return nil }
        return desiredHosts[currentDesiredHostIndex]
    }

    private func orderedUniqueHosts(primaryHost: String, alternateHosts: [String]) -> [String] {
        var seenHosts = Set<String>()
        return ([primaryHost] + alternateHosts).compactMap { host in
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else { return nil }
            guard seenHosts.insert(trimmedHost).inserted else { return nil }
            return trimmedHost
        }
    }

    private func beginConnectionAttempt() {
        guard let host = currentDesiredHost else { return }
        receiverHost = host
        configuredEndpointSummary = "\(host):\(desiredPort) [\(requestedVideoTransportMode.rawValue.uppercased())]"
        transportService.connect(host: host, port: desiredPort)
    }

    private func rotateToAlternateHost(after reason: String) {
        guard desiredHosts.count > 1 else { return }
        currentDesiredHostIndex = (currentDesiredHostIndex + 1) % desiredHosts.count
        guard let host = currentDesiredHost else { return }
        print("[Sender] Retrying via alternate receiver path \(host):\(desiredPort) after \(reason)")
    }

    func setStreamingPipelinePreference(_ preference: NetworkProtocol.StreamingPipelinePreference) {
        guard preference != streamingPipelinePreference else { return }
        streamingPipelinePreference = preference
        resolvedStreamingPipelineMode = NetworkProtocol.resolvedStreamingPipelineMode(for: preference)
    }

    func setUseReceiverSideCursorOverlay(_ enabled: Bool) {
        guard enabled != useReceiverSideCursorOverlay else { return }
        useReceiverSideCursorOverlay = enabled
        applyCursorOverlayModeIfRunning()
    }

    func setUseDynamicCursorAppearanceMirroring(_ enabled: Bool) {
        guard enabled != useDynamicCursorAppearanceMirroring else { return }
        useDynamicCursorAppearanceMirroring = enabled
        resetCursorAppearanceCaches()

        guard state == .running, useReceiverSideCursorOverlay else { return }
        let displayID = virtualDisplayService.displayID
        guard displayID != 0 else { return }
        pollCursorState(for: displayID)
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

    private var shouldShowSenderCursorInCapture: Bool {
        NetworkProtocol.showSenderCursorFallbackWhileTestingOverlay || !useReceiverSideCursorOverlay
    }

    private func applyCursorOverlayModeIfRunning() {
        guard state == .running else { return }
        guard virtualDisplayService.isActive else { return }

        let displayID = virtualDisplayService.displayID
        if useReceiverSideCursorOverlay {
            startCursorTracking(for: displayID)
        } else {
            stopCursorTracking(sendHiddenState: true)
        }

        captureService.stopCapture()

        let liveMode = activeDisplayMode ?? virtualDisplayService.activeMode()
        let captureWidth = liveMode?.pixelWidth ?? effectiveCaptureWidth()
        let captureHeight = liveMode?.pixelHeight ?? effectiveCaptureHeight()
        print("[Sender] Restarting capture for cursor mode change: \(useReceiverSideCursorOverlay ? "side-overlay" : "native-captured")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, case .running = self.state else { return }
            self.captureService.startCapture(
                width: captureWidth,
                height: captureHeight,
                framesPerSecond: NetworkProtocol.captureFramesPerSecond,
                streamingPipelineMode: self.resolvedStreamingPipelineMode,
                showsCursor: self.shouldShowSenderCursorInCapture
            )
        }
    }

    private func startCursorTracking(for displayID: CGDirectDisplayID) {
        stopCursorTracking(sendHiddenState: false)
        guard displayID != 0 else { return }

        if let host = currentDesiredHost ?? (receiverHost.isEmpty ? nil : receiverHost) {
            cursorDatagramTransportService.connect(host: host, port: desiredPort)
        }

        lastSentCursorState = nil
        lastSentCursorAppearanceSignature = nil
        prevSentCursorAppearanceSignature = nil
        lastSentCursorAppearanceNanoseconds = 0
        resetCursorAppearanceCaches()
        wasMouseButtonPressed = false
        lastCursorDebugStatus = nil
        lastCursorDebugLogNanoseconds = 0
        lastVisibleCursorNormalizedPosition = nil
        lastVisibleCursorTimestampNanoseconds = nil
        lastCursorHandoffEdge = nil
        pendingCursorPollWorkItem = nil
        pendingCursorPollDisplayID = nil
        lastCursorPollTimestampNanoseconds = 0
        cursorPollRequestCount = 0
        cursorPollCoalescedCount = 0
        cursorPollExecutionCount = 0
        cursorPacketSentCount = 0
        cursorPacketSuppressedCount = 0
        lastCursorTelemetryLogNanoseconds = 0
        logCursorDebug("tracking started for display \(displayID)")
        if !useDynamicCursorAppearanceMirroring {
            logCursorDebug("dynamic cursor appearance mirroring disabled; sender will use arrow cursor")
        }
        installCursorEventMonitors(for: displayID)
        startCursorRefreshTimer(for: displayID)
        pollCursorState(for: displayID)
    }

    private func stopCursorTracking(sendHiddenState: Bool) {
        pendingCursorPollWorkItem?.cancel()
        pendingCursorPollWorkItem = nil
        pendingCursorPollDisplayID = nil
        cursorTrackingRefreshTimer?.setEventHandler {}
        cursorTrackingRefreshTimer?.cancel()
        cursorTrackingRefreshTimer = nil
        removeCursorEventMonitors()

        if sendHiddenState,
           state == .running || state == .connected {
            let hiddenState = CursorStatePayload(
                timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                normalizedX: 0,
                normalizedY: 0,
                isVisible: false,
                ownershipIntent: .hidden,
                appearance: nil
            )
            logCursorDebug("sending hidden cursor state while stopping tracking")
            if NetworkProtocol.useReceiverCursorDatagramTransport {
                cursorDatagramTransportService.sendCursorState(hiddenState)
            }
            transportService.sendCursorState(hiddenState)
        }

        cursorDatagramTransportService.disconnect()

        lastSentCursorState = nil
        lastSentCursorAppearanceSignature = nil
        prevSentCursorAppearanceSignature = nil
        lastSentCursorAppearanceNanoseconds = 0
        resetCursorAppearanceCaches()
        wasMouseButtonPressed = false
        lastCursorDebugLogNanoseconds = 0
        lastVisibleCursorNormalizedPosition = nil
        lastVisibleCursorTimestampNanoseconds = nil
        lastCursorHandoffEdge = nil
        lastCursorPollTimestampNanoseconds = 0
        cursorPollRequestCount = 0
        cursorPollCoalescedCount = 0
        cursorPollExecutionCount = 0
        cursorPacketSentCount = 0
        cursorPacketSuppressedCount = 0
        lastCursorTelemetryLogNanoseconds = 0
    }

    private func startInputEventLogging(for displayID: CGDirectDisplayID) {
        stopInputEventLogging()
        guard displayID != 0 else { return }

        inputLoggingDisplayID = displayID
        activeMouseHoldStartNanoseconds = nil
        lastObservedMouseButtonsMask = currentPressedMouseButtonsMask()
        lastMouseHoldProgressLogNanoseconds = 0

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(InputTelemetry.holdTimerIntervalMilliseconds),
            repeating: .milliseconds(InputTelemetry.holdTimerIntervalMilliseconds),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pollInputLogging(for: displayID)
            }
        }
        timer.activate()
        inputHoldTelemetryTimer = timer

        logInputDebug("input logging started for display \(displayID)")
    }

    private func stopInputEventLogging() {
        emitMouseHoldProgressIfNeeded(force: true)

        inputHoldTelemetryTimer?.setEventHandler {}
        inputHoldTelemetryTimer?.cancel()
        inputHoldTelemetryTimer = nil

        inputLoggingDisplayID = nil
        activeMouseHoldStartNanoseconds = nil
        lastObservedMouseButtonsMask = 0
        lastMouseHoldProgressLogNanoseconds = 0
    }

    private func pollInputLogging(for displayID: CGDirectDisplayID) {
        let now = DispatchTime.now().uptimeNanoseconds
        let buttonsMask = currentPressedMouseButtonsMask()
        let mouseLocation = NSEvent.mouseLocation
        let previousButtonsMask = lastObservedMouseButtonsMask

        if previousButtonsMask == 0 && buttonsMask != 0 {
            activeMouseHoldStartNanoseconds = now
            lastMouseHoldProgressLogNanoseconds = 0
            logInputDebug(
                "\(inputTransitionName(for: buttonsMask, isPressed: true)) " +
                "\(inputLocationContext(mouseLocation, displayID: displayID)) buttons=\(buttonsMask)"
            )
        } else if previousButtonsMask != 0 && buttonsMask == 0 {
            let durationMilliseconds = activeMouseHoldDurationMilliseconds(at: now)
            logInputDebug(
                "\(inputTransitionName(for: previousButtonsMask, isPressed: false)) after \(durationMilliseconds) ms " +
                "\(inputLocationContext(mouseLocation, displayID: displayID)) buttons=\(buttonsMask)"
            )
            activeMouseHoldStartNanoseconds = nil
            lastMouseHoldProgressLogNanoseconds = 0
        } else if previousButtonsMask != 0 && buttonsMask != 0 && previousButtonsMask != buttonsMask {
            if activeMouseHoldStartNanoseconds == nil {
                activeMouseHoldStartNanoseconds = now
            }
            logInputDebug(
                "buttons-changed \(previousButtonsMask)->\(buttonsMask) " +
                "\(inputLocationContext(mouseLocation, displayID: displayID))"
            )
        }

        lastObservedMouseButtonsMask = buttonsMask
        emitMouseHoldProgressIfNeeded(force: false)
    }

    private func emitMouseHoldProgressIfNeeded(force: Bool) {
        guard let displayID = inputLoggingDisplayID else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let buttonsMask = currentPressedMouseButtonsMask()

        guard buttonsMask != 0 else {
            if force,
               let activeMouseHoldStartNanoseconds {
                logInputDebug(
                    "hold logging stopped after \(millisecondsSince(activeMouseHoldStartNanoseconds, now: now)) ms " +
                    "\(inputLocationContext(NSEvent.mouseLocation, displayID: displayID))"
                )
            }
            activeMouseHoldStartNanoseconds = nil
            lastMouseHoldProgressLogNanoseconds = 0
            return
        }

        if activeMouseHoldStartNanoseconds == nil {
            activeMouseHoldStartNanoseconds = now
            lastMouseHoldProgressLogNanoseconds = 0
            logInputDebug(
                "buttons-down without explicit mouse-down \(inputLocationContext(NSEvent.mouseLocation, displayID: displayID)) " +
                "buttons=\(buttonsMask)"
            )
        }

        guard let activeMouseHoldStartNanoseconds else { return }
        guard force || now >= (activeMouseHoldStartNanoseconds + InputTelemetry.minimumHoldDurationNanoseconds) else {
            return
        }
        guard force ||
            lastMouseHoldProgressLogNanoseconds == 0 ||
            now >= (lastMouseHoldProgressLogNanoseconds + InputTelemetry.holdProgressLogIntervalNanoseconds) else {
            return
        }

        lastMouseHoldProgressLogNanoseconds = now
        logInputDebug(
            "hold active \(millisecondsSince(activeMouseHoldStartNanoseconds, now: now)) ms " +
            "\(inputLocationContext(NSEvent.mouseLocation, displayID: displayID)) buttons=\(buttonsMask)"
        )
    }

    private func installCursorEventMonitors(for displayID: CGDirectDisplayID) {
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .rightMouseDragged,
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged
        ]

        localCursorEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.scheduleCursorPoll(for: displayID)
            }
            return event
        }

        globalCursorEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleCursorPoll(for: displayID)
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
        let refreshFramesPerSecond = max(1, cursorRefreshFramesPerSecond())
        let intervalNanoseconds = Int(1_000_000_000 / refreshFramesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .nanoseconds(intervalNanoseconds),
            repeating: .nanoseconds(intervalNanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleCursorPoll(for: displayID)
            }
        }
        timer.activate()
        cursorTrackingRefreshTimer = timer
    }

    private func cursorRefreshFramesPerSecond() -> Int {
        if useDynamicCursorAppearanceMirroring {
            return max(
                NetworkProtocol.cursorOverlayFramesPerSecond,
                NetworkProtocol.cursorAppearanceRefreshFramesPerSecond
            )
        }

        return NetworkProtocol.cursorOverlayFramesPerSecond
    }

    private func scheduleCursorPoll(for displayID: CGDirectDisplayID) {
        guard useReceiverSideCursorOverlay else { return }
        cursorPollRequestCount += 1

        if pendingCursorPollDisplayID == displayID {
            cursorPollCoalescedCount += 1
            emitCursorTelemetryIfNeeded(for: displayID)
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let minimumIntervalNanoseconds = minimumCursorPollIntervalNanoseconds()
        let delayNanoseconds: UInt64
        if lastCursorPollTimestampNanoseconds == 0 || now >= (lastCursorPollTimestampNanoseconds + minimumIntervalNanoseconds) {
            delayNanoseconds = 0
        } else {
            delayNanoseconds = (lastCursorPollTimestampNanoseconds + minimumIntervalNanoseconds) - now
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingCursorPollDisplayID = nil
                self.pendingCursorPollWorkItem = nil
                self.lastCursorPollTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
                self.cursorPollExecutionCount += 1
                self.pollCursorState(for: displayID)
                self.emitCursorTelemetryIfNeeded(for: displayID)
            }
        }

        pendingCursorPollDisplayID = displayID
        pendingCursorPollWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(delayNanoseconds)),
            execute: workItem
        )
    }

    private func minimumCursorPollIntervalNanoseconds() -> UInt64 {
        let targetFramesPerSecond: Int
        if isMouseButtonPressed() {
            targetFramesPerSecond = min(
                NetworkProtocol.cursorOverlayFramesPerSecond,
                NetworkProtocol.captureFramesPerSecond
            )
        } else {
            targetFramesPerSecond = NetworkProtocol.cursorOverlayFramesPerSecond
        }

        return UInt64(1_000_000_000 / max(1, targetFramesPerSecond))
    }

    private func pollCursorState(for displayID: CGDirectDisplayID) {
        guard useReceiverSideCursorOverlay else { return }
        guard state == .running else { return }
        guard virtualDisplayService.displayID == displayID else { return }

        let nextState = currentCursorState(for: displayID)
        let motionState = CursorStatePayload(
            timestampNanoseconds: nextState.timestampNanoseconds,
            normalizedX: nextState.normalizedX,
            normalizedY: nextState.normalizedY,
            isVisible: nextState.isVisible,
            ownershipIntent: nextState.ownershipIntent,
            appearance: nil
        )

        let shouldSendMotion = shouldSendCursorState(motionState)
        let shouldSendAppearance = nextState.appearance != nil && shouldSendCursorState(nextState)

        guard shouldSendMotion || shouldSendAppearance else {
            cursorPacketSuppressedCount += 1
            emitCursorTelemetryIfNeeded(for: displayID)
            return
        }

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

        if shouldSendMotion {
            if NetworkProtocol.useReceiverCursorDatagramTransport, cursorDatagramTransportService.isConnected {
                cursorDatagramTransportService.sendCursorState(motionState)
            } else {
                transportService.sendCursorState(nextState)
            }
            lastSentCursorState = motionState
            cursorPacketSentCount += 1
        }

        if let appearance = nextState.appearance, shouldSendAppearance {
            logCursorDebug(
                "sending cursor appearance signature \(appearance.signature) " +
                "size=\(Int(appearance.widthPoints))x\(Int(appearance.heightPoints))"
            )
            transportService.sendCursorState(nextState)
            lastSentCursorState = nextState
            prevSentCursorAppearanceSignature = lastSentCursorAppearanceSignature
            lastSentCursorAppearanceSignature = appearance.signature
            lastSentCursorAppearanceNanoseconds = DispatchTime.now().uptimeNanoseconds
            cursorPacketSentCount += 1
        }
        emitCursorTelemetryIfNeeded(for: displayID)
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
        let buttonsPressed = isMouseButtonPressed()
        let recentEdgeHandoffCandidate = wasRecentEdgeHandoffCandidate(at: now)
        if buttonsPressed,
           recentEdgeHandoffCandidate,
           cursorHandoffEdgeJustOutside(mouseLocation, in: frame) != nil {
            let normalizedPosition = clampedNormalizedCursorPosition(for: mouseLocation, in: frame)
            lastVisibleCursorNormalizedPosition = normalizedPosition
            lastVisibleCursorTimestampNanoseconds = now
            lastCursorHandoffEdge = nil
            updateCursorDebugStatus(
                String(
                    format: "cursor drag-clamped on display %u mouse=(%.1f, %.1f) normalized=(%.4f, %.4f)",
                    displayID,
                    mouseLocation.x,
                    mouseLocation.y,
                    normalizedPosition.x,
                    normalizedPosition.y
                )
            )
            return remoteCursorState(
                at: now,
                normalizedPosition: normalizedPosition
            )
        }

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
        return remoteCursorState(
            at: now,
            normalizedPosition: normalizedPosition
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
        if isMouseButtonPressed() {
            return .remote
        }

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

    private func remoteCursorState(
        at nowNanoseconds: UInt64,
        normalizedPosition: CGPoint
    ) -> CursorStatePayload {
        let appearance = currentCursorAppearance(forceRefresh: lastSentCursorState == nil)
        let appearanceToSend: CursorAppearancePayload?
        if let appearance,
           lastSentCursorState == nil || appearance.signature != lastSentCursorAppearanceSignature {
            // Hysteresis: if the new signature matches the *previously* sent signature, the cursor
            // is oscillating between two shapes (e.g. pointer ↔ I-beam at a UI element boundary).
            // Suppress the re-send until the new shape has been stable for 200 ms, so we don't
            // flood the control channel with rapid appearance toggles.
            let isOscillating = appearance.signature == prevSentCursorAppearanceSignature
            let oscillationCooldownNanoseconds: UInt64 = 200_000_000
            if isOscillating, lastSentCursorAppearanceNanoseconds > 0,
               nowNanoseconds < lastSentCursorAppearanceNanoseconds + oscillationCooldownNanoseconds {
                appearanceToSend = nil
            } else {
                appearanceToSend = appearance
            }
        } else {
            appearanceToSend = nil
        }

        return CursorStatePayload(
            timestampNanoseconds: nowNanoseconds,
            normalizedX: Double(normalizedPosition.x),
            normalizedY: Double(normalizedPosition.y),
            isVisible: true,
            ownershipIntent: .remote,
            appearance: appearanceToSend
        )
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

    private func clampedNormalizedCursorPosition(
        for mouseLocation: CGPoint,
        in frame: CGRect
    ) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }

        let clampedX = min(max(mouseLocation.x, frame.minX), frame.maxX)
        let clampedY = min(max(mouseLocation.y, frame.minY), frame.maxY)
        let normalizedX = max(0, min(1, (clampedX - frame.minX) / frame.width))
        let normalizedY = max(0, min(1, (frame.maxY - clampedY) / frame.height))
        return CGPoint(x: normalizedX, y: normalizedY)
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

    private func isMouseButtonPressed() -> Bool {
        NSEvent.pressedMouseButtons != 0
    }

    private func currentCursorAppearance(forceRefresh: Bool) -> CursorAppearancePayload? {
        guard useDynamicCursorAppearanceMirroring else {
            return defaultArrowCursorAppearance()
        }

        let now = DispatchTime.now().uptimeNanoseconds

        let mouseButtonPressed = isMouseButtonPressed()
        if mouseButtonPressed {
            if !wasMouseButtonPressed {
                wasMouseButtonPressed = true
                frozenCursorAppearanceWhileButtonPressed =
                    refreshedCursorAppearance(at: now, forceRefresh: true) ?? cachedCursorAppearance
            }

            if let frozenCursorAppearanceWhileButtonPressed {
                return frozenCursorAppearanceWhileButtonPressed
            }

            return cachedCursorAppearance ?? refreshedCursorAppearance(at: now, forceRefresh: forceRefresh)
        }

        if wasMouseButtonPressed {
            wasMouseButtonPressed = false
            frozenCursorAppearanceWhileButtonPressed = nil
            nextCursorAppearanceRefreshNanoseconds = 0
        }

        return refreshedCursorAppearance(at: now, forceRefresh: forceRefresh)
    }

    private func refreshedCursorAppearance(
        at nowNanoseconds: UInt64,
        forceRefresh: Bool
    ) -> CursorAppearancePayload? {
        if !forceRefresh,
           nextCursorAppearanceRefreshNanoseconds > nowNanoseconds,
           let cachedCursorAppearance {
            return cachedCursorAppearance
        }

        let intervalNanoseconds = UInt64(
            1_000_000_000 / max(1, NetworkProtocol.cursorAppearanceRefreshFramesPerSecond)
        )
        nextCursorAppearanceRefreshNanoseconds = nowNanoseconds + intervalNanoseconds

        let snapshot = currentCursorAppearanceSnapshot()

        if let cachedCursorAppearance,
           snapshot?.descriptor == cachedCursorAppearanceDescriptor {
            return cachedCursorAppearance
        }

        guard let snapshot,
              let appearance = sampleCurrentCursorAppearance(from: snapshot.cursor) else {
            return cachedCursorAppearance
        }

        cachedCursorAppearance = appearance
        cachedCursorAppearanceDescriptor = snapshot.descriptor
        return appearance
    }

    private func currentCursorAppearanceSnapshot() -> (cursor: NSCursor, descriptor: CursorAppearanceDescriptor)? {
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let image = cursor.image
        let hotSpot = cursor.hotSpot
        return (
            cursor: cursor,
            descriptor: CursorAppearanceDescriptor(
                objectIdentifier: ObjectIdentifier(cursor),
                widthPoints: image.size.width,
                heightPoints: image.size.height,
                hotSpotX: hotSpot.x,
                hotSpotY: hotSpot.y
            )
        )
    }

    private func sampleCurrentCursorAppearance(from cursor: NSCursor) -> CursorAppearancePayload? {
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

    private func defaultArrowCursorAppearance() -> CursorAppearancePayload? {
        if let cachedArrowCursorAppearance {
            return cachedArrowCursorAppearance
        }

        guard let appearance = sampleCurrentCursorAppearance(from: .arrow) else {
            return nil
        }

        cachedArrowCursorAppearance = appearance
        return appearance
    }

    private func resetCursorAppearanceCaches() {
        cachedCursorAppearance = nil
        cachedCursorAppearanceDescriptor = nil
        frozenCursorAppearanceWhileButtonPressed = nil
        nextCursorAppearanceRefreshNanoseconds = 0
        lastSentCursorAppearanceSignature = nil
        prevSentCursorAppearanceSignature = nil
        lastSentCursorAppearanceNanoseconds = 0
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

    private func logInputDebug(_ message: String) {
        guard NetworkProtocol.enableCursorDebugLogging else { return }
        print("[Sender][Input] \(message)")
    }

    private func currentPressedMouseButtonsMask() -> UInt64 {
        UInt64(truncatingIfNeeded: NSEvent.pressedMouseButtons)
    }

    private func inputTransitionName(for buttonsMask: UInt64, isPressed: Bool) -> String {
        let suffix = isPressed ? "down" : "up"
        switch buttonsMask {
        case 1 << 0:
            return "left-\(suffix)"
        case 1 << 1:
            return "right-\(suffix)"
        case 1 << 2:
            return "other-\(suffix)"
        default:
            return "buttons-\(suffix)"
        }
    }

    private func inputLocationContext(_ mouseLocation: CGPoint, displayID: CGDirectDisplayID) -> String {
        guard let frame = screenFrame(for: displayID) else {
            return String(
                format: "mouse=(%.1f, %.1f) display=%u screen=unavailable",
                mouseLocation.x,
                mouseLocation.y,
                displayID
            )
        }

        let containment = frame.contains(mouseLocation) ? "inside" : "outside"
        return String(
            format: "mouse=(%.1f, %.1f) display=%u %@",
            mouseLocation.x,
            mouseLocation.y,
            displayID,
            containment
        )
    }

    private func screenFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == displayID
        }) else {
            return nil
        }

        return screen.frame
    }

    private func activeMouseHoldDurationMilliseconds(at nowNanoseconds: UInt64) -> Int {
        guard let activeMouseHoldStartNanoseconds else { return 0 }
        return millisecondsSince(activeMouseHoldStartNanoseconds, now: nowNanoseconds)
    }

    private func millisecondsSince(_ startNanoseconds: UInt64, now nowNanoseconds: UInt64) -> Int {
        guard nowNanoseconds >= startNanoseconds else { return 0 }
        return Int((nowNanoseconds - startNanoseconds) / 1_000_000)
    }

    private func updateCursorDebugStatus(_ message: String) {
        guard NetworkProtocol.enableCursorDebugLogging else { return }
        guard lastCursorDebugStatus != message else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastCursorDebugLogNanoseconds != 0,
           now < (lastCursorDebugLogNanoseconds + 1_000_000_000) {
            lastCursorDebugStatus = message
            return
        }
        lastCursorDebugStatus = message
        lastCursorDebugLogNanoseconds = now
        print("[Sender][Cursor] \(message)")
    }

    private func emitCursorTelemetryIfNeeded(for displayID: CGDirectDisplayID) {
        guard NetworkProtocol.enableCursorDebugLogging || NetworkProtocol.enableTransportDebugLogging else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        if lastCursorTelemetryLogNanoseconds == 0 {
            lastCursorTelemetryLogNanoseconds = now
            return
        }

        guard now >= (lastCursorTelemetryLogNanoseconds + 1_000_000_000) else { return }

        refreshTransportTelemetry()
        print(
            "[Sender][Cursor] telemetry display \(displayID): " +
            "requests=\(cursorPollRequestCount) " +
            "executed=\(cursorPollExecutionCount) " +
            "coalesced=\(cursorPollCoalescedCount) " +
            "sent=\(cursorPacketSentCount) " +
            "suppressed=\(cursorPacketSuppressedCount) " +
            "tcpVideoSent=\(tcpVideoFramesSent) " +
            "tcpVideoDropped=\(tcpVideoFramesDropped) " +
            "tcpCursorSent=\(tcpCursorFramesSent) " +
            "udpCursorMotion=\(cursorDatagramMotionPacketsSent) " +
            "udpCursorQueued=\(cursorDatagramQueuedPacketsSent) " +
            "udpCursorDropped=\(cursorDatagramQueuedPacketsDropped) " +
            "udpCursorPending=\(cursorDatagramPendingPackets) " +
            "udpCursorErrors=\(cursorDatagramSendErrors)"
        )

        lastCursorTelemetryLogNanoseconds = now
        cursorPollRequestCount = 0
        cursorPollCoalescedCount = 0
        cursorPollExecutionCount = 0
        cursorPacketSentCount = 0
        cursorPacketSuppressedCount = 0
    }

    private func startTransportTelemetryTimer() {
        transportTelemetryTimer?.invalidate()
        transportTelemetryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTransportTelemetry()
            }
        }
    }

    private func refreshTransportTelemetry() {
        let tcpSnapshot = transportService.debugSnapshot()
        let cursorSnapshot = cursorDatagramTransportService.debugSnapshot()

        if tcpVideoFramesSent != tcpSnapshot.sentVideoFrames {
            tcpVideoFramesSent = tcpSnapshot.sentVideoFrames
        }
        if tcpVideoFramesDropped != tcpSnapshot.droppedVideoFrames {
            tcpVideoFramesDropped = tcpSnapshot.droppedVideoFrames
        }
        if tcpCursorFramesSent != tcpSnapshot.sentCursorFrames {
            tcpCursorFramesSent = tcpSnapshot.sentCursorFrames
        }
        if cursorDatagramMotionPacketsSent != cursorSnapshot.sentMotionPackets {
            cursorDatagramMotionPacketsSent = cursorSnapshot.sentMotionPackets
        }
        if cursorDatagramQueuedPacketsSent != cursorSnapshot.sentQueuedPackets {
            cursorDatagramQueuedPacketsSent = cursorSnapshot.sentQueuedPackets
        }
        if cursorDatagramQueuedPacketsDropped != cursorSnapshot.droppedQueuedPackets {
            cursorDatagramQueuedPacketsDropped = cursorSnapshot.droppedQueuedPackets
        }
        if cursorDatagramPendingPackets != cursorSnapshot.pendingPackets {
            cursorDatagramPendingPackets = cursorSnapshot.pendingPackets
        }
        if cursorDatagramSendErrors != cursorSnapshot.sendErrors {
            cursorDatagramSendErrors = cursorSnapshot.sendErrors
        }

        guard NetworkProtocol.enableTransportDebugLogging else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        if lastTransportTelemetryLogNanoseconds != 0,
           now < (lastTransportTelemetryLogNanoseconds + NetworkProtocol.transportTelemetryLogIntervalNanoseconds) {
            return
        }

        print(
            "[Sender][Transport] tcp: sent(video=\(tcpSnapshot.sentVideoFrames), control=\(tcpSnapshot.sentControlFrames), " +
            "cursor=\(tcpSnapshot.sentCursorFrames), audio=\(tcpSnapshot.sentAudioFrames)) " +
            "pending=\(tcpSnapshot.pendingFrames) " +
            "inFlight=\(tcpSnapshot.networkInFlightCount) " +
            "dropped(video=\(tcpSnapshot.droppedVideoFrames), cursor=\(tcpSnapshot.droppedCursorFrames)) | " +
            "cursor-udp: motion=\(cursorSnapshot.sentMotionPackets) queued=\(cursorSnapshot.sentQueuedPackets) " +
            "pending=\(cursorSnapshot.pendingPackets) inFlight=\(cursorSnapshot.networkInFlightCount) " +
            "dropped=\(cursorSnapshot.droppedQueuedPackets) errors=\(cursorSnapshot.sendErrors)"
        )

        lastTransportTelemetryLogNanoseconds = now
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
