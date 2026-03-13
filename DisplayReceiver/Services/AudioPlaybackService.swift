import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackService {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: NetworkProtocol.audioSampleRateHz,
        channels: AVAudioChannelCount(NetworkProtocol.audioChannelCount),
        interleaved: true
    )

    private var isPrepared = false
    private var queuedBufferCount = 0

    func prepare() {
        guard !isPrepared else {
            ensureEngineRunning()
            return
        }
        guard let playbackFormat else { return }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        isPrepared = true
        ensureEngineRunning()
    }

    func stop() {
        queuedBufferCount = 0
        playerNode.stop()
        engine.stop()
    }

    func play(header: BinaryAudioHeader, payload: Data) {
        guard header.codec == .pcmInt16Interleaved else { return }
        guard let playbackFormat else { return }

        prepare()

        let frameCount = AVAudioFrameCount(max(0, header.frameCount))
        guard frameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else { return }

        let bytesPerFrame = Int(playbackFormat.streamDescription.pointee.mBytesPerFrame)
        let expectedPayloadLength = Int(frameCount) * bytesPerFrame
        guard payload.count >= expectedPayloadLength else { return }
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }

        buffer.frameLength = frameCount
        payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            memcpy(destination, baseAddress, expectedPayloadLength)
        }
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(expectedPayloadLength)

        if queuedBufferCount >= NetworkProtocol.audioPlaybackMaxQueuedBuffers {
            playerNode.stop()
            queuedBufferCount = 0
            ensureEngineRunning()
        }

        queuedBufferCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queuedBufferCount = max(0, self.queuedBufferCount - 1)
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func ensureEngineRunning() {
        guard isPrepared else { return }

        if !engine.isRunning {
            try? engine.start()
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
}
