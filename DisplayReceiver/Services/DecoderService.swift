import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// VideoToolbox decoder scaffold with raw fallback.
final class DecoderService {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var cachedSPS: Data?
    private var cachedPPS: Data?

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
            do {
                try refreshSessionIfNeeded(from: encodedFrame)
                if let pixelBuffer = try decodeH264(encodedFrame: encodedFrame) {
                    return DecodedFrame(
                        metadata: encodedFrame.metadata,
                        pixelBuffer: pixelBuffer,
                        pixelData: nil,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        pixelFormat: .bgra8
                    )
                }
                print("[DecoderService] H.264 decode returned nil for frame \(encodedFrame.metadata.frameIndex)")
            } catch {
                print("[DecoderService] H.264 decode failed for frame \(encodedFrame.metadata.frameIndex): \(error)")
            }

            return DecodedFrame(
                metadata: encodedFrame.metadata,
                pixelBuffer: nil,
                pixelData: encodedFrame.payload,
                bytesPerRow: encodedFrame.sourceBytesPerRow,
                pixelFormat: encodedFrame.sourcePixelFormat
            )
        }
    }

    private func refreshSessionIfNeeded(from frame: EncodedFrame) throws {
        guard let sps = frame.h264SPS, let pps = frame.h264PPS else {
            if decompressionSession == nil || formatDescription == nil {
                throw DecoderServiceError.parameterSetUnavailable
            }
            return
        }

        let shouldRebuild: Bool
        if let cachedSPS, let cachedPPS {
            shouldRebuild = cachedSPS != sps || cachedPPS != pps || decompressionSession == nil || formatDescription == nil
        } else {
            shouldRebuild = true
        }

        guard shouldRebuild else {
            return
        }

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

        cachedSPS = sps
        cachedPPS = pps
        formatDescription = validFormat
        try rebuildDecompressionSession(format: validFormat)
    }

    private func rebuildDecompressionSession(format: CMVideoFormatDescription) throws {
        invalidateSession()

        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
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

        decompressionSession = sessionOut
    }

    private func invalidateSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
    }

    private func decodeH264(encodedFrame: EncodedFrame) throws -> CVPixelBuffer? {
        guard let session = decompressionSession, let formatDescription else {
            throw DecoderServiceError.parameterSetUnavailable
        }

        var blockBuffer: CMBlockBuffer?
        var createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: encodedFrame.payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: encodedFrame.payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw DecoderServiceError.blockBufferCreationFailed(createStatus)
        }

        createStatus = encodedFrame.payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: encodedFrame.payload.count)
        }

        guard createStatus == kCMBlockBufferNoErr else {
            throw DecoderServiceError.blockBufferWriteFailed(createStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
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

        let context = DecoderCallbackContext()
        let refcon = Unmanaged.passRetained(context).toOpaque()

        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: refcon,
            infoFlagsOut: &flagsOut
        )

        guard decodeStatus == noErr else {
            Unmanaged<DecoderCallbackContext>.fromOpaque(refcon).release()
            throw DecoderServiceError.decodeFailed(decodeStatus)
        }

        let waitResult = context.semaphore.wait(timeout: .now() + 1.0)
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
}

private final class DecoderCallbackContext {
    let semaphore = DispatchSemaphore(value: 0)
    var pixelBuffer: CVPixelBuffer?
    var error: Error?
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
