import Accelerate
import AVFoundation
import CoreVideo
import Foundation

struct CaptureCardResolution: Hashable, Identifiable, Sendable {
    let width: Int
    let height: Int

    var id: String { "\(width)x\(height)" }

    var label: String {
        switch (width, height) {
        case (1920, 1080):
            return "1080p"
        case (1280, 720):
            return "720p"
        case (720, 576):
            return "576p"
        case (720, 480):
            return "480p"
        case (640, 480):
            return "480p VGA"
        default:
            return "\(width)x\(height)"
        }
    }
}

/// Discovers and captures frames from an external capture card device.
///
/// The service does **not** request a specific pixel format — requesting a
/// format that requires a conversion the driver refuses to perform (e.g. UYVY
/// → NV12 on the Elgato HD60 X under macOS 26) causes AVFoundation to deliver
/// zero frames with no error.  Instead we let the device output its native
/// format (`'2vuy'` UYVY for the Elgato) and hand native YUV buffers to Metal
/// whenever possible, avoiding CPU conversion in the low-latency path.
///
/// `alwaysDiscardsLateVideoFrames` is enabled to keep latency minimal: when
/// the render thread is slower than the capture device, we drop frames rather
/// than buffer them.
final class CaptureCardService: NSObject {
    enum CaptureCardError: LocalizedError {
        case noDeviceSelected
        case permissionDenied
        case cannotAddInput(String, underlying: Error?)
        case cannotAddOutput
        case captureSessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDeviceSelected:
                return "No capture device selected."
            case .permissionDenied:
                return "Camera access denied. Go to System Settings › Privacy & Security › Camera and enable DisplayReceiver."
            case .cannotAddInput(let name, let underlying):
                if let underlying {
                    return "Cannot open '\(name)': \(underlying.localizedDescription)"
                }
                return "Cannot open '\(name)'. The device may be in use by another app (e.g. QuickTime)."
            case .cannotAddOutput:
                return "Cannot add video output to capture session."
            case .captureSessionFailed(let reason):
                return "Capture session failed: \(reason)"
            }
        }
    }

    /// Called on a `.userInteractive` background queue for each captured frame.
    var onFrame: ((CVPixelBuffer, FrameMetadata, PixelFormat) -> Void)?
    /// Called on the main queue whenever the available device list changes.
    var onDevicesChanged: (([AVCaptureDevice]) -> Void)?
    /// Called on the main queue if the session encounters a runtime error.
    var onError: ((Error) -> Void)?

    /// Audio output volume for the capture card preview (0.0 = mute, 1.0 = full).
    var audioVolume: Float = 1.0 {
        didSet { audioPreviewOutput?.volume = audioVolume }
    }

    private(set) var hasAudio = false

    private var session: AVCaptureSession?
    private var audioPreviewOutput: AVCaptureAudioPreviewOutput?
    private let outputQueue = DispatchQueue(label: "wireddisplay.capturecard.output", qos: .userInteractive)
    private var frameIndex: UInt64 = 0
    private var deviceObservations: [NSObjectProtocol] = []

    // Pool of IOSurface-backed BGRA pixel buffers reused for converted UYVY frames.
    private var bgraPool: CVPixelBufferPool?
    private var bgraPoolWidth  = 0
    private var bgraPoolHeight = 0
    private var uyvyConversionInfo: vImage_YpCbCrToARGB?
    private var yuyvConversionInfo: vImage_YpCbCrToARGB?
    private var lastCaptureTimestampNanoseconds: UInt64?
    private var captureDiagnosticsWindowStartNanoseconds: UInt64?
    private var captureDiagnosticsFrameCount: UInt64 = 0
    private var captureDiagnosticsIntervalSumMilliseconds: Double = 0
    private var captureDiagnosticsIntervalMinMilliseconds = Double.greatestFiniteMagnitude
    private var captureDiagnosticsIntervalMaxMilliseconds: Double = 0
    private var captureDiagnosticsDroppedCount: UInt64 = 0
    private var lastPresentationTimestamp: CMTime?
    private var captureDiagnosticsPresentationIntervalSumMilliseconds: Double = 0
    private var captureDiagnosticsPresentationIntervalMinMilliseconds = Double.greatestFiniteMagnitude
    private var captureDiagnosticsPresentationIntervalMaxMilliseconds: Double = 0
    private var captureDiagnosticsPresentationIntervalCount: UInt64 = 0

    override init() {
        super.init()
        registerDeviceNotifications()
    }

    deinit {
        removeDeviceNotifications()
    }

    // MARK: - Permission

    /// Requests camera access (required on macOS 10.14+ even for listing capture devices).
    func requestAccess(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            DispatchQueue.main.async { [weak self] in
                self?.onDevicesChanged?(CaptureCardService.availableDevices())
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.onDevicesChanged?(CaptureCardService.availableDevices())
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async { completion(false) }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    // MARK: - Device discovery

    static func availableDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.external, .builtInWideAngleCamera]
        } else {
            deviceTypes = [.externalUnknown, .builtInWideAngleCamera]
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    static func availableResolutions(for device: AVCaptureDevice) -> [CaptureCardResolution] {
        let resolutions = Set(device.formats.compactMap { format -> CaptureCardResolution? in
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            guard width > 0, height > 0 else { return nil }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 25.0 }) else {
                return nil
            }
            return CaptureCardResolution(width: width, height: height)
        })

        return resolutions.sorted { lhs, rhs in
            if lhs.width * lhs.height == rhs.width * rhs.height {
                if lhs.width == rhs.width { return lhs.height > rhs.height }
                return lhs.width > rhs.width
            }
            return lhs.width * lhs.height > rhs.width * rhs.height
        }
    }

    // MARK: - Lifecycle

    func start(device: AVCaptureDevice, preferredResolution: CaptureCardResolution? = nil) throws {
        stop()
        frameIndex = 0
        bgraPool = nil
        uyvyConversionInfo = nil
        yuyvConversionInfo = nil
        resetCaptureDiagnostics()
        hasAudio = false

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        if let preferredResolution {
            configureSessionPreset(
                for: captureSession,
                preferredResolution: preferredResolution,
                phase: "initial"
            )
        }

        // ── Video input ────────────────────────────────────────────────────────
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: device)
        } catch {
            print("[CaptureCard] AVCaptureDeviceInput failed for '\(device.localizedName)': \(error)")
            throw error
        }
        guard captureSession.canAddInput(videoInput) else {
            throw CaptureCardError.cannotAddInput(device.localizedName, underlying: nil)
        }
        captureSession.addInput(videoInput)
        let selectedFormat = configureLowLatencyFormat(
            for: device,
            preferredResolution: preferredResolution
        )

        // ── Audio input (optional) ─────────────────────────────────────────────
        // The Elgato (and most capture cards) expose an audio device with the
        // same display name as the video device.  We look for an exact name
        // match so the HDMI audio follows the right card.
        if let audioDevice = findAudioDevice(matchingVideoDevice: device) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if captureSession.canAddInput(audioInput) {
                    captureSession.addInput(audioInput)
                    print("[CaptureCard] audio input: '\(audioDevice.localizedName)'")
                    hasAudio = true
                }
            } catch {
                print("[CaptureCard] audio input unavailable: \(error.localizedDescription)")
            }
        } else {
            print("[CaptureCard] no matching audio device found for '\(device.localizedName)'")
        }

        // ── Video output ───────────────────────────────────────────────────────
        let videoOutput = AVCaptureVideoDataOutput()
        // Do NOT set videoSettings — requesting a conversion format the driver
        // refuses (e.g. UYVY→NV12 on macOS 26) silently produces zero frames.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw CaptureCardError.cannotAddOutput
        }
        captureSession.addOutput(videoOutput)

        if let preferredResolution {
            configureSessionPreset(
                for: captureSession,
                preferredResolution: preferredResolution,
                phase: "after video output"
            )
        }
        if let selectedFormat {
            applyCaptureFormat(selectedFormat, to: device, context: "after video output")
        }

        if let connection = videoOutput.connection(with: .video) {
            let frameDuration = selectedFormat?.minFrameDuration ?? CMTime(value: 1, timescale: 60)
            connection.videoMinFrameDuration = frameDuration
            connection.videoMaxFrameDuration = frameDuration
            print("[CaptureCard] video connection frame duration forced to \(frameDurationDescription(frameDuration))")
        }

        let available = videoOutput.availableVideoPixelFormatTypes
        print("[CaptureCard] '\(device.localizedName)' output pixel formats: \(available.map { fcc($0) })")

        // ── Audio preview output (optional) ────────────────────────────────────
        // AVCaptureAudioPreviewOutput routes the captured HDMI audio directly
        // to the system default output device — near-zero latency, no decoding.
        if hasAudio {
            let preview = AVCaptureAudioPreviewOutput()
            preview.volume = audioVolume
            if captureSession.canAddOutput(preview) {
                captureSession.addOutput(preview)
                audioPreviewOutput = preview
                print("[CaptureCard] audio preview output added (volume=\(audioVolume))")
            } else {
                print("[CaptureCard] canAddOutput(audioPreview) returned false")
                hasAudio = false
            }
        }

        captureSession.commitConfiguration()
        if let selectedFormat {
            applyCaptureFormat(selectedFormat, to: device, context: "after commit")
        }
        self.session = captureSession

        DispatchQueue.global(qos: .userInteractive).async {
            captureSession.startRunning()
            if let selectedFormat {
                self.verifyActiveFormat(selectedFormat, on: device, context: "after startRunning")
            }
            print(
                "[CaptureCard] startRunning: isRunning=\(captureSession.isRunning) " +
                "hasAudio=\(self.hasAudio) active=\(self.activeFormatSummary(for: device))"
            )
        }
    }

    // MARK: - Video format selection

    private func configureLowLatencyFormat(
        for device: AVCaptureDevice,
        preferredResolution: CaptureCardResolution?
    ) -> CaptureFormatCandidate? {
        if let preferredResolution {
            print("[CaptureCard] requested resolution: \(preferredResolution.width)x\(preferredResolution.height) (\(preferredResolution.label))")
        }

        let candidates = device.formats.compactMap { format -> CaptureFormatCandidate? in
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            guard width > 0, height > 0 else { return nil }
            if let preferredResolution,
               (width != preferredResolution.width || height != preferredResolution.height) {
                return nil
            }

            let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
            let maxFrameRate = format.videoSupportedFrameRateRanges
                .filter { $0.maxFrameRate >= 59.0 }
                .map(\.maxFrameRate)
                .max()
            guard let maxFrameRate else { return nil }

            let preferredRange = preferredFrameRateRange(for: format.videoSupportedFrameRateRanges)
            guard let preferredRange else { return nil }

            let preferredDuration = preferredFrameDuration(for: preferredRange)
            return CaptureFormatCandidate(
                format: format,
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                maxFrameRate: maxFrameRate,
                selectedFrameRate: preferredRange.maxFrameRate,
                minFrameDuration: preferredDuration,
                score: scoreCaptureFormat(
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    maxFrameRate: maxFrameRate,
                    selectedFrameRate: preferredRange.maxFrameRate,
                    preferredResolution: preferredResolution
                )
            )
        }

        let preview = candidates
            .sorted { $0.score > $1.score }
            .prefix(8)
            .map { "\($0.width)x\($0.height) \(String(format: "%.2f", $0.maxFrameRate))fps \(fcc($0.pixelFormat)) score=\($0.score)" }
            .joined(separator: ", ")
        if !preview.isEmpty {
            print("[CaptureCard] top formats for '\(device.localizedName)': \(preview)")
        }

        guard let selected = candidates.max(by: { $0.score < $1.score }) else {
            if let preferredResolution {
                print(
                    "[CaptureCard] no 60fps format found for requested resolution " +
                    "\(preferredResolution.width)x\(preferredResolution.height); using device default"
                )
            } else {
                print("[CaptureCard] no 60fps capture format found; using device default")
            }
            return nil
        }

        applyCaptureFormat(selected, to: device, context: "selected")
        return selected
    }

    private func configureSessionPreset(
        for session: AVCaptureSession,
        preferredResolution: CaptureCardResolution,
        phase: String
    ) {
        guard let preset = sessionPreset(for: preferredResolution) else {
            print("[CaptureCard] no session preset for \(preferredResolution.width)x\(preferredResolution.height)")
            return
        }

        guard session.canSetSessionPreset(preset) else {
            print("[CaptureCard] cannot set session preset \(preset.rawValue) during \(phase)")
            return
        }

        session.sessionPreset = preset
        print("[CaptureCard] session preset set to \(preset.rawValue) during \(phase)")
    }

    private func sessionPreset(for resolution: CaptureCardResolution) -> AVCaptureSession.Preset? {
        switch (resolution.width, resolution.height) {
        case (3840, 2160):
            return .hd4K3840x2160
        case (1920, 1080):
            return .hd1920x1080
        case (1280, 720):
            return .hd1280x720
        case (640, 480):
            return .vga640x480
        case (352, 288):
            return .cif352x288
        case (320, 240):
            return .qvga320x240
        default:
            return nil
        }
    }

    private func applyCaptureFormat(
        _ selected: CaptureFormatCandidate,
        to device: AVCaptureDevice,
        context: String
    ) {
        do {
            try device.lockForConfiguration()
            device.activeFormat = selected.format
            device.activeVideoMinFrameDuration = selected.minFrameDuration
            device.activeVideoMaxFrameDuration = selected.minFrameDuration
            device.unlockForConfiguration()

            print(
                "[CaptureCard] selected format (\(context)): \(selected.width)x\(selected.height) " +
                "\(String(format: "%.2f", selected.maxFrameRate))fps \(fcc(selected.pixelFormat)); " +
                "active duration=\(frameDurationDescription(selected.minFrameDuration))"
            )
        } catch {
            print("[CaptureCard] format selection failed during \(context): \(error.localizedDescription)")
        }
    }

    private func verifyActiveFormat(
        _ selected: CaptureFormatCandidate,
        on device: AVCaptureDevice,
        context: String
    ) {
        let description = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard Int(dimensions.width) != selected.width || Int(dimensions.height) != selected.height else {
            return
        }

        print(
            "[CaptureCard] WARNING: active format changed \(context): expected " +
            "\(selected.width)x\(selected.height), got \(dimensions.width)x\(dimensions.height). " +
            "The macOS capture session or driver is overriding the requested resolution."
        )
    }

    private func scoreCaptureFormat(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        maxFrameRate: Double,
        selectedFrameRate: Double,
        preferredResolution: CaptureCardResolution?
    ) -> Int {
        var score = 0

        if preferredResolution != nil {
            score += 20_000
        } else if width == 1920, height == 1080 {
            score += 10_000
        } else if width == 1280, height == 720 {
            score += 6_000
        } else if width <= 1920, height <= 1080 {
            score += 3_000
        } else {
            score -= 2_000
        }

        if selectedFrameRate >= 59.0, selectedFrameRate <= 61.0 {
            score += 2_000
        } else if selectedFrameRate > 61.0 {
            score += 1_500
        }

        if width == 1920, height == 1080, maxFrameRate >= 119.0 {
            score += 1_200
        }

        switch pixelFormat {
        case kCVPixelFormatType_422YpCbCr8, 0x79757673:
            score += 800
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            score += maxFrameRate >= 119.0 ? 1_400 : 600
        case kCVPixelFormatType_32BGRA:
            score += 300
        default:
            break
        }

        return score
    }

    private func preferredFrameRateRange(for ranges: [AVFrameRateRange]) -> AVFrameRateRange? {
        if let sixty = ranges.min(by: { lhs, rhs in
            abs(lhs.maxFrameRate - 60.0) < abs(rhs.maxFrameRate - 60.0)
        }), abs(sixty.maxFrameRate - 60.0) < 1.0 {
            return sixty
        }

        return ranges
            .filter { $0.maxFrameRate >= 59.0 }
            .max { lhs, rhs in lhs.maxFrameRate < rhs.maxFrameRate }
    }

    private func preferredFrameDuration(for range: AVFrameRateRange) -> CMTime {
        if range.maxFrameDuration.isValid, range.maxFrameDuration.seconds > 0 {
            return range.maxFrameDuration
        }
        return range.minFrameDuration
    }

    private func frameDurationDescription(_ duration: CMTime) -> String {
        let fps = duration.seconds > 0 ? 1.0 / duration.seconds : 0
        return String(format: "%.2ffps (%lld/%d)", fps, duration.value, duration.timescale)
    }

    private func activeFormatSummary(for device: AVCaptureDevice) -> String {
        let description = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
        let minDuration = device.activeVideoMinFrameDuration
        let fps = minDuration.seconds > 0 ? 1.0 / minDuration.seconds : 0
        return "\(dimensions.width)x\(dimensions.height) \(String(format: "%.2f", fps))fps \(fcc(pixelFormat))"
    }

    func stop() {
        session?.stopRunning()
        session = nil
        audioPreviewOutput = nil
        hasAudio = false
        frameIndex = 0
        bgraPool = nil
        bgraPoolWidth  = 0
        bgraPoolHeight = 0
        uyvyConversionInfo = nil
        yuyvConversionInfo = nil
        resetCaptureDiagnostics()
    }

    // MARK: - Audio device discovery

    /// Finds the audio device whose display name matches the given video device.
    /// Capture cards typically expose a companion audio device with the same name.
    private func findAudioDevice(matchingVideoDevice video: AVCaptureDevice) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.external, .builtInMicrophone]
        } else {
            types = [.externalUnknown, .builtInMicrophone]
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        )
        // Exact match first; partial match as fallback for devices whose audio
        // name has a suffix (e.g. "Elgato HD60 X Audio").
        return discovery.devices.first { $0.localizedName == video.localizedName }
            ?? discovery.devices.first {
                $0.localizedName.localizedCaseInsensitiveContains(video.localizedName)
                || video.localizedName.localizedCaseInsensitiveContains($0.localizedName)
            }
    }

    var isRunning: Bool { session?.isRunning == true }

    // MARK: - FourCC helper

    private func fcc(_ v: OSType) -> String {
        let b = withUnsafeBytes(of: v.bigEndian) { Array($0) }
        return String(bytes: b, encoding: .ascii).map { "'\($0)'" } ?? "0x\(String(v, radix: 16))"
    }

    // MARK: - Device change notifications

    private func registerDeviceNotifications() {
        let center = NotificationCenter.default
        let connectedName: Notification.Name
        let disconnectedName: Notification.Name
        if #available(macOS 15.0, *) {
            connectedName = AVCaptureDevice.wasConnectedNotification
            disconnectedName = AVCaptureDevice.wasDisconnectedNotification
        } else {
            connectedName = .AVCaptureDeviceWasConnected
            disconnectedName = .AVCaptureDeviceWasDisconnected
        }
        let connected = center.addObserver(forName: connectedName, object: nil, queue: .main) { [weak self] _ in
            self?.onDevicesChanged?(CaptureCardService.availableDevices())
        }
        let disconnected = center.addObserver(forName: disconnectedName, object: nil, queue: .main) { [weak self] _ in
            self?.onDevicesChanged?(CaptureCardService.availableDevices())
        }
        deviceObservations = [connected, disconnected]
    }

    private func removeDeviceNotifications() {
        deviceObservations.forEach { NotificationCenter.default.removeObserver($0) }
        deviceObservations.removeAll()
    }

    // MARK: - BGRA pixel buffer pool

    /// Returns (or lazily creates) a pool of IOSurface-backed BGRA buffers at the given size.
    private func bgraPixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = bgraPool, bgraPoolWidth == width, bgraPoolHeight == height {
            return pool
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        bgraPool = pool
        bgraPoolWidth  = width
        bgraPoolHeight = height
        return pool
    }

    // MARK: - UYVY / YUYV → BGRA conversion

    private func conversionInfoForYUV422(isCbFirst: Bool) -> vImage_YpCbCrToARGB? {
        if isCbFirst, let uyvyConversionInfo {
            return uyvyConversionInfo
        }
        if !isCbFirst, let yuyvConversionInfo {
            return yuyvConversionInfo
        }

        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 255, YpMin: 0,
            CbCrMax: 255, CbCrMin: 0
        )
        let srcFmt: vImageYpCbCrType = isCbFirst
            ? kvImage422CbYpCrYp8
            : kvImage422YpCbYpCr8

        var convInfo = vImage_YpCbCrToARGB()
        let genErr = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
            &pixelRange,
            &convInfo,
            srcFmt,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        guard genErr == kvImageNoError else {
            print("[CaptureCard] vImage setup failed: \(genErr)")
            return nil
        }

        if isCbFirst {
            uyvyConversionInfo = convInfo
        } else {
            yuyvConversionInfo = convInfo
        }
        return convInfo
    }

    /// Converts a packed YCbCr 4:2:2 pixel buffer (UYVY or YUYV) to a BGRA
    /// CVPixelBuffer using vImage.  The destination buffer is allocated from a
    /// reusable pool so there is no per-frame heap allocation after the first
    /// frame at each resolution.
    ///
    /// BT.709 limited-range is used because HD HDMI sources use that standard.
    /// The conversion is ~0.5 ms for 1920×1080 on Apple Silicon.
    private func convertYUV422ToBGRA(
        _ src: CVPixelBuffer,
        width: Int,
        height: Int,
        isCbFirst: Bool   // true = UYVY ('2vuy'), false = YUYV ('yuvs')
    ) -> CVPixelBuffer? {
        guard let pool = bgraPixelBufferPool(width: width, height: height) else {
            print("[CaptureCard] BGRA pool creation failed")
            return nil
        }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let dst else {
            print("[CaptureCard] pool pixel buffer allocation failed")
            return nil
        }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        guard let srcPtr = CVPixelBufferGetBaseAddress(src),
              let dstPtr = CVPixelBufferGetBaseAddress(dst) else { return nil }

        var srcBuf = vImage_Buffer(
            data: srcPtr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(src)
        )
        var dstBuf = vImage_Buffer(
            data: dstPtr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(dst)
        )

        guard var convInfo = conversionInfoForYUV422(isCbFirst: isCbFirst) else { return nil }

        // Step 1: convert UYVY/YUYV → ARGB directly into the destination buffer.
        let convErr: vImage_Error
        if isCbFirst {
            convErr = vImageConvert_422CbYpCrYp8ToARGB8888(
                &srcBuf, &dstBuf, &convInfo, nil, 255, vImage_Flags(kvImageNoFlags)
            )
        } else {
            convErr = vImageConvert_422YpCbYpCr8ToARGB8888(
                &srcBuf, &dstBuf, &convInfo, nil, 255, vImage_Flags(kvImageNoFlags)
            )
        }
        guard convErr == kvImageNoError else {
            print("[CaptureCard] vImage conversion failed: \(convErr)")
            return nil
        }

        // Step 2: permute ARGB → BGRA in-place.
        // ARGB channels: A=0 R=1 G=2 B=3  →  BGRA: B=0 G=1 R=2 A=3
        let permute: [UInt8] = [3, 2, 1, 0]
        vImagePermuteChannels_ARGB8888(&dstBuf, &dstBuf, permute, vImage_Flags(kvImageNoFlags))

        return dst
    }

    private func resetCaptureDiagnostics() {
        lastCaptureTimestampNanoseconds = nil
        captureDiagnosticsWindowStartNanoseconds = nil
        captureDiagnosticsFrameCount = 0
        captureDiagnosticsIntervalSumMilliseconds = 0
        captureDiagnosticsIntervalMinMilliseconds = Double.greatestFiniteMagnitude
        captureDiagnosticsIntervalMaxMilliseconds = 0
        captureDiagnosticsDroppedCount = 0
        lastPresentationTimestamp = nil
        captureDiagnosticsPresentationIntervalSumMilliseconds = 0
        captureDiagnosticsPresentationIntervalMinMilliseconds = Double.greatestFiniteMagnitude
        captureDiagnosticsPresentationIntervalMaxMilliseconds = 0
        captureDiagnosticsPresentationIntervalCount = 0
    }

    private func recordCaptureDiagnostics(at now: UInt64, presentationTimestamp: CMTime) {
        if captureDiagnosticsWindowStartNanoseconds == nil {
            captureDiagnosticsWindowStartNanoseconds = now
        }

        if let lastCaptureTimestampNanoseconds, now >= lastCaptureTimestampNanoseconds {
            let interval = Double(now - lastCaptureTimestampNanoseconds) / 1_000_000.0
            captureDiagnosticsIntervalSumMilliseconds += interval
            captureDiagnosticsIntervalMinMilliseconds = min(captureDiagnosticsIntervalMinMilliseconds, interval)
            captureDiagnosticsIntervalMaxMilliseconds = max(captureDiagnosticsIntervalMaxMilliseconds, interval)
        }
        lastCaptureTimestampNanoseconds = now
        captureDiagnosticsFrameCount += 1

        if presentationTimestamp.isValid,
           let lastPresentationTimestamp,
           lastPresentationTimestamp.isValid {
            let interval = CMTimeSubtract(presentationTimestamp, lastPresentationTimestamp).seconds * 1_000.0
            if interval >= 0, interval.isFinite {
                captureDiagnosticsPresentationIntervalSumMilliseconds += interval
                captureDiagnosticsPresentationIntervalMinMilliseconds = min(captureDiagnosticsPresentationIntervalMinMilliseconds, interval)
                captureDiagnosticsPresentationIntervalMaxMilliseconds = max(captureDiagnosticsPresentationIntervalMaxMilliseconds, interval)
                captureDiagnosticsPresentationIntervalCount += 1
            }
        }
        if presentationTimestamp.isValid {
            lastPresentationTimestamp = presentationTimestamp
        }

        guard let windowStart = captureDiagnosticsWindowStartNanoseconds,
              now >= windowStart,
              now - windowStart >= 2_000_000_000 else {
            return
        }

        let elapsedSeconds = Double(now - windowStart) / 1_000_000_000.0
        let frameRate = Double(captureDiagnosticsFrameCount) / elapsedSeconds
        let averageInterval = captureDiagnosticsFrameCount > 1
            ? captureDiagnosticsIntervalSumMilliseconds / Double(captureDiagnosticsFrameCount - 1)
            : 0
        let minInterval = captureDiagnosticsIntervalMinMilliseconds == Double.greatestFiniteMagnitude
            ? 0
            : captureDiagnosticsIntervalMinMilliseconds
        let presentationAverageInterval = captureDiagnosticsPresentationIntervalCount > 0
            ? captureDiagnosticsPresentationIntervalSumMilliseconds / Double(captureDiagnosticsPresentationIntervalCount)
            : 0
        let presentationFrameRate = presentationAverageInterval > 0
            ? 1_000.0 / presentationAverageInterval
            : 0
        let presentationMinInterval = captureDiagnosticsPresentationIntervalMinMilliseconds == Double.greatestFiniteMagnitude
            ? 0
            : captureDiagnosticsPresentationIntervalMinMilliseconds

        print(
            String(
                format: "[CaptureCard][Pacing] capture=%.1fHz pts=%.1fHz dropped=%llu interval avg/min/max=%.2f/%.2f/%.2fms pts avg/min/max=%.2f/%.2f/%.2fms",
                frameRate,
                presentationFrameRate,
                captureDiagnosticsDroppedCount,
                averageInterval,
                minInterval,
                captureDiagnosticsIntervalMaxMilliseconds,
                presentationAverageInterval,
                presentationMinInterval,
                captureDiagnosticsPresentationIntervalMaxMilliseconds
            )
        )

        captureDiagnosticsWindowStartNanoseconds = now
        captureDiagnosticsFrameCount = 0
        captureDiagnosticsIntervalSumMilliseconds = 0
        captureDiagnosticsIntervalMinMilliseconds = Double.greatestFiniteMagnitude
        captureDiagnosticsIntervalMaxMilliseconds = 0
        captureDiagnosticsDroppedCount = 0
        captureDiagnosticsPresentationIntervalSumMilliseconds = 0
        captureDiagnosticsPresentationIntervalMinMilliseconds = Double.greatestFiniteMagnitude
        captureDiagnosticsPresentationIntervalMaxMilliseconds = 0
        captureDiagnosticsPresentationIntervalCount = 0
    }
}

