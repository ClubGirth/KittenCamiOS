import Foundation

enum KittenCamPacketType: UInt8 {
    case streamInformation = 1
    case videoConfiguration = 2
    case videoFrame = 3
    case heartbeat = 4
    case error = 5
    case audioConfiguration = 6
    case audioFrame = 7
}

struct KittenCamPacket {
    static let protocolVersion: UInt8 = 1

    let type: KittenCamPacketType
    let payload: Data

    func encoded() -> Data {
        var packet = Data()

        packet.append(Self.protocolVersion)
        packet.append(type.rawValue)

        var payloadLength = UInt32(payload.count).bigEndian

        withUnsafeBytes(of: &payloadLength) { bytes in
            packet.append(contentsOf: bytes)
        }

        packet.append(payload)

        return packet
    }
}
