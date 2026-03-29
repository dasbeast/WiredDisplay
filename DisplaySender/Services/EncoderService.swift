import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// VideoToolbox HEVC (H.265) encoder for Sidecar-quality display streaming with raw fallback.
final class EncoderService {
    private struct EncodeRequest {
        let forceKeyFrame: Bool
        let targetBitrateKbps: Int
        let streamFrameIndex: UInt64
    }

    private var compressionSession: VTCompressionSession?
    private var configuredWidth = 0
    private var configuredHeight = 0
    private var submittedFrameCount: UInt64 = 0
    private var encodedFrameCount: UInt64 = 0
    private var currentTargetBitrateBps: Int = NetworkProtocol.targetVideoBitrateBps
    private let stateLock = NSLock()
    private var forceNextKeyFrame = false
    private var framesInFlight = 0
    private let maxFramesInFlight = 2
    private var preferredKeyFrameIntervalFrames = max(
        1,
        NetworkProtocol.targetFramesPerSecond * NetworkProtocol.keyFrameIntervalSeconds
    )
    /// Cached VPS/SPS/PPS from the last key frame so we can send them with every frame.
    private var lastVPS: Data?
    private var lastSPS: Data?
    private var lastPPS: Data?

    var onEncodedFrame: ((EncodedFrame) -> Void)?
    var onError: ((Error) -> Void)?

    deinit {
        invalidateSession()
    }

    func requestKeyFrame() {
        stateLock.lock()
        forceNextKeyFrame = true
        stateLock.unlock()
    }

    func setPreferredKeyFrameIntervalFrames(_ frameCount: Int) {
        let normalizedFrameCount = max(1, frameCount)

        stateLock.lock()
        preferredKeyFrameIntervalFrames = normalizedFrameCount
        stateLock.unlock()

        if let compressionSession {
            let intervalNumber = NSNumber(value: normalizedFrameCount)
            let seconds = Double(normalizedFrameCount) / Double(max(1, NetworkProtocol.targetFramesPerSecond))
            setCompressionProperty(
                compressionSession,
                key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: intervalNumber,
                label: "MaxKeyFrameInterval"
            )
            setCompressionProperty(
                compressionSession,
                key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                value: NSNumber(value: seconds),
                label: "MaxKeyFrameIntervalDuration"
            )
        }
    }

    @discardableResult
    func encode(frame: CapturedFrame) -> Bool {
        do {
            if NetworkProtocol.preferRawFrameTransportForDiagnostics {
                let request = try beginEncodeRequest()
                let encodedFrame = finishEncodeRequest(with: makeRawEncodedFrame(from: frame, request: request))
                onEncodedFrame?(encodedFrame)
                return true
            }

            try configureSessionIfNeeded(width: frame.metadata.width, height: frame.metadata.height)
            let request = try beginEncodeRequest()
            let pixelBuffer = try makeInputPixelBuffer(from: frame)
            try encodeWithVideoToolbox(
                pixelBuffer: pixelBuffer,
                frame: frame,
                request: request
            )
            return true
        } catch EncoderServiceError.tooManyFramesInFlight {
            return false
        } catch {
            onError?(error)
            return false
        }
    }

    private func makeInputPixelBuffer(from frame: CapturedFrame) throws -> CVPixelBuffer {
        if let pixelBuffer = frame.pixelBuffer {
            return pixelBuffer
        }

        return try makePixelBuffer(from: frame)
    }

    private func makeRawEncodedFrame(from frame: CapturedFrame, request: EncodeRequest) -> EncodedFrame {
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

        let metadata = makeStreamMetadata(
            from: frame,
            streamFrameIndex: request.streamFrameIndex,
            isKeyFrame: request.forceKeyFrame
        )

        return EncodedFrame(
            metadata: metadata,
            codec: .rawBGRA,
            payload: rawData,
            isKeyFrame: metadata.isKeyFrame,
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

        guard currentFramesInFlight() == 0 else {
            throw EncoderServiceError.reconfigurationWhileEncoding
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
            outputCallback: nil,
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

        // Force 1-in-1-out: zero encoder lookahead so every submitted frame is emitted immediately.
        setCompressionProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0), label: "MaxFrameDelayCount")

        // HEVC Main profile for hardware decode compatibility.
        setCompressionProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel, label: "ProfileLevel")