private struct CaptureFormatCandidate {
    let format: AVCaptureDevice.Format
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let maxFrameRate: Double
    let selectedFrameRate: Double
    let minFrameDuration: CMTime
    let score: Int
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureCardService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[CaptureCard] sample buffer has no image buffer — dropping")
            return
        }

        let now   = DispatchTime.now().uptimeNanoseconds
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let index  = frameIndex
        frameIndex &+= 1
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        recordCaptureDiagnostics(at: now, presentationTimestamp: presentationTimestamp)

        let cvFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if index < 5 || index % 300 == 0 {
            print("[CaptureCard] frame \(index): \(width)×\(height) format=\(fcc(cvFormat))")
        }

        // Route to the correct pixel format and, if necessary, convert.
        let deliveredBuffer: CVPixelBuffer
        let pixelFormat: PixelFormat

        switch cvFormat {

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            // Native NV12 — Metal YUV shader handles this directly (zero copy).
            deliveredBuffer = pixelBuffer
            pixelFormat = .yuv420

        case kCVPixelFormatType_32BGRA:
            // Native BGRA — Metal BGRA path handles this directly.
            deliveredBuffer = pixelBuffer
            pixelFormat = .bgra8

        case kCVPixelFormatType_422YpCbCr8:         // '2vuy'  UYVY  (Elgato native)
            deliveredBuffer = pixelBuffer
            pixelFormat = .yuv422UYVY

        case 0x79757673:                             // 'yuvs'  YUYV
            deliveredBuffer = pixelBuffer
            pixelFormat = .yuv422YUYV

        default:
            // Unknown format: pass through and let the Metal path figure it out.
            if index < 5 {
                print("[CaptureCard] unknown format \(fcc(cvFormat)) — passing as bgra8")
            }
            deliveredBuffer = pixelBuffer
            pixelFormat = .bgra8
        }

        let metadata = FrameMetadata(
            frameIndex: index,
            timestampNanoseconds: now,
            encodeCompleteTimestampNanoseconds: nil,
            width: width,
            height: height,
            isKeyFrame: true
        )

        onFrame?(deliveredBuffer, metadata, pixelFormat)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        captureDiagnosticsDroppedCount += 1
        let idx = frameIndex
        if idx < 10 {
            print("[CaptureCard] frame DROPPED idx=\(idx) — late frame discarded (expected at zero latency)")
        }
    }
}
