import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// VideoToolbox HEVC (H.265) encoder for Sidecar-quality display streaming with raw fallback.
final class EncoderService {
    private var compressionSession: VTCompressionSession?
    private var configuredWidth = 0
    private var configuredHeight = 0
    private var encodedFrameCount: UInt64 = 0
    private var currentTargetBitrateBps: Int = NetworkProtocol.targetVideoBitrateBps
    private let stateLock = NSLock()
    private var forceNextKeyFrame = false
    /// Cached VPS/SPS/PPS from the last key frame so we can send them with every frame.
    private var lastVPS: Data?
    private var lastSPS: Data?
    private var lastPPS: Data?

    deinit {
        invalidateSession()
    }

    func requestKeyFrame() {
        stateLock.lock()
        forceNextKeyFrame = true
        stateLock.unlock()
    }

    func encode(frame: CapturedFrame) -> EncodedFrame? {
        if NetworkProtocol.preferRawFrameTransportForDiagnostics {
            return makeRawEncodedFrame(from: frame)
        }

        do {
            let pixelBuffer: CVPixelBuffer
            if let pb = frame.pixelBuffer {
                // Make an owned copy before handing the buffer to the asynchronous encoder.
                pixelBuffer = try makePixelBufferCopy(from: pb)
            } else {
                // Fallback: reconstruct pixel buffer from raw data (synthetic frames)
                pixelBuffer = try makePixelBuffer(from: frame)
            }
            try configureSessionIfNeeded(width: frame.metadata.width, height: frame.metadata.height)
            if let encoded = try encodeWithVideoToolbox(pixelBuffer: pixelBuffer, frame: frame) {
                print("[EncoderService] HEVC encoded frame \(frame.metadata.frameIndex): \(encoded.payload.count) bytes, keyFrame=\(encoded.isKeyFrame)")
                return encoded
            }
            print("[EncoderService] Dropping frame \(frame.metadata.frameIndex): HEVC encode produced no output in time")
        } catch {
            print("[EncoderService] Dropping frame \(frame.metadata.frameIndex): HEVC encode failed: \(error)")
        }
        return nil
    }

