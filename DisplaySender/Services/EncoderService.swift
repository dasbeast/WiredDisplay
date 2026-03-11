import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// VideoToolbox encoder — HEVC (H.265) primary with raw BGRA diagnostic fallback.
final class EncoderService {
    private var compressionSession: VTCompressionSession?
    private var configuredWidth = 0
    private var configuredHeight = 0
    private var encodedFrameCount: UInt64 = 0
    private var currentTargetBitrateBps: Int = NetworkProtocol.targetVideoBitrateBps
    /// Cached VPS/SPS/PPS from the last HEVC key frame so we can send them with every frame.
    private var lastVPS: Data?
    private var lastSPS: Data?
    private var lastPPS: Data?

    deinit {
        invalidateSession()
    }

    func encode(frame: CapturedFrame) -> EncodedFrame? {
        if NetworkProtocol.preferRawFrameTransportForDiagnostics {
            return makeRawEncodedFrame(from: frame)
        }

        do {
            let pixelBuffer: CVPixelBuffer
            if let pb = frame.pixelBuffer {
                // Use the CVPixelBuffer directly from SCStream — no copy needed
                pixelBuffer = pb
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

        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H265,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttributes as CFDictionary,
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

        // HEVC encoder configuration for near-retina quality over Thunderbolt.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        // Quality 0.97: perceptually lossless for UI/text. HEVC hardware encoder on Apple Silicon handles this easily.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.97 as CFNumber)
        // MinFrameDelayCount = 0 minimizes encode-side latency — important for interactive display.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        let bitrate = NSNumber(value: currentTargetBitrateBps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate)
        // Permit short bursts for keyframes while keeping average bitrate bounded.
        let dataRateBytesPerSecond = NSNumber(value: max(1, (currentTargetBitrateBps * 2) / 8))
        let dataRateWindowSeconds = NSNumber(value: 1)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [dataRateBytesPerSecond, dataRateWindowSeconds] as CFArray
        )

        let fps = NetworkProtocol.targetFramesPerSecond as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps)
        let keyFrameInterval = (NetworkProtocol.targetFramesPerSecond * NetworkProtocol.keyFrameIntervalSeconds) as CFNumber
        let keyFrameIntervalDuration = NetworkProtocol.keyFrameIntervalSeconds as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyFrameIntervalDuration)

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
        let forceKeyFrame = encodedFrameCount == 0 || encodedFrameCount % keyFrameInterval == 0
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

        let waitResult = callbackContext.semaphore.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            throw EncoderServiceError.encodeTimedOut
        }
        if let callbackError = callbackContext.error {
            throw callbackError
        }

        if var output = callbackContext.output {
            encodedFrameCount += 1

            // Cache VPS/SPS/PPS from HEVC key frames
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

    var vpsData: Data?
    var spsData: Data?
    var ppsData: Data?

    if isKeyFrame, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
        var paramCount = 0
        var nalLength: Int32 = 0

        // HEVC has 3 parameter sets: index 0 = VPS, 1 = SPS, 2 = PPS
        func extractHEVCParameterSet(at index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &paramCount,
                nalUnitHeaderLengthOut: &nalLength
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            return Data(bytes: pointer, count: size)
        }

        vpsData = extractHEVCParameterSet(at: 0)
        spsData = extractHEVCParameterSet(at: 1)
        ppsData = extractHEVCParameterSet(at: 2)
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
