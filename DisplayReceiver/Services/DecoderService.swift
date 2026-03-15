import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// VideoToolbox decoder — supports HEVC (H.265), H.264, and raw BGRA.
final class DecoderService {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var awaitingH264KeyFrame = false
    private var awaitingHEVCKeyFrame = false
    // Cached parameter sets for H.264 (SPS + PPS)
    private var cachedH264SPS: Data?
    private var cachedH264PPS: Data?
    // Cached parameter sets for HEVC (VPS + SPS + PPS)
    private var cachedHEVCVPS: Data?
    private var cachedHEVCSPS: Data?
    private var cachedHEVCPPS: Data?

    var onNeedsKeyFrame: ((FrameMetadata, VideoCodec) -> Void)?

    deinit {
        invalidateSession()
    }

    func decode(packet: VideoPacket) -> DecodedFrame {
        guard let encodedFrame = try? JSONDecoder().decode(EncodedFrame.self, from: packet.payload) else {
            return DecodedFrame(
                metadata: packet.metadata,
                pixelBuffer: nil,
                pixelData: packet.payload,
                bytesPerRow: max(1, packet.metadata.width * 4),
                pixelFormat: .bgra8
            )
        }

        return decodeEncodedFrame(encodedFrame)
    }

    /// Decodes an EncodedFrame directly (used by binary video frame path).
    func decodeEncodedFrame(_ encodedFrame: EncodedFrame) -> DecodedFrame {
        switch encodedFrame.codec {
        case .rawBGRA:
            return DecodedFrame(
                metadata: encodedFrame.metadata,
                pixelBuffer: nil,
                pixelData: encodedFrame.payload,
                bytesPerRow: encodedFrame.sourceBytesPerRow,
                pixelFormat: encodedFrame.sourcePixelFormat
            )

        case .h264AVCC:
            if awaitingH264KeyFrame && !encodedFrame.isKeyFrame {
                return DecodedFrame(
                    metadata: encodedFrame.metadata,
                    pixelBuffer: nil,
                    pixelData: nil,
                    bytesPerRow: 0,
                    pixelFormat: .bgra8
                )
            }
            do {
                try refreshH264SessionIfNeeded(from: encodedFrame)
                if let pixelBuffer = try decodeCompressedFrame(encodedFrame: encodedFrame) {
                    awaitingH264KeyFrame = false
                    return DecodedFrame(
                        metadata: encodedFrame.metadata,
                        pixelBuffer: pixelBuffer,
                        pixelData: nil,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        pixelFormat: .yuv420
                    )
                }
                print("[DecoderService] H.264 decode returned nil for frame \(encodedFrame.metadata.frameIndex)")
            } catch {
                awaitingH264KeyFrame = true
                invalidateSession()
                print("[DecoderService] H.264 decode failed for frame \(encodedFrame.metadata.frameIndex): \(error)")
                onNeedsKeyFrame?(encodedFrame.metadata, encodedFrame.codec)
            }

            return DecodedFrame(
                metadata: encodedFrame.metadata,
                pixelBuffer: nil,
                pixelData: nil,
                bytesPerRow: 0,
                pixelFormat: encodedFrame.sourcePixelFormat
            )

        case .hevcAVCC:
            if awaitingHEVCKeyFrame && !encodedFrame.isKeyFrame {
                return DecodedFrame(
                    metadata: encodedFrame.metadata,
                    pixelBuffer: nil,
                    pixelData: nil,
                    bytesPerRow: 0,
                    pixelFormat: .bgra8
                )
            }
            do {
                try refreshHEVCSessionIfNeeded(from: encodedFrame)
                if let pixelBuffer = try decodeCompressedFrame(encodedFrame: encodedFrame) {
                    awaitingHEVCKeyFrame = false
                    return DecodedFrame(
                        metadata: encodedFrame.metadata,
                        pixelBuffer: pixelBuffer,
                        pixelData: nil,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        pixelFormat: .yuv420
                    )
                }
                print("[DecoderService] HEVC decode returned nil for frame \(encodedFrame.metadata.frameIndex)")
            } catch {
                awaitingHEVCKeyFrame = true
                invalidateSession()
                print("[DecoderService] HEVC decode failed for frame \(encodedFrame.metadata.frameIndex): \(error)")
                onNeedsKeyFrame?(encodedFrame.metadata, encodedFrame.codec)
            }

            return DecodedFrame(
                metadata: encodedFrame.metadata,
                pixelBuffer: nil,
                pixelData: nil,
                bytesPerRow: 0,
                pixelFormat: encodedFrame.sourcePixelFormat
            )
        }
    }