    private func makeRawEncodedFrame(from frame: CapturedFrame) -> EncodedFrame {
        // Extract raw data from the pixel buffer if rawData is empty
        let rawData: Data
        let bytesPerRow: Int
        if !frame.rawData.isEmpty {
            rawData = frame.rawData
            bytesPerRow = frame.bytesPerRow
        } else if let pb = frame.pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let height = CVPixelBufferGetHeight(pb)
                rawData = Data(bytes: base, count: bpr * height)
                bytesPerRow = bpr
            } else {
                rawData = frame.rawData
                bytesPerRow = frame.bytesPerRow
            }
        } else {
            rawData = frame.rawData
            bytesPerRow = frame.bytesPerRow
        }

        return EncodedFrame(
            metadata: frame.metadata,
            codec: .rawBGRA,
            payload: rawData,
            isKeyFrame: frame.metadata.isKeyFrame,
            sourceBytesPerRow: bytesPerRow,
            sourcePixelFormat: frame.pixelFormat,
            targetBitrateKbps: currentTargetBitrateBps / 1_000,
            targetFramesPerSecond: NetworkProtocol.targetFramesPerSecond,
            h264SPS: nil,
            h264PPS: nil
        )
    }

    private func configureSessionIfNeeded(width: Int, height: Int) throws {
        guard compressionSession == nil || width != configuredWidth || height != configuredHeight else {
            return
        }

        invalidateSession()

        // Require hardware-accelerated HEVC encoder (Apple Silicon / T2 chip).
        let encoderSpec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true as CFBoolean,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true as CFBoolean
        ] as CFDictionary

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: nil,
            compressionSessionOut: &newSession
        )

        guard status == noErr, let session = newSession else {
            throw EncoderServiceError.compressionSessionCreationFailed(status)
        }

        configuredWidth = width
        configuredHeight = height
        compressionSession = session

        currentTargetBitrateBps = NetworkProtocol.recommendedVideoBitrateBps(
            width: width,
            height: height,
            fps: NetworkProtocol.targetFramesPerSecond
        )

        // --- Sidecar-quality HEVC session configuration ---

        // Real-time encoding: prioritize latency over compression efficiency.
        setCompressionProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, label: "RealTime")

        // No B-frames: the single biggest latency saver — decoder doesn't wait for future frames.
        setCompressionProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse, label: "AllowFrameReordering")

        // HEVC Main profile for hardware decode compatibility.
        setCompressionProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel, label: "ProfileLevel")

        // Bitrate: generous target for Thunderbolt bandwidth.
        let bitrate = NSNumber(value: currentTargetBitrateBps)
        setCompressionProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate, label: "AverageBitRate")

        // DataRateLimits: allow 100 Mbps bursts over 1-second windows for fast motion / scene changes.
        // Format: [bytes-per-period, period-in-seconds] — 12_500_000 bytes = 100 Mbps.
        let dataRateLimits: [NSNumber] = [12_500_000 as NSNumber, 1.0 as NSNumber]
        setCompressionProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray, label: "DataRateLimits")

        // Frame rate hint for rate control.
        let fps = NetworkProtocol.targetFramesPerSecond as CFNumber
        setCompressionProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps, label: "ExpectedFrameRate")

        // Short key frame interval for fast recovery if a frame is dropped.
        let keyFrameInterval = (NetworkProtocol.targetFramesPerSecond * NetworkProtocol.keyFrameIntervalSeconds) as CFNumber
        let keyFrameIntervalDuration = NetworkProtocol.keyFrameIntervalSeconds as CFNumber
        setCompressionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval, label: "MaxKeyFrameInterval")
        setCompressionProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: keyFrameIntervalDuration,
            label: "MaxKeyFrameIntervalDuration"
        )

        // Preserve source color space (Rec. 709 / Display P3) so colors aren't washed out.
        setCompressionProperty(
            session,
            key: kVTCompressionPropertyKey_ColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2,
            label: "ColorPrimaries"
        )
        setCompressionProperty(
            session,
            key: kVTCompressionPropertyKey_TransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2,
            label: "TransferFunction"
        )
        setCompressionProperty(
            session,
            key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            label: "YCbCrMatrix"
        )

        // Quality: near-lossless for UI / text content.
        setCompressionProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.97 as CFNumber, label: "Quality")

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func invalidateSession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        configuredWidth = 0
        configuredHeight = 0
        encodedFrameCount = 0
        lastVPS = nil
        lastSPS = nil
        lastPPS = nil
    }

    private func makePixelBuffer(from frame: CapturedFrame) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.metadata.width,
            frame.metadata.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw EncoderServiceError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw EncoderServiceError.pixelBufferBaseAddressUnavailable
        }

        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowCount = frame.metadata.height
        frame.rawData.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            for row in 0..<rowCount {
                let srcOffset = row * frame.bytesPerRow
                let dstOffset = row * destinationBytesPerRow
                let srcPtr = srcBase.advanced(by: srcOffset)
                let dstPtr = baseAddress.advanced(by: dstOffset)
                memcpy(dstPtr, srcPtr, min(frame.bytesPerRow, destinationBytesPerRow))
            }
        }

        return pixelBuffer
    }

    private func makePixelBufferCopy(from source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw EncoderServiceError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
              let destinationBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw EncoderServiceError.pixelBufferBaseAddressUnavailable
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            let sourceOffset = row * sourceBytesPerRow
            let destinationOffset = row * destinationBytesPerRow
            let sourcePointer = sourceBaseAddress.advanced(by: sourceOffset)
            let destinationPointer = destinationBaseAddress.advanced(by: destinationOffset)
            memcpy(destinationPointer, sourcePointer, min(sourceBytesPerRow, destinationBytesPerRow))
        }

        return pixelBuffer
    }

    private func encodeWithVideoToolbox(pixelBuffer: CVPixelBuffer, frame: CapturedFrame) throws -> EncodedFrame? {
        guard let session = compressionSession else { return nil }

        let callbackContext = EncoderCallbackContext(
            frame: frame,
            targetBitrateKbps: max(1, currentTargetBitrateBps / 1_000)
        )
        let refcon = Unmanaged.passRetained(callbackContext).toOpaque()

        var flags = VTEncodeInfoFlags()
        let timescale = CMTimeScale(max(1, NetworkProtocol.targetFramesPerSecond))
        let pts = CMTime(value: Int64(frame.metadata.frameIndex), timescale: timescale)
        let duration = CMTime(value: 1, timescale: timescale)

        // Force key frame on first frame and every keyFrameIntervalSeconds
        let keyFrameInterval = UInt64(NetworkProtocol.targetFramesPerSecond * NetworkProtocol.keyFrameIntervalSeconds)
        let forceKeyFrame = consumeForcedKeyFrame() || encodedFrameCount == 0 || encodedFrameCount % keyFrameInterval == 0
        let frameProps: CFDictionary? = forceKeyFrame ? [
            kVTEncodeFrameOptionKey_ForceKeyFrame: true as CFBoolean
        ] as CFDictionary : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: refcon,
            infoFlagsOut: &flags
        )

        guard status == noErr else {
            Unmanaged<EncoderCallbackContext>.fromOpaque(refcon).release()
            throw EncoderServiceError.encodeFailed(status)
        }

        var waitResult = callbackContext.semaphore.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            let completeStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            if completeStatus != noErr {
                print("[EncoderService] CompleteFrames failed at \(frame.metadata.frameIndex): \(completeStatus)")
            }
            waitResult = callbackContext.semaphore.wait(timeout: .now() + 0.5)
        }
        if waitResult == .timedOut {
            throw EncoderServiceError.encodeTimedOut
        }
        if let callbackError = callbackContext.error {
            throw callbackError
        }

        if var output = callbackContext.output {
            encodedFrameCount += 1

            // Cache VPS/SPS/PPS from key frames
            if output.hevcVPS != nil { lastVPS = output.hevcVPS }
            if output.h264SPS != nil { lastSPS = output.h264SPS }
            if output.h264PPS != nil { lastPPS = output.h264PPS }

            // Always attach cached VPS/SPS/PPS so the decoder can initialize at any point
            if output.hevcVPS == nil || output.h264SPS == nil || output.h264PPS == nil {
                output = EncodedFrame(
                    metadata: output.metadata,
                    codec: output.codec,
                    payload: output.payload,
                    isKeyFrame: output.isKeyFrame,
                    sourceBytesPerRow: output.sourceBytesPerRow,
                    sourcePixelFormat: output.sourcePixelFormat,
                    targetBitrateKbps: output.targetBitrateKbps,
                    targetFramesPerSecond: output.targetFramesPerSecond,
                    h264SPS: lastSPS,
                    h264PPS: lastPPS,
                    hevcVPS: lastVPS
                )
            }

            return output
        }

        return nil
    }

    private func consumeForcedKeyFrame() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let shouldForce = forceNextKeyFrame
        forceNextKeyFrame = false
        return shouldForce
    }

    @discardableResult
    private func setCompressionProperty(
        _ session: VTSession,
        key: CFString,
        value: CFTypeRef,
        label: String
    ) -> OSStatus {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status != noErr else { return status }

        print(
            "[EncoderService] Compression property \(label) unsupported/failed " +
            "at \(configuredWidth)x\(configuredHeight): \(status)"
        )
        return status
    }
}

