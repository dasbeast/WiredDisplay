import Foundation
import Network
import Darwin
import SystemConfiguration

/// Lightweight diagnostics helpers for local interface visibility and wired path status.
enum LocalInterfaceKind: String, Sendable {
    case thunderboltBridge
    case wiredEthernet
    case wifi
    case bridge
    case other

    nonisolated var isWiredPreferred: Bool {
        switch self {
        case .thunderboltBridge, .wiredEthernet, .bridge:
            return true
        case .wifi, .other:
            return false
        }
    }

    nonisolated var priorityScore: Int {
        switch self {
        case .thunderboltBridge:
            return 0
        case .wiredEthernet:
            return 1
        case .bridge:
            return 2
        case .wifi:
            return 4
        case .other:
            return 3
        }
    }
}

struct LocalInterfaceAddress: Sendable {
    let interfaceName: String
    let address: String
    let kind: LocalInterfaceKind

    nonisolated var isLinkLocal: Bool { address.hasPrefix("169.254.") }
    nonisolated var isWiredPreferred: Bool { kind.isWiredPreferred }
}

enum NetworkDiagnostics {
    /// Returns active non-loopback IPv4 addresses currently visible on this Mac.
    nonisolated static func localIPv4Addresses() -> [LocalInterfaceAddress] {
        var results: [LocalInterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        let interfaceKinds = interfaceKindsByBSDName()

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }

        defer {
            freeifaddrs(pointer)
        }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }

            let flags = Int32(entry.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }

            guard let addressPointer = entry.ifa_addr else { continue }
            guard addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addressPointer.pointee.sa_len)

            let status = getnameinfo(
                addressPointer,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard status == 0 else { continue }

            let name = String(cString: entry.ifa_name)
            let ip = String(cString: host)
            let kind = interfaceKinds[name] ?? inferInterfaceKind(interfaceName: name)
            results.append(LocalInterfaceAddress(interfaceName: name, address: ip, kind: kind))
        }

        return results.sorted(by: compareLocalInterfaces)
    }

    nonisolated static func localIPv4Descriptions() -> [String] {
        localIPv4Addresses().map { "\($0.interfaceName): \($0.address)" }
    }

    nonisolated static func preferredDiscoveryIPv4Address() -> LocalInterfaceAddress? {
        let addresses = localIPv4Addresses()
        return addresses.min(by: { lhs, rhs in
            compareLocalInterfaces(lhs, rhs)
        })
    }

    nonisolated static func looksLikeWiredPreferredHost(_ host: String) -> Bool {
        host.hasPrefix("169.254.")
    }

    /// Builds TCP parameters tuned for interactive display streaming.
    /// `noDelay` disables Nagle coalescing to reduce input-to-photon latency.
    nonisolated static func lowLatencyTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// Builds UDP parameters tuned for interactive video delivery.
    nonisolated static func lowLatencyUDPParameters() -> NWParameters {
        let udpOptions = NWProtocolUDP.Options()
        let parameters = NWParameters(dtls: nil, udp: udpOptions)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

/// Tracks whether a wired path (Ethernet or Thunderbolt Bridge) is currently available.
/// Thunderbolt Bridge does not register as .wiredEthernet in Network.framework,
/// so we monitor all paths and check for any non-wifi, non-cellular interface,
/// or look for bridge/thunderbolt interface names in the system interfaces.
final class WiredPathStatusMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "wireddisplay.network.wiredpath")

    private(set) var isStarted = false
    var onUpdate: ((Bool) -> Void)?

    func start() {
        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            let hasWired = self?.detectWiredPath(path) ?? false
            self?.onUpdate?(hasWired)
        }

        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
    }

    private func detectWiredPath(_ path: NWPath) -> Bool {
        guard path.status == .satisfied else { return false }

        // Check if any available interface is wired (ethernet or bridge/thunderbolt)
        for interface in path.availableInterfaces {
            switch interface.type {
            case .wiredEthernet:
                return true
            case .other:
                // Thunderbolt Bridge shows up as type .other with name like "bridge0"
                let name = interface.name.lowercased()
                if name.hasPrefix("bridge") || name.hasPrefix("thunder") || name.hasPrefix("en") {
                    return true
                }
            default:
                continue
            }
        }

        // Also check system interfaces for actual bridge / wired interfaces.
        let interfaces = NetworkDiagnostics.localIPv4Addresses()
        if interfaces.contains(where: \.isWiredPreferred) { return true }

        return false
    }
}

private extension NetworkDiagnostics {
    nonisolated static func compareLocalInterfaces(_ lhs: LocalInterfaceAddress, _ rhs: LocalInterfaceAddress) -> Bool {
        let lhsScore = hostPreferenceScore(for: lhs)
        let rhsScore = hostPreferenceScore(for: rhs)
        if lhsScore != rhsScore {
            return lhsScore < rhsScore
        }
        if lhs.interfaceName != rhs.interfaceName {
            return lhs.interfaceName < rhs.interfaceName
        }
        return lhs.address < rhs.address
    }

    nonisolated static func hostPreferenceScore(for address: LocalInterfaceAddress) -> Int {
        var score = address.kind.priorityScore * 10
        if address.isLinkLocal {
            score -= address.kind == .thunderboltBridge ? 5 : 1
        } else if isPrivateIPv4(address.address) {
            score += 1
        } else {
            score += 3
        }
        return score
    }

    nonisolated static func isPrivateIPv4(_ host: String) -> Bool {
        host.hasPrefix("10.") ||
        host.hasPrefix("192.168.") ||
        host.hasPrefix("172.16.") ||
        host.hasPrefix("172.17.") ||
        host.hasPrefix("172.18.") ||
        host.hasPrefix("172.19.") ||
        host.hasPrefix("172.20.") ||
        host.hasPrefix("172.21.") ||
        host.hasPrefix("172.22.") ||
        host.hasPrefix("172.23.") ||
        host.hasPrefix("172.24.") ||
        host.hasPrefix("172.25.") ||
        host.hasPrefix("172.26.") ||
        host.hasPrefix("172.27.") ||
        host.hasPrefix("172.28.") ||
        host.hasPrefix("172.29.") ||
        host.hasPrefix("172.30.") ||
        host.hasPrefix("172.31.")
    }

    nonisolated static func interfaceKindsByBSDName() -> [String: LocalInterfaceKind] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }

        var result: [String: LocalInterfaceKind] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let systemType = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            result[bsdName] = classifyInterface(
                interfaceName: bsdName,
                systemType: systemType,
                displayName: displayName
            )
        }
        return result
    }

    nonisolated static func classifyInterface(
        interfaceName: String,
        systemType: String?,
        displayName: String?
    ) -> LocalInterfaceKind {
        let interfaceNameLower = interfaceName.lowercased()
        let displayNameLower = (displayName ?? "").lowercased()

        if displayNameLower.contains("thunderbolt bridge") || interfaceNameLower.hasPrefix("bridge") {
            return .thunderboltBridge
        }

        if systemType == (kSCNetworkInterfaceTypeIEEE80211 as String) {
            return .wifi
        }

        if systemType == (kSCNetworkInterfaceTypeEthernet as String) {
            return .wiredEthernet
        }

        if displayNameLower.contains("bridge") {
            return .bridge
        }

        return inferInterfaceKind(interfaceName: interfaceName)
    }

    nonisolated static func inferInterfaceKind(interfaceName: String) -> LocalInterfaceKind {
        let name = interfaceName.lowercased()
        if name.hasPrefix("bridge") || name.hasPrefix("thunder") {
            return .thunderboltBridge
        }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") {
            return .other
        }
        return .other
    }
}
