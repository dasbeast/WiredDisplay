import Foundation
import Network
import Darwin

/// Lightweight diagnostics helpers for local interface visibility and wired path status.
struct LocalInterfaceAddress: Sendable {
    let interfaceName: String
    let address: String
}

enum NetworkDiagnostics {
    /// Returns active non-loopback IPv4 addresses currently visible on this Mac.
    static func localIPv4Addresses() -> [LocalInterfaceAddress] {
        var results: [LocalInterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

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
            results.append(LocalInterfaceAddress(interfaceName: name, address: ip))
        }

        return results.sorted {
            if $0.interfaceName == $1.interfaceName {
                return $0.address < $1.address
            }
            return $0.interfaceName < $1.interfaceName
        }
    }

    static func localIPv4Descriptions() -> [String] {
        localIPv4Addresses().map { "\($0.interfaceName): \($0.address)" }
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

        // Also check system interfaces for bridge/thunderbolt addresses
        let interfaces = NetworkDiagnostics.localIPv4Addresses()
        for iface in interfaces {
            let name = iface.interfaceName.lowercased()
            if name.hasPrefix("bridge") || name.hasPrefix("en") {
                return true
            }
        }

        return false
    }
}
