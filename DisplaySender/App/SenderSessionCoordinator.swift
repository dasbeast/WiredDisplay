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
    private let wiredPathMonitor = WiredPathStatusMonitor()

    private(set) var state: SessionState = .idle { didSet { onChange?() } }
    private(set) var receiverHost: String = "" { didSet { onChange?() } }
    private(set) var targetWidth: Int = 2560 { didSet { onChange?() } }
    private(set) var targetHeight: Int = 1440 { didSet { onChange?() } }
    private(set) var sentFrameCount: UInt64 = 0 { didSet { onChange?() } }
    private(set) var droppedOutboundFrameCount: UInt64 = 0 { didSet { onChange?() } }
    private(set) var lastErrorMessage: String? { didSet { onChange?() } }
    private(set) var sentFramesPerSecond: Double? { didSet { onChange?() } }
    private(set) var sentMegabitsPerSecond: Double? { didSet { onChange?() } }

    private(set) var configuredEndpointSummary: String = "-" { didSet { onChange?() } }
    private(set) var wiredPathAvailable = false { didSet { onChange?() } }
    private(set) var localInterfaceDescriptions: [String] = [] { didSet { onChange?() } }
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
    private var outboundWindowStartNanoseconds: UInt64?
    private var outboundWindowFrameCount: UInt64 = 0
    private var outboundWindowPayloadBytes: UInt64 = 0
    private var isFrameEncodeInFlight = false

    init(
        captureService: CaptureService = CaptureService(),
        encoderService: EncoderService = EncoderService(),
        transportService: TransportService = TransportService()
    ) {
        self.captureService = captureService
        self.encoderService = encoderService
        self.transportService = transportService

        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        captureService.onCapturedFrame = { [weak self] frame in
            guard let self else { return }
            Task { @MainActor in
                self.handleCapturedFrame(frame)
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
                self.droppedOutboundFrameCount = count
            }
        }
    }

    deinit {
        wiredPathMonitor.stop()
    }

    /// Connects to receiver and performs handshake only.
    func connect(
        receiverHost: String,
        port: UInt16 = NetworkProtocol.defaultPort,
        targetWidth: Int = 2560,
        targetHeight: Int = 1440
    ) {
        desiredHost = receiverHost
        desiredPort = port
        shouldMaintainConnection = true

        self.receiverHost = receiverHost
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        sentFrameCount = 0
        droppedOutboundFrameCount = 0
        lastErrorMessage = nil
        sentFramesPerSecond = nil
        sentMegabitsPerSecond = nil
        outboundWindowStartNanoseconds = nil
        outboundWindowFrameCount = 0
        outboundWindowPayloadBytes = 0
        isFrameEncodeInFlight = false
        configuredEndpointSummary = "\(receiverHost):\(port)"
        localInterfaceDescriptions = NetworkDiagnostics.localIPv4Descriptions()

        state = .connecting
        captureService.stopCapture()
        transportService.connect(host: receiverHost, port: port)
    }

    /// Starts capture and frame transport after handshake succeeds.
    func startSession() {
        guard canStartSession else { return }
        state = .running
        let captureWidth = effectiveCaptureWidth()
        let captureHeight = effectiveCaptureHeight()
        captureService.startCapture(
            width: captureWidth,
            height: captureHeight,
            framesPerSecond: NetworkProtocol.captureFramesPerSecond
        )
    }

    /// Stops sender session and resets services to idle placeholders.
    func stopSession() {
        shouldMaintainConnection = false
        stopHeartbeatTimers()
        captureService.stopCapture()
        transportService.disconnect()
        state = .idle
        sentFramesPerSecond = nil
        sentMegabitsPerSecond = nil
        droppedOutboundFrameCount = 0
        outboundWindowStartNanoseconds = nil
        outboundWindowFrameCount = 0
        outboundWindowPayloadBytes = 0
        isFrameEncodeInFlight = false
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
        handleCapturedFrame(synthetic)
    }

    private func handleCapturedFrame(_ capturedFrame: CapturedFrame) {
        guard case .running = state else { return }
        guard !isFrameEncodeInFlight else { return }
        isFrameEncodeInFlight = true

        let encoderService = self.encoderService

        Task.detached(priority: .userInitiated) { [weak self, capturedFrame] in
            let encodedFrame = encoderService.encode(frame: capturedFrame)

            do {
                let encodedPayload = try JSONEncoder().encode(encodedFrame)
                await MainActor.run {
                    guard let self else { return }
                    defer { self.isFrameEncodeInFlight = false }

                    guard case .running = self.state else { return }
                    let packet = VideoPacket(metadata: encodedFrame.metadata, payload: encodedPayload)
                    self.transportService.send(packet)
                    self.sentFrameCount += 1
                    self.updateOutboundMetrics(payloadByteCount: encodedPayload.count)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isFrameEncodeInFlight = false
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
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
                    state = .connected
                    lastInboundHeartbeatAt = Date()
                    startHeartbeatTimers()
                    // Auto-start streaming once handshake succeeds
                    startSession()
                } else {
                    state = .failed(ack.reason ?? "receiver rejected handshake")
                    shouldMaintainConnection = false
                    captureService.stopCapture()
                    transportService.disconnect()
                }
            case .heartbeat:
                _ = try envelope.decodePayload(as: HeartbeatPayload.self)
                lastInboundHeartbeatAt = Date()
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
        stopHeartbeatTimers()
        captureService.stopCapture()
        transportService.disconnect()

        guard shouldMaintainConnection, let host = desiredHost else { return }

        Timer.scheduledTimer(withTimeInterval: NetworkProtocol.reconnectDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldMaintainConnection else { return }
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
}