    /// Rebuilds the H.264 decompression session when SPS/PPS change.
    private func refreshH264SessionIfNeeded(from frame: EncodedFrame) throws {
        guard let sps = frame.h264SPS, let pps = frame.h264PPS else {
            if decompressionSession == nil || formatDescription == nil {
                throw DecoderServiceError.parameterSetUnavailable
            }
            return
        }

        let shouldRebuild: Bool
        if let cachedH264SPS, let cachedH264PPS {
            shouldRebuild = cachedH264SPS != sps || cachedH264PPS != pps || decompressionSession == nil || formatDescription == nil
        } else {
            shouldRebuild = true
        }

        guard shouldRebuild else { return }

        let parameterSetSizes = [sps.count, pps.count]
        var formatDescriptionOut: CMFormatDescription?
        let formatStatus: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.baseAddress, let ppsBase = ppsBytes.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescriptionOut
                )
            }
        }

        guard formatStatus == noErr, let validFormat = formatDescriptionOut else {
            throw DecoderServiceError.formatDescriptionCreationFailed(formatStatus)
        }

        try rebuildDecompressionSession(format: validFormat)
        cachedH264SPS = sps
        cachedH264PPS = pps
    }

    /// Rebuilds the HEVC decompression session when VPS/SPS/PPS change.
    private func refreshHEVCSessionIfNeeded(from frame: EncodedFrame) throws {
        guard let vps = frame.hevcVPS, let sps = frame.h264SPS, let pps = frame.h264PPS else {
            if decompressionSession == nil || formatDescription == nil {
                throw DecoderServiceError.parameterSetUnavailable
            }
            return
        }

        let shouldRebuild: Bool
        if let cachedHEVCVPS, let cachedHEVCSPS, let cachedHEVCPPS {
            shouldRebuild = cachedHEVCVPS != vps || cachedHEVCSPS != sps || cachedHEVCPPS != pps
                || decompressionSession == nil || formatDescription == nil
        } else {
            shouldRebuild = true
        }

        guard shouldRebuild else { return }

        let parameterSetSizes = [vps.count, sps.count, pps.count]
        var formatDescriptionOut: CMFormatDescription?
        let formatStatus: OSStatus = vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard let vpsBase = vpsBytes.baseAddress,
                          let spsBase = spsBytes.baseAddress,
                          let ppsBase = ppsBytes.baseAddress else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                    let pointers: [UnsafePointer<UInt8>] = [
                        vpsBase.assumingMemoryBound(to: UInt8.self),
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescriptionOut
                    )
                }
            }
        }

        guard formatStatus == noErr, let validFormat = formatDescriptionOut else {
            throw DecoderServiceError.formatDescriptionCreationFailed(formatStatus)
        }

        try rebuildDecompressionSession(format: validFormat)
        cachedHEVCVPS = vps
        cachedHEVCSPS = sps
        cachedHEVCPPS = pps
    }

    private func rebuildDecompressionSession(format: CMVideoFormatDescription) throws {
        invalidateSession()

        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decoderOutputCallback,
            decompressionOutputRefCon: nil
        )

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &sessionOut
        )

        guard status == noErr, let sessionOut else {
            throw DecoderServiceError.decompressionSessionCreationFailed(status)
        }

        // Signal real-time priority so VT minimizes decode latency.
        VTSessionSetProperty(sessionOut, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        formatDescription = format
        decompressionSession = sessionOut
    }

    private func invalidateSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        cachedH264SPS = nil
        cachedH264PPS = nil
        cachedHEVCVPS = nil
        cachedHEVCSPS = nil
        cachedHEVCPPS = nil
    }

    private func decodeCompressedFrame(encodedFrame: EncodedFrame) throws -> CVPixelBuffer? {
        guard let session = decompressionSession, let formatDescription else {
            throw DecoderServiceError.parameterSetUnavailable
        }

        let blockBuffer = try makeBlockBufferBackedByPayload(encodedFrame.payload)

        let frameRate = max(1, encodedFrame.targetFramesPerSecond)
        let timescale = CMTimeScale(frameRate)
        let presentationTimeStamp = CMTime(value: Int64(encodedFrame.metadata.frameIndex), timescale: timescale)
        let duration = CMTime(value: 1, timescale: timescale)

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid)
        var sampleSize = encodedFrame.payload.count

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            throw DecoderServiceError.sampleBufferCreationFailed(sampleStatus)
        }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            let notSync: CFBoolean = encodedFrame.isKeyFrame ? false as CFBoolean : true as CFBoolean
            let dependsOnOthers: CFBoolean = encodedFrame.isKeyFrame ? false as CFBoolean : true as CFBoolean
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(notSync).toOpaque()
            )
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                Unmanaged.passUnretained(dependsOnOthers).toOpaque()
            )
        }

        let context = DecoderCallbackContext()
        let refcon = Unmanaged.passRetained(context).toOpaque()

        var flagsOut = VTDecodeInfoFlags()
        let decodeFlags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
            ._1xRealTimePlayback
        ]

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: refcon,
            infoFlagsOut: &flagsOut
        )

        guard decodeStatus == noErr else {
            Unmanaged<DecoderCallbackContext>.fromOpaque(refcon).release()
            throw DecoderServiceError.decodeFailed(decodeStatus)
        }

        let waitResult = context.semaphore.wait(timeout: .now() + 0.05)
        if waitResult == .timedOut {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }

        if let error = context.error {
            throw error
        }

        if waitResult == .timedOut, context.pixelBuffer == nil {
            throw DecoderServiceError.decodeTimedOut
        }

        return context.pixelBuffer
    }

    private func makeBlockBufferBackedByPayload(_ payload: Data) throws -> CMBlockBuffer {
        let storage = DataBackedBlockBufferStorage(payload: payload)
        let retainedStorage = Unmanaged.passRetained(storage)

        var customBlockSource = CMBlockBufferCustomBlockSource()
        customBlockSource.version = UInt32(kCMBlockBufferCustomBlockSourceVersion)
        customBlockSource.AllocateBlock = nil
        customBlockSource.FreeBlock = releaseDataBackedBlockBuffer
        customBlockSource.refCon = retainedStorage.toOpaque()

        var blockBuffer: CMBlockBuffer?
        let createStatus = storage.payload.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }

            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: baseAddress),
                blockLength: payload.count,
                blockAllocator: nil,
                customBlockSource: &customBlockSource,
                offsetToData: 0,
                dataLength: payload.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            retainedStorage.release()
            throw DecoderServiceError.blockBufferCreationFailed(createStatus)
        }

        return blockBuffer
    }
}

