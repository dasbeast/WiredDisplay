import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Capture pipeline using SCStream for continuous screen capture.
/// Can target a specific display (e.g. the virtual extended display).
final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isCapturing = false

    private var stream: SCStream?
    private var frameIndex: UInt64 = 0
    private let captureQueue = DispatchQueue(label: "wireddisplay.sender.capture", qos: .userInteractive)

    /// The CGDirectDisplayID to capture. If 0, captures the main display.
    var targetDisplayID: CGDirectDisplayID = 0

    var onCapturedFrame: ((CapturedFrame) -> Void)?
    var onError: ((Error) -> Void)?

    func startCapture(width: Int, height: Int, framesPerSecond: Int = 30) {
        stopCapture()

        isCapturing = true
        frameIndex = 0

        if NetworkProtocol.forceSyntheticCaptureForDiagnostics {
            startSyntheticCapture(width: width, height: height, framesPerSecond: framesPerSecond)
            return
        }

        Task {
            do {
                try await startSCStream(width: width, height: height, framesPerSecond: framesPerSecond)
            } catch {
                print("[CaptureService] SCStream failed: \(error). Falling back to synthetic capture.")
                onError?(CaptureServiceError.screenCapturePermissionDenied(underlying: error))
                startSyntheticCapture(width: width, height: height, framesPerSecond: framesPerSecond)
            }
        }
    }

    func stopCapture() {
        isCapturing = false

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

    private func startSCStream(width: Int, height: Int, framesPerSecond: Int) async throws {
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
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()

        self.stream = newStream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isCapturing, type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard frameWidth > 0, frameHeight > 0 else { return }

        let currentIndex = frameIndex
        frameIndex += 1

        let metadata = FrameMetadata(
            frameIndex: currentIndex,
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            width: frameWidth,
            height: frameHeight,
            isKeyFrame: currentIndex % 60 == 0
        )

        // Pass CVPixelBuffer directly to avoid expensive copy for H.264 encoding
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let frame = CapturedFrame(
            metadata: metadata,
            rawData: Data(),
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8,
            pixelBuffer: pixelBuffer
        )
        onCapturedFrame?(frame)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        onError?(error)
    }

    // MARK: - Synthetic Fallback

    private var syntheticTimer: DispatchSourceTimer?

    private func startSyntheticCapture(width: Int, height: Int, framesPerSecond: Int) {
        let queue = DispatchQueue(label: "wireddisplay.sender.capture.synthetic")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1, framesPerSecond)

        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / interval))
        timer.setEventHandler { [weak self] in
            guard let self, self.isCapturing else { return }

            let metadata = FrameMetadata(
                frameIndex: self.frameIndex,
                timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                width: width,
                height: height,
                isKeyFrame: self.frameIndex % UInt64(interval) == 0
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
