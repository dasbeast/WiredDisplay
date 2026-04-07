import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Capture pipeline using SCStream for continuous screen capture.
/// Can target a specific display (e.g. the virtual extended display).
final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private enum ProcessingBacklog {
        static let maxPendingScreenSamples = 2
        static let lagWarningNanoseconds: UInt64 = 20_000_000
        static let logIntervalNanoseconds: UInt64 = 30_000_000_000
    }

    private(set) var isCapturing = false

    private var stream: SCStream?
    private var frameIndex: UInt64 = 0
    private var forceNextKeyFrame = false
    private var audioPacketIndex: UInt64 = 0
    private let captureQueue = DispatchQueue(label: "wireddisplay.sender.capture", qos: .userInteractive)
    private let screenProcessingQueue = DispatchQueue(label: "wireddisplay.sender.capture.screen", qos: .userInitiated)
    private let stateLock = NSLock()
    private var lastScreenFrameTimestampNanoseconds: UInt64?
    private var lastScreenFrameGapWarningTimestampNanoseconds: UInt64?
    private var lastIncompleteScreenFrameLogTimestampNanoseconds: UInt64?
    private var lastScreenProcessingLagWarningTimestampNanoseconds: UInt64?
    private var lastScreenProcessingDurationWarningTimestampNanoseconds: UInt64?
    private var pendingScreenSamples = 0
    private var droppedScreenSamples: UInt64 = 0
    private var captureGeneration: UInt64 = 0
    private let outputAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: NetworkProtocol.audioSampleRateHz,
        channels: AVAudioChannelCount(NetworkProtocol.audioChannelCount),
        interleaved: true
    )
    private var audioConverter: AVAudioConverter?
    private var audioConverterSourceSignature: String?

    /// The CGDirectDisplayID to capture. If 0, captures the main display.
    var targetDisplayID: CGDirectDisplayID = 0

    var onCapturedFrame: ((CapturedFrame) -> Void)?
    var onCapturedAudio: ((AudioPacket) -> Void)?
    var onError: ((Error) -> Void)?

    func startCapture(
        width: Int,
        height: Int,
        framesPerSecond: Int = 60,
        streamingPipelineMode: NetworkProtocol.StreamingPipelineMode = .adaptiveUpscale,
        showsCursor: Bool = true
    ) {
        stopCapture()

        isCapturing = true
        stateLock.lock()
        forceNextKeyFrame = true
        audioPacketIndex = 0
        captureGeneration &+= 1
        pendingScreenSamples = 0
        droppedScreenSamples = 0
        lastScreenProcessingLagWarningTimestampNanoseconds = nil
        lastScreenProcessingDurationWarningTimestampNanoseconds = nil
        stateLock.unlock()
        audioConverter = nil
        audioConverterSourceSignature = nil
        lastScreenFrameTimestampNanoseconds = nil
        lastScreenFrameGapWarningTimestampNanoseconds = nil
        lastIncompleteScreenFrameLogTimestampNanoseconds = nil

        if NetworkProtocol.forceSyntheticCaptureForDiagnostics {
            startSyntheticCapture(width: width, height: height, framesPerSecond: framesPerSecond)
            return
        }

        Task {
            do {
                try await startSCStream(
                    width: width,
                    height: height,
                    framesPerSecond: framesPerSecond,
                    streamingPipelineMode: streamingPipelineMode,
                    showsCursor: showsCursor
                )
            } catch {
                print("[CaptureService] SCStream failed: \(error). Falling back to synthetic capture.")
                onError?(CaptureServiceError.screenCapturePermissionDenied(underlying: error))
                startSyntheticCapture(width: width, height: height, framesPerSecond: framesPerSecond)
            }
        }
    }

    func stopCapture() {
        isCapturing = false
        lastScreenFrameTimestampNanoseconds = nil
        lastScreenFrameGapWarningTimestampNanoseconds = nil
        lastIncompleteScreenFrameLogTimestampNanoseconds = nil

        if let stream {
            self.stream = nil
            Task {
                try? await stream.stopCapture()
            }
        }

        syntheticTimer?.cancel()
        syntheticTimer = nil
    }

    // MARK: - SCStream Setup

    private func startSCStream(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        streamingPipelineMode: NetworkProtocol.StreamingPipelineMode,
        showsCursor: Bool
    ) async throws {
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        print("[CaptureService] Available displays: \(available.displays.map { "ID=\($0.displayID) \($0.width)x\($0.height)" })")
        print("[CaptureService] Target display ID: \(targetDisplayID)")

        // Find the target display — either the virtual display or the main display
        let display: SCDisplay
        if targetDisplayID != 0,
           let targetDisplay = available.displays.first(where: { $0.displayID == targetDisplayID }) {
            display = targetDisplay
            print("[CaptureService] Found target virtual display \(targetDisplayID): \(display.width)x\(display.height)")
        } else if targetDisplayID != 0 {
            print("[CaptureService] WARNING: Target display \(targetDisplayID) not found in SCShareableContent! Falling back to main display.")
            if let mainDisplay = available.displays.first {
                display = mainDisplay
                print("[CaptureService] Using main display \(display.displayID) instead")
            } else {
                throw CaptureServiceError.noDisplayAvailable
            }
        } else if let mainDisplay = available.displays.first {
            display = mainDisplay
            print("[CaptureService] Capturing main display \(display.displayID)")
        } else {
            throw CaptureServiceError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // SCDisplay dimensions are points; SCStreamConfiguration expects pixels.
        // Capture at backing-pixel resolution to preserve Retina sharpness.
        let captureScale: Float
        if #available(macOS 14.0, *) {
            captureScale = max(1.0, filter.pointPixelScale)
        } else {
            captureScale = 1.0
        }

        let sourcePointsWidth: CGFloat
        let sourcePointsHeight: CGFloat
        if #available(macOS 14.0, *) {
            sourcePointsWidth = max(1.0, filter.contentRect.width)
            sourcePointsHeight = max(1.0, filter.contentRect.height)
        } else {
            sourcePointsWidth = CGFloat(max(1, display.width))
            sourcePointsHeight = CGFloat(max(1, display.height))
        }

        var captureWidthPixels = max(1, Int((sourcePointsWidth * CGFloat(captureScale)).rounded()))
        var captureHeightPixels = max(1, Int((sourcePointsHeight * CGFloat(captureScale)).rounded()))

        let totalPixels = captureWidthPixels * captureHeightPixels
        let pipelineDescription: String
        if streamingPipelineMode == .adaptiveUpscale {
            // Bound capture resolution for stable real-time encoding at target FPS.
            // Adaptive Upscale should remain the lower-latency path regardless of chip tier.
            let pixelBudget = max(1, NetworkProtocol.adaptiveUpscaleCapturePixelBudget)
            if totalPixels > pixelBudget {
                let downscale = sqrt(Double(pixelBudget) / Double(totalPixels))
                captureWidthPixels = max(1, Int(Double(captureWidthPixels) * downscale))
                captureHeightPixels = max(1, Int(Double(captureHeightPixels) * downscale))
            }
            pipelineDescription = "\(streamingPipelineMode.rawValue), budget \(pixelBudget) px"
        } else {
            pipelineDescription = streamingPipelineMode.rawValue
        }

        // H.264 encoders are generally happiest with even dimensions.
        if captureWidthPixels % 2 != 0 { captureWidthPixels -= 1 }
        if captureHeightPixels % 2 != 0 { captureHeightPixels -= 1 }
        captureWidthPixels = max(2, captureWidthPixels)
        captureHeightPixels = max(2, captureHeightPixels)

        print(
            "[CaptureService] Stream source points=\(Int(sourcePointsWidth))x\(Int(sourcePointsHeight)) " +
            "scale=\(String(format: "%.2f", captureScale)) -> pixels=\(captureWidthPixels)x\(captureHeightPixels) " +
            "(requested \(width)x\(height), pipeline \(pipelineDescription))"
        )
        if !NetworkProtocol.enableSenderAudioCapture {
            print("[CaptureService] Audio capture disabled for diagnostics")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = captureWidthPixels
        configuration.height = captureHeightPixels
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = false
        configuration.capturesAudio = NetworkProtocol.enableSenderAudioCapture
        configuration.excludesCurrentProcessAudio = NetworkProtocol.enableSenderAudioCapture
        if NetworkProtocol.enableSenderAudioCapture {
            configuration.sampleRate = Int(NetworkProtocol.audioSampleRateHz)
            configuration.channelCount = NetworkProtocol.audioChannelCount
        }
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }
        configuration.queueDepth = 3
        configuration.showsCursor = showsCursor

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if NetworkProtocol.enableSenderAudioCapture {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        }
        try await newStream.startCapture()

        self.stream = newStream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        guard isCapturing else { return }

        switch type {
        case .screen:
            let frameTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            if let frameStatus = screenFrameStatus(from: sampleBuffer),
               frameStatus != .complete {
                logIncompleteScreenFrameIfNeeded(status: frameStatus, at: frameTimestampNanoseconds)
                return
            }

            if let lastScreenFrameTimestampNanoseconds,
               frameTimestampNanoseconds > lastScreenFrameTimestampNanoseconds {
                let gapNanoseconds = frameTimestampNanoseconds - lastScreenFrameTimestampNanoseconds
                if gapNanoseconds >= 500_000_000 {
                    let shouldLogGapWarning: Bool
                    if let lastScreenFrameGapWarningTimestampNanoseconds {
                        shouldLogGapWarning =
                            frameTimestampNanoseconds >= (
                                lastScreenFrameGapWarningTimestampNanoseconds +
                                ProcessingBacklog.logIntervalNanoseconds
                            )
                    } else {
                        shouldLogGapWarning = true
                    }

                    if shouldLogGapWarning {
                        lastScreenFrameGapWarningTimestampNanoseconds = frameTimestampNanoseconds
                        print(
                            "[CaptureService] Screen frame gap " +
                            "\(String(format: "%.1f", Double(gapNanoseconds) / 1_000_000.0)) ms " +
                            "on display \(targetDisplayID)"
                        )
                    }
                }
            }
            lastScreenFrameTimestampNanoseconds = frameTimestampNanoseconds

            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let generation = currentCaptureGeneration()
            guard beginScreenSampleProcessing(for: generation) else { return }

            screenProcessingQueue.async { [weak self] in
                self?.processScreenSample(
                    pixelBuffer: pixelBuffer,
                    generation: generation,
                    enqueuedAtNanoseconds: frameTimestampNanoseconds
                )
            }
        case .audio:
            guard NetworkProtocol.enableSenderAudioCapture else { return }
            guard let audioPacket = makeAudioPacket(from: sampleBuffer) else { return }
            onCapturedAudio?(audioPacket)
        default:
            return
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        print("[CaptureService] Stream stopped with error: \(error)")
        onError?(error)
    }

    private func screenFrameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first,
        let rawStatus = attachments[.status] as? Int else {
            return nil
        }

        return SCFrameStatus(rawValue: rawStatus)
    }

    private func logIncompleteScreenFrameIfNeeded(status: SCFrameStatus, at timestampNanoseconds: UInt64) {
        if status == .idle {
            return
        }

        let shouldLog: Bool
        if let lastIncompleteScreenFrameLogTimestampNanoseconds {
            shouldLog = timestampNanoseconds >= (lastIncompleteScreenFrameLogTimestampNanoseconds + 1_000_000_000)
        } else {
            shouldLog = true
        }

        guard shouldLog else { return }
        lastIncompleteScreenFrameLogTimestampNanoseconds = timestampNanoseconds
        print("[CaptureService] Ignoring \(screenFrameStatusDescription(status)) screen frame")
    }

    private func screenFrameStatusDescription(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete:
            return "complete"
        case .idle:
            return "idle"
        case .blank:
            return "blank"
        case .suspended:
            return "suspended"
        case .started:
            return "started"
        case .stopped:
            return "stopped"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    private func currentCaptureGeneration() -> UInt64 {
        stateLock.lock()
        let generation = captureGeneration
        stateLock.unlock()
        return generation
    }

    private func beginScreenSampleProcessing(for generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard generation == captureGeneration else { return false }
        guard pendingScreenSamples < ProcessingBacklog.maxPendingScreenSamples else {
            droppedScreenSamples += 1
            if droppedScreenSamples == 1 || droppedScreenSamples.isMultiple(of: 60) {
                print(
                    "[CaptureService] Dropped \(droppedScreenSamples) screen frames before processing " +
                    "(pending=\(pendingScreenSamples), display \(targetDisplayID))"
                )
            }
            return false
        }

        pendingScreenSamples += 1
        return true
    }

    private func finishScreenSampleProcessing(for generation: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard generation == captureGeneration else { return }
        pendingScreenSamples = max(0, pendingScreenSamples - 1)
    }

    private func processScreenSample(
        pixelBuffer: CVPixelBuffer,
        generation: UInt64,
        enqueuedAtNanoseconds: UInt64
    ) {
        defer { finishScreenSampleProcessing(for: generation) }

        guard isCapturing else { return }
        guard generation == currentCaptureGeneration() else { return }

        let processingStartNanoseconds = DispatchTime.now().uptimeNanoseconds
        logScreenProcessingLagIfNeeded(
            startNanoseconds: processingStartNanoseconds,
            enqueuedAtNanoseconds: enqueuedAtNanoseconds
        )

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard frameWidth > 0, frameHeight > 0 else { return }

        let currentIndex: UInt64
        let isFirstFrame: Bool
        stateLock.lock()
        guard generation == captureGeneration else {
            stateLock.unlock()
            return
        }
        currentIndex = frameIndex
        frameIndex += 1
        isFirstFrame = forceNextKeyFrame
        forceNextKeyFrame = false
        stateLock.unlock()

        let metadata = FrameMetadata(
            frameIndex: currentIndex,
            timestampNanoseconds: enqueuedAtNanoseconds,
            width: frameWidth,
            height: frameHeight,
            isKeyFrame: isFirstFrame || currentIndex % 60 == 0
        )

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let frame = CapturedFrame(
            metadata: metadata,
            rawData: Data(),
            bytesPerRow: bytesPerRow,
            pixelFormat: .yuv420,
            pixelBuffer: pixelBuffer
        )
        onCapturedFrame?(frame)

        logScreenProcessingDurationIfNeeded(startNanoseconds: processingStartNanoseconds)
    }

    private func logScreenProcessingLagIfNeeded(
        startNanoseconds: UInt64,
        enqueuedAtNanoseconds: UInt64
    ) {
        guard startNanoseconds > enqueuedAtNanoseconds else { return }
        let lagNanoseconds = startNanoseconds - enqueuedAtNanoseconds
        guard lagNanoseconds >= ProcessingBacklog.lagWarningNanoseconds else { return }

        let pending: Int
        let dropped: UInt64
        let shouldLog: Bool
        stateLock.lock()
        pending = pendingScreenSamples
        dropped = droppedScreenSamples
        if let lastWarning = lastScreenProcessingLagWarningTimestampNanoseconds {
            shouldLog = startNanoseconds >= (lastWarning + ProcessingBacklog.logIntervalNanoseconds)
        } else {
            shouldLog = true
        }
        if shouldLog {
            lastScreenProcessingLagWarningTimestampNanoseconds = startNanoseconds
        }
        stateLock.unlock()

        guard shouldLog else { return }
        print(
            "[CaptureService] Screen sample processing lag " +
            "\(String(format: "%.1f", Double(lagNanoseconds) / 1_000_000.0)) ms " +
            "(pending=\(pending), dropped=\(dropped), display \(targetDisplayID))"
        )
    }

    private func logScreenProcessingDurationIfNeeded(startNanoseconds: UInt64) {
        let endNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard endNanoseconds > startNanoseconds else { return }
        let durationNanoseconds = endNanoseconds - startNanoseconds
        guard durationNanoseconds >= ProcessingBacklog.lagWarningNanoseconds else { return }

        let pending: Int
        let shouldLog: Bool
        stateLock.lock()
        pending = pendingScreenSamples
        if let lastWarning = lastScreenProcessingDurationWarningTimestampNanoseconds {
            shouldLog = endNanoseconds >= (lastWarning + ProcessingBacklog.logIntervalNanoseconds)
        } else {
            shouldLog = true
        }
        if shouldLog {
            lastScreenProcessingDurationWarningTimestampNanoseconds = endNanoseconds
        }
        stateLock.unlock()

        guard shouldLog else { return }
        print(
            "[CaptureService] Screen sample processing took " +
            "\(String(format: "%.1f", Double(durationNanoseconds) / 1_000_000.0)) ms " +
            "(pending=\(pending), display \(targetDisplayID))"
        )
    }

    // MARK: - Synthetic Fallback

    private var syntheticTimer: DispatchSourceTimer?

    private func makeAudioPacket(from sampleBuffer: CMSampleBuffer) -> AudioPacket? {
        guard let outputAudioFormat else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let sourceASBDPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        guard let sourceFormat = AVAudioFormat(streamDescription: sourceASBDPointer) else { return nil }

        let sourceSignature = audioFormatSignature(for: sourceASBDPointer.pointee)
        if audioConverter == nil || audioConverterSourceSignature != sourceSignature {
            audioConverter = AVAudioConverter(from: sourceFormat, to: outputAudioFormat)
            audioConverterSourceSignature = sourceSignature
        }

        guard let audioConverter else { return nil }

        let sourceFrameCount = AVAudioFrameCount(max(0, CMSampleBufferGetNumSamples(sampleBuffer)))
        guard sourceFrameCount > 0 else { return nil }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            return nil
        }

        sourceBuffer.frameLength = sourceFrameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sourceFrameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let ratio = outputAudioFormat.sampleRate / max(1.0, sourceFormat.sampleRate)
        let targetCapacity = AVAudioFrameCount(max(Double(sourceFrameCount) * ratio, 1.0).rounded(.up) + 64)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputAudioFormat, frameCapacity: targetCapacity) else {
            return nil
        }

        var converterError: NSError?
        var consumedSourceBuffer = false
        let conversionStatus = audioConverter.convert(to: convertedBuffer, error: &converterError) { _, outStatus in
            if consumedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            consumedSourceBuffer = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard converterError == nil else { return nil }
        guard conversionStatus == .haveData || conversionStatus == .inputRanDry else { return nil }
        guard convertedBuffer.frameLength > 0 else { return nil }

        let bytesPerFrame = Int(outputAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let payloadLength = Int(convertedBuffer.frameLength) * bytesPerFrame
        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let audioBufferData = audioBuffer.mData else { return nil }
        guard Int(audioBuffer.mDataByteSize) >= payloadLength else { return nil }
        let payload = Data(bytes: audioBufferData, count: payloadLength)

        let audioPacket = AudioPacket(
            packetIndex: audioPacketIndex,
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            codec: .pcmInt16Interleaved,
            sampleRateHz: outputAudioFormat.sampleRate,
            channelCount: Int(outputAudioFormat.channelCount),
            frameCount: Int(convertedBuffer.frameLength),
            payload: payload
        )
        audioPacketIndex += 1
        return audioPacket
    }

    private func audioFormatSignature(for asbd: AudioStreamBasicDescription) -> String {
        [
            String(asbd.mSampleRate),
            String(asbd.mFormatID),
            String(asbd.mFormatFlags),
            String(asbd.mBytesPerPacket),
            String(asbd.mFramesPerPacket),
            String(asbd.mBytesPerFrame),
            String(asbd.mChannelsPerFrame),
            String(asbd.mBitsPerChannel)
        ].joined(separator: ":")
    }

    private func startSyntheticCapture(width: Int, height: Int, framesPerSecond: Int) {
        let queue = DispatchQueue(label: "wireddisplay.sender.capture.synthetic")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1, framesPerSecond)

        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / interval))
        timer.setEventHandler { [weak self] in
            guard let self, self.isCapturing else { return }

            let isFirstFrame = self.forceNextKeyFrame
            self.forceNextKeyFrame = false

            let metadata = FrameMetadata(
                frameIndex: self.frameIndex,
                timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                width: width,
                height: height,
                isKeyFrame: isFirstFrame || self.frameIndex % UInt64(interval) == 0
            )

            let bytesPerRow = max(1, width * 4)
            let byteCount = bytesPerRow * height
            let rawBytes = Data(repeating: UInt8(self.frameIndex % 255), count: max(0, byteCount))
            self.onCapturedFrame?(
                CapturedFrame(
                    metadata: metadata,
                    rawData: rawBytes,
                    bytesPerRow: bytesPerRow,
                    pixelFormat: .bgra8
                )
            )
            self.frameIndex += 1
        }

        syntheticTimer = timer
        timer.resume()
    }
}

enum CaptureServiceError: Error, LocalizedError {
    case noDisplayAvailable
    case screenCapturePermissionDenied(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for capture"
        case .screenCapturePermissionDenied(let underlying):
            return "Screen capture failed – grant Screen Recording permission in System Settings > Privacy & Security. (\(underlying.localizedDescription))"
        }
    }
}