private final class EncoderCallbackContext {
    let frame: CapturedFrame
    let targetBitrateKbps: Int
    let semaphore = DispatchSemaphore(value: 0)
    var output: EncodedFrame?
    var error: Error?

    init(frame: CapturedFrame, targetBitrateKbps: Int) {
        self.frame = frame
        self.targetBitrateKbps = targetBitrateKbps
    }
}

private let encoderOutputCallback: VTCompressionOutputCallback = { _, sourceFrameRefcon, status, _, sampleBuffer in
    guard let sourceFrameRefcon else { return }
    let context = Unmanaged<EncoderCallbackContext>.fromOpaque(sourceFrameRefcon).takeRetainedValue()

    defer {
        context.semaphore.signal()
    }

    guard status == noErr else {
        context.error = EncoderServiceError.encodeFailed(status)
        return
    }

    guard let sampleBuffer, sampleBuffer.isValid else {
        context.error = EncoderServiceError.invalidSampleBuffer
        return
    }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        context.error = EncoderServiceError.missingBlockBuffer
        return
    }

    let payloadLength = CMBlockBufferGetDataLength(blockBuffer)
    guard payloadLength > 0 else {
        context.error = EncoderServiceError.emptyEncodedPayload
        return
    }

    var payload = Data(count: payloadLength)
    let copyStatus = payload.withUnsafeMutableBytes { destinationBytes -> OSStatus in
        guard let destinationBase = destinationBytes.baseAddress else {
            return kCMBlockBufferBadCustomBlockSourceErr
        }
        return CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: payloadLength,
            destination: destinationBase
        )
    }

    guard copyStatus == kCMBlockBufferNoErr else {
        context.error = EncoderServiceError.blockBufferReadFailed(copyStatus)
        return
    }

    let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let firstAttachment = attachmentsArray?.first
    let notSync = firstAttachment?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    let isKeyFrame = !notSync

    // HEVC parameter sets: VPS (index 0), SPS (index 1), PPS (index 2)
    var vpsData: Data?
    var spsData: Data?
    var ppsData: Data?

    if isKeyFrame, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
        var paramPointer: UnsafePointer<UInt8>?
        var paramSize = 0
        var paramCount = 0
        var nalLength: Int32 = 0

        // VPS — index 0
        let vpsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &paramPointer,
            parameterSetSizeOut: &paramSize,
            parameterSetCountOut: &paramCount,
            nalUnitHeaderLengthOut: &nalLength
        )
        if vpsStatus == noErr, let ptr = paramPointer {
            vpsData = Data(bytes: ptr, count: paramSize)
        }

        // SPS — index 1
        let spsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &paramPointer,
            parameterSetSizeOut: &paramSize,
            parameterSetCountOut: &paramCount,
            nalUnitHeaderLengthOut: &nalLength
        )
        if spsStatus == noErr, let ptr = paramPointer {
            spsData = Data(bytes: ptr, count: paramSize)
        }

        // PPS — index 2
        let ppsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 2,
            parameterSetPointerOut: &paramPointer,
            parameterSetSizeOut: &paramSize,
            parameterSetCountOut: &paramCount,
            nalUnitHeaderLengthOut: &nalLength
        )
        if ppsStatus == noErr, let ptr = paramPointer {
            ppsData = Data(bytes: ptr, count: paramSize)
        }
    }

    context.output = EncodedFrame(
        metadata: context.frame.metadata,
        codec: .hevcAVCC,
        payload: payload,
        isKeyFrame: isKeyFrame,
        sourceBytesPerRow: context.frame.bytesPerRow,
        sourcePixelFormat: context.frame.pixelFormat,
        targetBitrateKbps: context.targetBitrateKbps,
        targetFramesPerSecond: NetworkProtocol.targetFramesPerSecond,
        h264SPS: spsData,
        h264PPS: ppsData,
        hevcVPS: vpsData
    )
}

enum EncoderServiceError: Error {
    case compressionSessionCreationFailed(OSStatus)
    case pixelBufferCreationFailed
    case pixelBufferBaseAddressUnavailable
    case encodeFailed(OSStatus)
    case invalidSampleBuffer
    case missingBlockBuffer
    case blockBufferReadFailed(OSStatus)
    case emptyEncodedPayload
    case encodeTimedOut
}
