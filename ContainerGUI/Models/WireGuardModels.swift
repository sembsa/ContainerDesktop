import Foundation

/// One WireGuard peer as `wg show all dump` reports it.
///
/// Deliberately has no field for a preshared key: the parser reads the column
/// and throws it away.
struct WireGuardPeer: Sendable, Hashable, Identifiable {
    var publicKey: String
    var endpoint: String?
    var allowedIPs: [String]
    /// `nil` = never (the dump prints 0).
    var latestHandshake: Date?
    var rxBytes: Int64
    var txBytes: Int64
    /// Persistent keepalive in seconds; `nil` = off.
    var keepalive: Int?

    var id: String { publicKey }
}

/// One WireGuard interface, from the dump and/or from `ifconfig` / `ip -o addr`.
///
/// Deliberately has no field for the interface's private key: the parser reads
/// the column and throws it away, so nothing downstream can display, log or
/// persist it.
struct WireGuardInterface: Sendable, Hashable {
    /// Where the details come from.
    enum Source: Sendable, Hashable {
        /// `wg show all dump` answered (as this user or through `sudo -n`).
        case dump
        /// Only the network stack was consulted: name and address, no peers.
        case addressOnly
    }

    var name: String
    var listenPort: Int?
    var publicKey: String?
    /// Interface addresses in CIDR form, `10.10.0.254/24`.
    var addresses: [String]
    /// The networks those addresses sit in, `10.10.0.0/24`.
    var subnets: [String]
    var peers: [WireGuardPeer]
    var source: Source
    /// Why there are no peers to show: wg needs root and `sudo -n` did not help.
    var peerDetailsNeedRoot: Bool
    /// `wg` is not installed on that machine (the interface was found by address).
    var wgMissing: Bool = false
    /// The interface was recognised by its MTU/name rather than by `wg`
    /// (macOS hides `wg0` behind a `utunN` device).
    var inferred: Bool = false
}

/// Everything one probe of a machine found.
struct WireGuardScan: Sendable, Hashable {
    enum Status: Sendable, Hashable {
        /// `wg` answered.
        case ok
        /// `wg` is installed but not allowed to read the interfaces.
        case needsRoot
        /// No `wg` binary in any of the candidate locations.
        case missing
    }

    var status: Status
    var wgBinary: String?
    /// `sudo -n` was attempted (it never prompts).
    var sudoAttempted: Bool
    /// `sudo -n` is what made the dump work.
    var usedSudo: Bool
    var interfaces: [WireGuardInterface]
}