private final class DecoderCallbackContext {
    let semaphore = DispatchSemaphore(value: 0)
    var pixelBuffer: CVPixelBuffer?
    var error: Error?
}

private final class DataBackedBlockBufferStorage {
    let payload: Data

    init(payload: Data) {
        self.payload = payload
    }
}

private func releaseDataBackedBlockBuffer(
    refCon: UnsafeMutableRawPointer?,
    doomedMemoryBlock _: UnsafeMutableRawPointer,
    sizeInBytes _: Int
) {
    guard let refCon else { return }
    Unmanaged<DataBackedBlockBufferStorage>.fromOpaque(refCon).release()
}

private let decoderOutputCallback: VTDecompressionOutputCallback = { _, sourceFrameRefCon, status, _, imageBuffer, _, _ in
    guard let sourceFrameRefCon else { return }
    let context = Unmanaged<DecoderCallbackContext>.fromOpaque(sourceFrameRefCon).takeRetainedValue()

    defer {
        context.semaphore.signal()
    }

    guard status == noErr else {
        context.error = DecoderServiceError.decodeFailed(status)
        return
    }

    if let imageBuffer {
        context.pixelBuffer = imageBuffer
    }
}

enum DecoderServiceError: Error {
    case parameterSetUnavailable
    case formatDescriptionCreationFailed(OSStatus)
    case decompressionSessionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case blockBufferWriteFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case decodeTimedOut
}