        // Bitrate: generous target for Thunderbolt bandwidth.
        let bitrate = NSNumber(value: currentTargetBitrateBps)
        setCompressionProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate, label: "AverageBitRate")

        // Frame rate hint for rate control.
        let fps = NetworkProtocol.targetFramesPerSecond as CFNumber
        setCompressionProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps, label: "ExpectedFrameRate")

        // Short key frame interval for fast recovery if a frame is dropped.
        let configuredKeyFrameIntervalFrames = currentPreferredKeyFrameIntervalFrames()
        let keyFrameInterval = configuredKeyFrameIntervalFrames as CFNumber
        let keyFrameIntervalDuration = (
            Double(configuredKeyFrameIntervalFrames) / Double(max(1, NetworkProtocol.targetFramesPerSecond))
        ) as CFNumber
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

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func invalidateSession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        configuredWidth = 0
        configuredHeight = 0
        submittedFrameCount = 0
        encodedFrameCount = 0
        currentTargetBitrateBps = NetworkProtocol.targetVideoBitrateBps
        stateLock.lock()
        framesInFlight = 0
        forceNextKeyFrame = false
        stateLock.unlock()
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

    private func beginEncodeRequest() throws -> EncodeRequest {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard framesInFlight < maxFramesInFlight else {
            throw EncoderServiceError.tooManyFramesInFlight
        }

        // Stream sequence numbers must only advance for frames the encoder actually accepts.
        // If capture-time indices are used here, overload drops create holes that the receiver
        // treats as missing compressed references and it stalls until a later keyframe arrives.
        let streamFrameIndex = submittedFrameCount
        let keyFrameInterval = UInt64(max(1, preferredKeyFrameIntervalFrames))
        let forceKeyFrame = forceNextKeyFrame
            || streamFrameIndex == 0
            || streamFrameIndex % keyFrameInterval == 0

        forceNextKeyFrame = false
        submittedFrameCount += 1
        framesInFlight += 1

        return EncodeRequest(
            forceKeyFrame: forceKeyFrame,
            targetBitrateKbps: max(1, currentTargetBitrateBps / 1_000),
            streamFrameIndex: streamFrameIndex
        )
    }

    private func currentPreferredKeyFrameIntervalFrames() -> Int {
        stateLock.lock()
        let currentValue = preferredKeyFrameIntervalFrames
        stateLock.unlock()
        return currentValue
    }

    private func encodeWithVideoToolbox(
        pixelBuffer: CVPixelBuffer,
        frame: CapturedFrame,
        request: EncodeRequest
    ) throws {
        guard let session = compressionSession else { return }

        var flags = VTEncodeInfoFlags()
        let timescale = CMTimeScale(max(1, NetworkProtocol.targetFramesPerSecond))
        let pts = CMTime(value: Int64(request.streamFrameIndex), timescale: timescale)
        let duration = CMTime(value: 1, timescale: timescale)

        let frameProps: CFDictionary? = request.forceKeyFrame ? [
            kVTEncodeFrameOptionKey_ForceKeyFrame: true as CFBoolean
        ] as CFDictionary : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProps,
            infoFlagsOut: &flags
        ) { [weak self] status, _, sampleBuffer in
            self?.handleEncodedSample(
                status: status,
                sampleBuffer: sampleBuffer,
                frame: frame,
                request: request
            )
        }

        guard status == noErr else {
            finishEncodeRequestWithoutOutput()
            throw EncoderServiceError.encodeFailed(status)
        }
    }

    private func handleEncodedSample(
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?,
        frame: CapturedFrame,
        request: EncodeRequest
    ) {
        guard status == noErr else {
            finishEncodeRequestWithoutOutput()
            onError?(EncoderServiceError.encodeFailed(status))
            return
        }

        guard let sampleBuffer, sampleBuffer.isValid else {
            finishEncodeRequestWithoutOutput()
            return
        }

        do {
            let encodedFrame = try makeEncodedFrame(
                from: sampleBuffer,
                frame: frame,
                request: request
            )

            let finalizedFrame = finishEncodeRequest(with: encodedFrame)
            if finalizedFrame.metadata.frameIndex % 30 == 0 {
                print(
                    "[EncoderService] HEVC encoded frame \(finalizedFrame.metadata.frameIndex): " +
                    "\(finalizedFrame.payload.count) bytes, keyFrame=\(finalizedFrame.isKeyFrame)"
                )
            }
            onEncodedFrame?(finalizedFrame)
        } catch {
            finishEncodeRequestWithoutOutput()
            onError?(error)
        }
    }

    private func makeEncodedFrame(
        from sampleBuffer: CMSampleBuffer,
        frame: CapturedFrame,
        request: EncodeRequest
    ) throws -> EncodedFrame {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw EncoderServiceError.missingBlockBuffer
        }

        let payloadLength = CMBlockBufferGetDataLength(blockBuffer)
        guard payloadLength > 0 else {
            throw EncoderServiceError.emptyEncodedPayload
        }

        let payload = try makeEncodedPayloadData(
            sampleBuffer: sampleBuffer,
            blockBuffer: blockBuffer,
            payloadLength: payloadLength
        )

        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let firstAttachment = attachmentsArray?.first
        let notSync = firstAttachment?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyFrame = !notSync
        let metadata = makeStreamMetadata(
            from: frame,
            streamFrameIndex: request.streamFrameIndex,
            isKeyFrame: isKeyFrame
        )

        // HEVC parameter sets: VPS (index 0), SPS (index 1), PPS (index 2)
        // Extract from every frame — the hardware encoder may update parameter sets mid-stream
        // (especially with EnableLowLatencyRateControl).
        var vpsData: Data?
        var spsData: Data?
        var ppsData: Data?

        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
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

        return EncodedFrame(
            metadata: metadata,
            codec: .hevcAVCC,
            payload: payload,
            isKeyFrame: isKeyFrame,
            sourceBytesPerRow: frame.bytesPerRow,
            sourcePixelFormat: frame.pixelFormat,
            targetBitrateKbps: request.targetBitrateKbps,
            targetFramesPerSecond: NetworkProtocol.targetFramesPerSecond,
            h264SPS: spsData,
            h264PPS: ppsData,
            hevcVPS: vpsData
        )
    }

    private func makeStreamMetadata(
        from frame: CapturedFrame,
        streamFrameIndex: UInt64,
        isKeyFrame: Bool
    ) -> FrameMetadata {
        FrameMetadata(
            frameIndex: streamFrameIndex,
            timestampNanoseconds: frame.metadata.timestampNanoseconds,
            width: frame.metadata.width,
            height: frame.metadata.height,
            isKeyFrame: isKeyFrame
        )
    }

    private func makeEncodedPayloadData(
        sampleBuffer: CMSampleBuffer,
        blockBuffer: CMBlockBuffer,
        payloadLength: Int
    ) throws -> Data {
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        if pointerStatus == kCMBlockBufferNoErr,
           totalLength == payloadLength,
           let dataPointer {
            let retainedSampleBuffer = sampleBuffer
            return Data(
                bytesNoCopy: UnsafeMutableRawPointer(dataPointer),
                count: payloadLength,
                deallocator: .custom { _, _ in
                    _ = retainedSampleBuffer
                }
            )
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
            throw EncoderServiceError.blockBufferReadFailed(copyStatus)
        }

        return payload
    }

    private func finishEncodeRequest(with encodedFrame: EncodedFrame) -> EncodedFrame {
        stateLock.lock()
        defer { stateLock.unlock() }

        framesInFlight = max(0, framesInFlight - 1)
        encodedFrameCount += 1

        let finalizedMetadata = FrameMetadata(
            frameIndex: encodedFrame.metadata.frameIndex,
            timestampNanoseconds: encodedFrame.metadata.timestampNanoseconds,
            encodeCompleteTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            width: encodedFrame.metadata.width,
            height: encodedFrame.metadata.height,
            isKeyFrame: encodedFrame.metadata.isKeyFrame
        )

        if encodedFrame.hevcVPS != nil { lastVPS = encodedFrame.hevcVPS }
        if encodedFrame.h264SPS != nil { lastSPS = encodedFrame.h264SPS }
        if encodedFrame.h264PPS != nil { lastPPS = encodedFrame.h264PPS }

        if encodedFrame.hevcVPS != nil, encodedFrame.h264SPS != nil, encodedFrame.h264PPS != nil {
            return EncodedFrame(
                metadata: finalizedMetadata,
                codec: encodedFrame.codec,
                payload: encodedFrame.payload,
                isKeyFrame: encodedFrame.isKeyFrame,
                sourceBytesPerRow: encodedFrame.sourceBytesPerRow,
                sourcePixelFormat: encodedFrame.sourcePixelFormat,
                targetBitrateKbps: encodedFrame.targetBitrateKbps,
                targetFramesPerSecond: encodedFrame.targetFramesPerSecond,
                h264SPS: encodedFrame.h264SPS,
                h264PPS: encodedFrame.h264PPS,
                hevcVPS: encodedFrame.hevcVPS
            )
        }

        return EncodedFrame(
            metadata: finalizedMetadata,
            codec: encodedFrame.codec,
            payload: encodedFrame.payload,
            isKeyFrame: encodedFrame.isKeyFrame,
            sourceBytesPerRow: encodedFrame.sourceBytesPerRow,
            sourcePixelFormat: encodedFrame.sourcePixelFormat,
            targetBitrateKbps: encodedFrame.targetBitrateKbps,
            targetFramesPerSecond: encodedFrame.targetFramesPerSecond,
            h264SPS: encodedFrame.h264SPS ?? lastSPS,
            h264PPS: encodedFrame.h264PPS ?? lastPPS,
            hevcVPS: encodedFrame.hevcVPS ?? lastVPS
        )
    }

    private func finishEncodeRequestWithoutOutput() {
        stateLock.lock()
        framesInFlight = max(0, framesInFlight - 1)
        stateLock.unlock()
    }

    private func currentFramesInFlight() -> Int {
        stateLock.lock()
        let currentCount = framesInFlight
        stateLock.unlock()
        return currentCount
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

enum EncoderServiceError: Error {
    case compressionSessionCreationFailed(OSStatus)
    case pixelBufferCreationFailed
    case pixelBufferBaseAddressUnavailable
    case encodeFailed(OSStatus)
    case invalidSampleBuffer
    case missingBlockBuffer
    case blockBufferReadFailed(OSStatus)
    case emptyEncodedPayload
    case tooManyFramesInFlight
    case reconfigurationWhileEncoding
}
