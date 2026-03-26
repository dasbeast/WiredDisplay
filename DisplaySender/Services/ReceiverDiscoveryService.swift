import Darwin
import Combine
import Foundation

enum DiscoveredReceiverVisualKind: String {
    case imac
    case macMini
    case macStudio
    case macbookAir
    case studioDisplay
    case macbookPro
    case display
}

struct DiscoveredReceiver: Identifiable, Equatable {
    let id: String
    let displayName: String
    let displayDescriptor: String?
    let host: String
    let port: UInt16
    let endpointSummary: String
    let prefersWiredPath: Bool
    let visualKind: DiscoveredReceiverVisualKind
    let pathOptions: [DiscoveryPathOption]
}

@MainActor
final class ReceiverDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var lastErrorMessage: String?

    private let browser = NetServiceBrowser()
    private var servicesByKey: [String: NetService] = [:]
    private var receiversByKey: [String: DiscoveredReceiver] = [:]

    private enum TXTRecordKey {
        static let deviceFamily = "deviceFamily"
        static let displayName = "displayName"
        static let preferredHost = "preferredHost"
        static let preferredHostIsWired = "preferredHostIsWired"
        static let pathOptions = "pathOptions"
    }

    override init() {
        super.init()
        browser.delegate = self
    }

    func startBrowsing() {
        guard !isBrowsing else { return }
        lastErrorMessage = nil
        browser.searchForServices(
            ofType: NetworkProtocol.discoveryServiceType,
            inDomain: NetworkProtocol.discoveryServiceDomain
        )
        isBrowsing = true
    }

    func stopBrowsing() {
        browser.stop()
        for service in servicesByKey.values {
            service.delegate = nil
            service.stop()
        }
        servicesByKey.removeAll(keepingCapacity: false)
        receiversByKey.removeAll(keepingCapacity: false)
        receivers = []
        isBrowsing = false
    }

    private func refreshPublishedReceivers() {
        receivers = receiversByKey.values.sorted { lhs, rhs in
            if lhs.prefersWiredPath != rhs.prefersWiredPath {
                return lhs.prefersWiredPath && !rhs.prefersWiredPath
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func key(for service: NetService) -> String {
        "\(service.domain)|\(service.type)|\(service.name)"
    }

    private func makeReceiver(from service: NetService) -> DiscoveredReceiver? {
        guard service.port > 0, service.port <= Int(UInt16.max) else {
            return nil
        }

        let textRecord = textRecordDictionary(for: service)

        guard let resolvedHost = preferredHost(for: service, textRecord: textRecord) else {
            return nil
        }

        let host = resolvedHost.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let displayDescriptor = txtString(for: TXTRecordKey.displayName, in: textRecord)
        let visualKind = resolveVisualKind(
            advertisedFamily: txtString(for: TXTRecordKey.deviceFamily, in: textRecord),
            receiverName: service.name,
            displayDescriptor: displayDescriptor
        )

        return DiscoveredReceiver(
            id: key(for: service),
            displayName: service.name,
            displayDescriptor: displayDescriptor,
            host: host,
            port: UInt16(service.port),
            endpointSummary: "\(host):\(service.port)",
            prefersWiredPath: resolvedHost.prefersWiredPath,
            visualKind: visualKind,
            pathOptions: pathOptions(for: service, textRecord: textRecord, preferredHost: host)
        )
    }

    private func pathOptions(
        for service: NetService,
        textRecord: [String: Data]?,
        preferredHost: String
    ) -> [DiscoveryPathOption] {
        if let serialized = txtString(for: TXTRecordKey.pathOptions, in: textRecord) {
            let advertisedOptions = NetworkDiagnostics.parseDiscoveryPathOptions(serialized)
            if !advertisedOptions.isEmpty {
                return NetworkDiagnostics.orderedUniqueDiscoveryPathOptions(
                    advertisedOptions,
                    preferredHost: preferredHost
                )
            }
        }

        let fallbackOptions = (service.addresses ?? []).compactMap { address -> DiscoveryPathOption? in
            guard let host = numericHost(from: address) else { return nil }
            let kind: LocalInterfaceKind
            if host.hasPrefix("169.254.") {
                kind = .thunderboltBridge
            } else {
                kind = .other
            }
            return DiscoveryPathOption(host: host, kind: kind)
        }

        if !fallbackOptions.isEmpty {
            return NetworkDiagnostics.orderedUniqueDiscoveryPathOptions(
                fallbackOptions,
                preferredHost: preferredHost
            )
        }

        return [DiscoveryPathOption(host: preferredHost, kind: .other)]
    }

    private func preferredHost(
        for service: NetService,
        textRecord: [String: Data]?
    ) -> (host: String, prefersWiredPath: Bool)? {
        let resolvedHosts = (service.addresses ?? []).compactMap(numericHost(from:))
        let resolvedHost = NetworkDiagnostics.resolvePreferredDiscoveryHost(
            advertisedHost: txtString(for: TXTRecordKey.preferredHost, in: textRecord),
            advertisedHostIsWired: txtString(for: TXTRecordKey.preferredHostIsWired, in: textRecord) == "1",
            resolvedHosts: resolvedHosts,
            fallbackHostName: service.hostName
        )

        return resolvedHost.map { (host: $0.host, prefersWiredPath: $0.prefersWiredPath) }
    }

    private func numericHost(from addressData: Data) -> String? {
        addressData.withUnsafeBytes { rawBuffer -> String? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }

            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            let family = Int32(sockaddrPointer.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { return nil }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sockaddrPointer,
                socklen_t(addressData.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { return nil }
            return String(cString: hostBuffer)
        }
    }

    private func textRecordDictionary(for service: NetService) -> [String: Data]? {
        guard let textRecordData = service.txtRecordData() else {
            return nil
        }

        return NetService.dictionary(fromTXTRecord: textRecordData)
    }

    private func txtString(for key: String, in textRecord: [String: Data]?) -> String? {
        guard let value = textRecord?[key], !value.isEmpty else {
            return nil
        }

        return String(data: value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveVisualKind(
        advertisedFamily: String?,
        receiverName: String,
        displayDescriptor: String?
    ) -> DiscoveredReceiverVisualKind {
        if let advertisedFamily,
           let family = DiscoveredReceiverVisualKind(rawValue: advertisedFamily) {
            return family
        }

        let receiverNameLowercased = receiverName.lowercased()
        let displayDescriptorLowercased = displayDescriptor?.lowercased() ?? ""
        let combined = receiverNameLowercased + " " + displayDescriptorLowercased

        if receiverNameLowercased.contains("mac mini") || receiverNameLowercased.contains("macmini") {
            return .macMini
        }

        if receiverNameLowercased.contains("mac studio") || receiverNameLowercased.contains("macstudio") {
            return .macStudio
        }

        if receiverNameLowercased.contains("macbook air") {
            return .macbookAir
        }

        if receiverNameLowercased.contains("imac") {
            return .imac
        }

        if receiverNameLowercased.contains("macbook pro") ||
            combined.contains("retina xdr") ||
            combined.contains("liquid retina") {
            return .macbookPro
        }

        if displayDescriptorLowercased.contains("studio display") {
            return .studioDisplay
        }

        if combined.contains("macbook") {
            return .macbookPro
        }

        return .display
    }
}

extension ReceiverDiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        isBrowsing = true
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isBrowsing = false
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        isBrowsing = false
        lastErrorMessage = "Receiver discovery failed (\(errorDict))"
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let serviceKey = key(for: service)
        servicesByKey[serviceKey] = service
        service.delegate = self
        service.resolve(withTimeout: NetworkProtocol.discoveryResolveTimeoutSeconds)

        if !moreComing {
            refreshPublishedReceivers()
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let serviceKey = key(for: service)
        servicesByKey[serviceKey]?.delegate = nil
        servicesByKey.removeValue(forKey: serviceKey)
        receiversByKey.removeValue(forKey: serviceKey)

        if !moreComing {
            refreshPublishedReceivers()
        }
    }
}

extension ReceiverDiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceKey = key(for: sender)
        if let receiver = makeReceiver(from: sender) {
            receiversByKey[serviceKey] = receiver
        }
        refreshPublishedReceivers()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        receiversByKey.removeValue(forKey: key(for: sender))
        lastErrorMessage = "Could not resolve \(sender.name) (\(errorDict))"
        refreshPublishedReceivers()
    }
}
