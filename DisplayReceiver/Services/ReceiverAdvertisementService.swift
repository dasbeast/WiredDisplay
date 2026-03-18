import AppKit
import Combine
import Darwin
import Foundation

private enum ReceiverAdvertisementTXTRecordKey {
    static let deviceFamily = "deviceFamily"
    static let displayName = "displayName"
    static let preferredHost = "preferredHost"
    static let preferredHostIsWired = "preferredHostIsWired"
}

private enum AdvertisedReceiverVisualKind: String {
    case imac
    case macMini
    case macStudio
    case macbookAir
    case studioDisplay
    case macbookPro
    case display
}

@MainActor
final class ReceiverAdvertisementService: NSObject, ObservableObject {
    @Published private(set) var isAdvertising = false
    @Published private(set) var advertisedName: String?
    @Published private(set) var lastErrorMessage: String?

    private var service: NetService?
    func startAdvertising(port: UInt16, name: String) {
        stopAdvertising()

        let profile = ReceiverAdvertisementProfile.current(receiverName: name)
        let service = NetService(
            domain: NetworkProtocol.discoveryServiceDomain,
            type: NetworkProtocol.discoveryServiceType,
            name: name,
            port: Int32(port)
        )
        if let txtRecordData = profile.txtRecordData {
            service.setTXTRecord(txtRecordData)
        }
        service.delegate = self
        self.service = service
        lastErrorMessage = nil
        service.publish()
    }

    func stopAdvertising() {
        service?.delegate = nil
        service?.stop()
        service = nil
        isAdvertising = false
        advertisedName = nil
    }
}

extension ReceiverAdvertisementService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        isAdvertising = true
        advertisedName = sender.name
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        isAdvertising = false
        advertisedName = nil
        lastErrorMessage = "Receiver advertisement failed (\(errorDict))"
    }
}

private struct ReceiverAdvertisementProfile {
    let displayName: String?
    let deviceFamily: AdvertisedReceiverVisualKind
    let preferredHost: String?
    let preferredHostIsWired: Bool

    var txtRecordData: Data? {
        var textRecord: [String: Data] = [
            ReceiverAdvertisementTXTRecordKey.deviceFamily: Data(deviceFamily.rawValue.utf8)
        ]

        if let displayName, !displayName.isEmpty {
            textRecord[ReceiverAdvertisementTXTRecordKey.displayName] = Data(displayName.utf8)
        }

        if let preferredHost, !preferredHost.isEmpty {
            textRecord[ReceiverAdvertisementTXTRecordKey.preferredHost] = Data(preferredHost.utf8)
            textRecord[ReceiverAdvertisementTXTRecordKey.preferredHostIsWired] = Data((preferredHostIsWired ? "1" : "0").utf8)
        }

        return NetService.data(fromTXTRecord: textRecord)
    }

    static func current(receiverName: String) -> ReceiverAdvertisementProfile {
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayName = mainScreen?.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReceiverName = receiverName.lowercased()
        let normalizedDisplayName = displayName?.lowercased() ?? ""
        let preferredAddress = NetworkDiagnostics.preferredDiscoveryIPv4Address()
        let hardwareModel = hardwareModelIdentifier()

        if hardwareModel.hasPrefix("Macmini") || normalizedReceiverName.contains("mac mini") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .macMini,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if hardwareModel.hasPrefix("MacStudio") || normalizedReceiverName.contains("mac studio") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .macStudio,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if hardwareModel.hasPrefix("MacBookAir") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .macbookAir,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if hardwareModel.hasPrefix("MacBookPro") || normalizedReceiverName.contains("macbook pro") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .macbookPro,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if hardwareModel.hasPrefix("iMac") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .imac,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if normalizedDisplayName.contains("studio display") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .studioDisplay,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if normalizedReceiverName.contains("imac") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .imac,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if normalizedReceiverName.contains("macbook") ||
            normalizedDisplayName.contains("retina xdr") ||
            normalizedDisplayName.contains("liquid retina") {
            return ReceiverAdvertisementProfile(
                displayName: displayName,
                deviceFamily: .macbookPro,
                preferredHost: preferredAddress?.address,
                preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
            )
        }

        if let mainScreen {
            let backingFrame = mainScreen.convertRectToBacking(mainScreen.frame)
            if normalizedDisplayName.contains("built-in"), backingFrame.width >= 4300 {
                return ReceiverAdvertisementProfile(
                    displayName: displayName,
                    deviceFamily: .imac,
                    preferredHost: preferredAddress?.address,
                    preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
                )
            }
        }

        return ReceiverAdvertisementProfile(
            displayName: displayName,
            deviceFamily: .display,
            preferredHost: preferredAddress?.address,
            preferredHostIsWired: preferredAddress?.isWiredPreferred ?? false
        )
    }

    private static func hardwareModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }

        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
