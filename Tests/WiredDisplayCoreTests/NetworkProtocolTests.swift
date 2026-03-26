import XCTest
@testable import WiredDisplayCore

final class NetworkProtocolTests: XCTestCase {
    func testValidateAcceptsCurrentVersion() throws {
        XCTAssertNoThrow(try NetworkProtocol.validate(version: NetworkProtocol.protocolVersion))
    }

    func testValidateRejectsUnsupportedVersion() {
        XCTAssertThrowsError(try NetworkProtocol.validate(version: NetworkProtocol.protocolVersion + 1)) { error in
            guard case let NetworkProtocol.ProtocolError.unsupportedVersion(received, expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(received, NetworkProtocol.protocolVersion + 1)
            XCTAssertEqual(expected, NetworkProtocol.protocolVersion)
        }
    }

    func testRecommendedVideoBitrateClampsToMinimum() {
        let bitrate = NetworkProtocol.recommendedVideoBitrateBps(width: 1, height: 1, fps: 1)
        XCTAssertEqual(bitrate, NetworkProtocol.minVideoBitrateBps)
    }

    func testRecommendedVideoBitrateUsesExpectedHeuristicWithinBounds() {
        let bitrate = NetworkProtocol.recommendedVideoBitrateBps(width: 5120, height: 2880, fps: 60)
        XCTAssertEqual(bitrate, 176_947_200)
    }

    func testRecommendedVideoBitrateClampsToMaximum() {
        let bitrate = NetworkProtocol.recommendedVideoBitrateBps(width: 200_000, height: 200_000, fps: 60)
        XCTAssertEqual(bitrate, NetworkProtocol.maxVideoBitrateBps)
    }

    func testNegotiatedVideoTransportFallsBackToTCPWhenUDPUnavailable() {
        XCTAssertEqual(
            NetworkProtocol.negotiatedVideoTransport(requested: .udp, canAcceptDatagrams: false),
            .tcp
        )
        XCTAssertEqual(
            NetworkProtocol.negotiatedVideoTransport(requested: .udp, canAcceptDatagrams: true),
            .udp
        )
    }

    func testKeyFrameIntervalFramesUsesTransportSpecificPolicy() {
        XCTAssertEqual(
            NetworkProtocol.keyFrameIntervalFrames(for: .tcp),
            NetworkProtocol.targetFramesPerSecond * NetworkProtocol.keyFrameIntervalSeconds
        )
        XCTAssertEqual(
            NetworkProtocol.keyFrameIntervalFrames(for: .udp),
            NetworkProtocol.udpKeyFrameIntervalFrames
        )
    }

    func testEvaluateSenderHeartbeatComputesRoundTripOffsetAndDisplayLatency() throws {
        let heartbeat = HeartbeatPayload(
            transmitTimestampNanoseconds: 1_014_000_000,
            originTimestampNanoseconds: 1_000_000_000,
            receiveTimestampNanoseconds: 1_012_000_000,
            renderedFrameIndex: 22,
            renderedFrameSenderTimestampNanoseconds: 1_020_000_000,
            renderedFrameReceiverTimestampNanoseconds: 1_025_000_000
        )

        let evaluation = try XCTUnwrap(
            NetworkProtocol.evaluateSenderHeartbeat(
                heartbeat,
                localReceiveTimestampNanoseconds: 1_030_000_000,
                negotiatedVideoTransportMode: .udp,
                awaitingFirstRenderedFrame: true
            )
        )

        XCTAssertEqual(evaluation.roundTripMilliseconds, 28.0, accuracy: 0.0001)
        XCTAssertEqual(evaluation.receiverClockOffsetNanoseconds, -2_000_000)
        XCTAssertEqual(try XCTUnwrap(evaluation.displayLatencyMilliseconds), 7.0, accuracy: 0.0001)
        XCTAssertTrue(evaluation.shouldClearAwaitingFirstRenderedFrame)
        XCTAssertFalse(evaluation.shouldRequestRecoveryKeyFrame)
    }

    func testEvaluateSenderHeartbeatRequestsRecoveryWhileAwaitingFirstUDPRender() throws {
        let heartbeat = HeartbeatPayload(
            transmitTimestampNanoseconds: 120,
            originTimestampNanoseconds: 100,
            receiveTimestampNanoseconds: 110,
            renderedFrameIndex: nil,
            renderedFrameSenderTimestampNanoseconds: nil,
            renderedFrameReceiverTimestampNanoseconds: nil
        )

        let evaluation = try XCTUnwrap(
            NetworkProtocol.evaluateSenderHeartbeat(
                heartbeat,
                localReceiveTimestampNanoseconds: 140,
                negotiatedVideoTransportMode: .udp,
                awaitingFirstRenderedFrame: true
            )
        )

        XCTAssertFalse(evaluation.shouldClearAwaitingFirstRenderedFrame)
        XCTAssertTrue(evaluation.shouldRequestRecoveryKeyFrame)
        XCTAssertNil(evaluation.displayLatencyMilliseconds)
    }

    func testEvaluateSenderHeartbeatRequiresReplyTimingTimestamps() {
        let heartbeat = HeartbeatPayload(
            transmitTimestampNanoseconds: 120,
            originTimestampNanoseconds: nil,
            receiveTimestampNanoseconds: 110,
            renderedFrameIndex: nil,
            renderedFrameSenderTimestampNanoseconds: nil,
            renderedFrameReceiverTimestampNanoseconds: nil
        )

        XCTAssertNil(
            NetworkProtocol.evaluateSenderHeartbeat(
                heartbeat,
                localReceiveTimestampNanoseconds: 140,
                negotiatedVideoTransportMode: .tcp,
                awaitingFirstRenderedFrame: false
            )
        )
    }

    func testNextReceiverFrameTimingSnapshotSeedsInitialIntervalAndJitter() throws {
        let snapshot = NetworkProtocol.nextReceiverFrameTimingSnapshot(
            previousArrivalNanoseconds: 1_000_000_000,
            previousSmoothedIntervalMilliseconds: nil,
            previousSmoothedJitterMilliseconds: nil,
            arrivalNanoseconds: 1_020_000_000
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.averageFrameIntervalMilliseconds), 20.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.estimatedJitterMilliseconds), 0.0, accuracy: 0.0001)
    }

    func testNextReceiverFrameTimingSnapshotSmoothsIntervalAndJitter() throws {
        let snapshot = NetworkProtocol.nextReceiverFrameTimingSnapshot(
            previousArrivalNanoseconds: 1_000_000_000,
            previousSmoothedIntervalMilliseconds: 16.0,
            previousSmoothedJitterMilliseconds: 1.0,
            arrivalNanoseconds: 1_020_000_000
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.averageFrameIntervalMilliseconds), 16.48, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.estimatedJitterMilliseconds), 1.3024, accuracy: 0.0001)
    }

    func testNetworkEnvelopeRoundTripsTypedPayload() throws {
        let payload = HeartbeatPayload(
            transmitTimestampNanoseconds: 123,
            originTimestampNanoseconds: 100,
            receiveTimestampNanoseconds: 110,
            renderedFrameIndex: 12,
            renderedFrameSenderTimestampNanoseconds: 90,
            renderedFrameReceiverTimestampNanoseconds: 120
        )

        let envelope = try NetworkEnvelope.make(
            type: .heartbeat,
            sequenceNumber: 7,
            payload: payload
        )

        let decoded = try envelope.decodePayload(as: HeartbeatPayload.self)
        XCTAssertEqual(decoded.transmitTimestampNanoseconds, payload.transmitTimestampNanoseconds)
        XCTAssertEqual(decoded.originTimestampNanoseconds, payload.originTimestampNanoseconds)
        XCTAssertEqual(decoded.receiveTimestampNanoseconds, payload.receiveTimestampNanoseconds)
        XCTAssertEqual(decoded.renderedFrameIndex, payload.renderedFrameIndex)
    }

    func testNetworkEnvelopeRejectsPayloadWhenVersionDoesNotMatch() throws {
        let envelope = NetworkEnvelope(
            version: NetworkProtocol.protocolVersion + 1,
            type: .heartbeat,
            sequenceNumber: 1,
            payload: try JSONEncoder().encode(
                HeartbeatPayload(
                    transmitTimestampNanoseconds: 1,
                    originTimestampNanoseconds: nil,
                    receiveTimestampNanoseconds: nil,
                    renderedFrameIndex: nil,
                    renderedFrameSenderTimestampNanoseconds: nil,
                    renderedFrameReceiverTimestampNanoseconds: nil
                )
            )
        )

        XCTAssertThrowsError(try envelope.decodePayload(as: HeartbeatPayload.self))
    }

    func testBinaryFrameWireRoundTripsHEVCFrame() throws {
        let encodedFrame = makeEncodedFrame(
            codec: .hevcAVCC,
            payload: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            vps: Data([0x01, 0x02]),
            sps: Data([0x03, 0x04, 0x05]),
            pps: Data([0x06, 0x07])
        )

        let serialized = try XCTUnwrap(BinaryFrameWire.serialize(encodedFrame: encodedFrame))
        let decoded = try XCTUnwrap(BinaryFrameWire.deserialize(data: serialized))

        XCTAssertEqual(decoded.header.frameIndex, encodedFrame.metadata.frameIndex)
        XCTAssertEqual(decoded.header.timestampNanoseconds, encodedFrame.metadata.timestampNanoseconds)
        XCTAssertEqual(decoded.header.width, encodedFrame.metadata.width)
        XCTAssertEqual(decoded.header.height, encodedFrame.metadata.height)
        XCTAssertEqual(decoded.header.codec, encodedFrame.codec)
        XCTAssertEqual(decoded.header.payloadLength, encodedFrame.payload.count)
        XCTAssertEqual(decoded.vps, encodedFrame.hevcVPS)
        XCTAssertEqual(decoded.sps, encodedFrame.h264SPS)
        XCTAssertEqual(decoded.pps, encodedFrame.h264PPS)
        XCTAssertEqual(decoded.payload, encodedFrame.payload)
    }

    func testBinaryFrameWireRejectsInvalidMagic() throws {
        let encodedFrame = makeEncodedFrame(codec: .rawBGRA, payload: Data([0xAA, 0xBB]))
        var serialized = try XCTUnwrap(BinaryFrameWire.serialize(encodedFrame: encodedFrame))
        serialized[0] = 0

        XCTAssertNil(BinaryFrameWire.deserialize(data: serialized))
    }

    func testVideoDatagramWireSplitsAndReassemblesFramePayload() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        let encodedFrame = makeEncodedFrame(codec: .rawBGRA, payload: payload)
        let datagrams = try XCTUnwrap(VideoDatagramWire.serialize(encodedFrame: encodedFrame))

        XCTAssertGreaterThan(datagrams.count, 1)

        let decodedChunks = try datagrams.enumerated().map { index, datagram in
            let decoded = try XCTUnwrap(VideoDatagramWire.deserialize(datagram: datagram))
            XCTAssertEqual(decoded.frameIndex, encodedFrame.metadata.frameIndex)
            XCTAssertEqual(decoded.chunkCount, datagrams.count)
            XCTAssertEqual(decoded.chunkIndex, index)
            return decoded
        }

        let reassembledFrameData = Data(
            decodedChunks
                .sorted { $0.chunkIndex < $1.chunkIndex }
                .flatMap(\.payload)
        )
        let decodedFrame = try XCTUnwrap(BinaryFrameWire.deserialize(data: reassembledFrameData))

        XCTAssertEqual(decodedFrame.header.frameIndex, encodedFrame.metadata.frameIndex)
        XCTAssertEqual(decodedFrame.header.codec, encodedFrame.codec)
        XCTAssertEqual(decodedFrame.payload, encodedFrame.payload)
    }

    private func makeEncodedFrame(
        codec: VideoCodec,
        payload: Data,
        vps: Data? = nil,
        sps: Data? = nil,
        pps: Data? = nil
    ) -> EncodedFrame {
        EncodedFrame(
            metadata: FrameMetadata(
                frameIndex: 42,
                timestampNanoseconds: 999_999,
                width: 2560,
                height: 1440,
                isKeyFrame: true
            ),
            codec: codec,
            payload: payload,
            isKeyFrame: true,
            sourceBytesPerRow: 2560 * 4,
            sourcePixelFormat: .bgra8,
            targetBitrateKbps: 20_000,
            targetFramesPerSecond: 60,
            h264SPS: sps,
            h264PPS: pps,
            hevcVPS: vps
        )
    }
}
