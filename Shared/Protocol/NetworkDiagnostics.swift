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

/// Tracks whether a wired Ethernet route is currently available.
final class WiredPathStatusMonitor {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let queue = DispatchQueue(label: "wireddisplay.network.wiredpath")

    private(set) var isStarted = false
    var onUpdate: ((Bool) -> Void)?

    func start() {
        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            self?.onUpdate?(path.status == .satisfied)
        }

        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
    }
}
