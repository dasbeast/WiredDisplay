import Combine
import Foundation

@MainActor
final class ReceiverAdvertisementService: NSObject, ObservableObject {
    @Published private(set) var isAdvertising = false
    @Published private(set) var advertisedName: String?
    @Published private(set) var lastErrorMessage: String?

    private var service: NetService?

    func startAdvertising(port: UInt16, name: String) {
        stopAdvertising()

        let service = NetService(
            domain: NetworkProtocol.discoveryServiceDomain,
            type: NetworkProtocol.discoveryServiceType,
            name: name,
            port: Int32(port)
        )
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
