import Foundation

enum AudioCodec: String, Codable, Sendable {
    case pcmInt16Interleaved
}

struct AudioPacket: Codable, Sendable {
    let packetIndex: UInt64
    let timestampNanoseconds: UInt64
    let codec: AudioCodec
    let sampleRateHz: Double
    let channelCount: Int
    let frameCount: Int
    let payload: Data
}

struct BinaryAudioHeader: Codable, Sendable {
    let packetIndex: UInt64
    let timestampNanoseconds: UInt64
    let codec: AudioCodec
    let sampleRateHz: Double
    let channelCount: Int
    let frameCount: Int
    let payloadLength: Int
}

enum BinaryAudioWire {
    static func serializeFramed(audioPacket: AudioPacket) -> Data? {
        let header = BinaryAudioHeader(
            packetIndex: audioPacket.packetIndex,
            timestampNanoseconds: audioPacket.timestampNanoseconds,
            codec: audioPacket.codec,
            sampleRateHz: audioPacket.sampleRateHz,
            channelCount: audioPacket.channelCount,
            frameCount: audioPacket.frameCount,
            payloadLength: audioPacket.payload.count
        )

        guard let headerData = try? JSONEncoder().encode(header) else {
            return nil
        }

        var body = Data()
        var magic = NetworkProtocol.binaryAudioMagic.bigEndian
        body.append(Data(bytes: &magic, count: 4))
        body.append(0)

        var headerLength = UInt32(headerData.count).bigEndian
        body.append(Data(bytes: &headerLength, count: 4))
        body.append(headerData)
        body.append(audioPacket.payload)

        var frameLength = UInt32(body.count).bigEndian
        var framed = Data(bytes: &frameLength, count: 4)
        framed.append(body)
        return framed
    }

    static func deserialize(data: Data) -> (header: BinaryAudioHeader, payload: Data)? {
        guard data.count >= 9 else { return nil }
        guard NetworkProtocol.readUInt32BigEndian(from: data, atOffset: 0) == NetworkProtocol.binaryAudioMagic else {
            return nil
        }

        guard let headerLength = NetworkProtocol.readUInt32BigEndian(from: data, atOffset: 5) else {
            return nil
        }

        let headerStart = 9
        let headerEnd = headerStart + Int(headerLength)
        guard data.count >= headerEnd else { return nil }

        let headerData = data.subdata(in: headerStart..<headerEnd)
        guard let header = try? JSONDecoder().decode(BinaryAudioHeader.self, from: headerData) else {
            return nil
        }

        let payloadEnd = headerEnd + header.payloadLength
        guard data.count >= payloadEnd else { return nil }

        let payload = data.subdata(in: headerEnd..<payloadEnd)
        return (header, payload)
    }
}
