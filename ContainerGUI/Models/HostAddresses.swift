import Foundation
import Darwin

/// This Mac's own addresses on the plain network (not tunnels, not containers).
enum HostAddresses {
    /// IPv4 addresses of the Ethernet / Wi-Fi interfaces that are up, e.g.
    /// `192.168.68.20`. Empty when none is known.
    static func localIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ip: String? = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var sin = pointer.pointee.sin_addr
                return inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count)) != nil ? String(cString: buffer) : nil
            }
            if let ip, isLAN(interface: name, address: ip), !found.contains(ip) { found.append(ip) }
        }
        return found
    }

    /// Whether an interface/address pair is a LAN address worth showing:
    /// `en*` (Ethernet, Wi-Fi), not self-assigned.
    static func isLAN(interface: String, address: String) -> Bool {
        interface.hasPrefix("en") && !address.hasPrefix("169.254.") && !address.hasPrefix("127.")
    }
}
