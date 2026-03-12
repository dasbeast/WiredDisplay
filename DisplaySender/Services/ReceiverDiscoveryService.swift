import Darwin
import Combine
import Foundation

struct DiscoveredReceiver: Identifiable, Equatable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let endpointSummary: String
    let prefersWiredPath: Bool
}

@MainActor
final class ReceiverDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var lastErrorMessage: String?

    private let browser = NetServiceBrowser()
    private var servicesByKey: [String: NetService] = [:]
    private var receiversByKey: [String: DiscoveredReceiver] = [:]

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

        guard let resolvedHost = preferredHost(for: service) else {
            return nil
        }

        let host = resolvedHost.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        return DiscoveredReceiver(
            id: key(for: service),
            displayName: service.name,
            host: host,
            port: UInt16(service.port),
            endpointSummary: "\(host):\(service.port)",
            prefersWiredPath: resolvedHost.prefersWiredPath
        )
    }

    private func preferredHost(for service: NetService) -> (host: String, prefersWiredPath: Bool)? {
        var candidates: [(host: String, score: Int, prefersWiredPath: Bool)] = []

        for address in service.addresses ?? [] {
            guard let host = numericHost(from: address) else { continue }
            let prefersWiredPath = host.hasPrefix("169.254.")
            let score: Int
            if prefersWiredPath {
                score = 0
            } else if host.contains(":") {
                score = 3
            } else if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("172.") {
                score = 1
            } else {
                score = 2
            }
            candidates.append((host: host, score: score, prefersWiredPath: prefersWiredPath))
        }

        if let bestCandidate = candidates.sorted(by: { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.host < rhs.host
        }).first {
            return (host: bestCandidate.host, prefersWiredPath: bestCandidate.prefersWiredPath)
        }

        if let hostName = service.hostName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hostName.isEmpty {
            return (host: hostName, prefersWiredPath: false)
        }

        return nil
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
