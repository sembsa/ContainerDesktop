import Foundation

/// A machine the app knows by name, with the addresses it can be recognised by
/// (its WireGuard overlay addresses, or the literal IP it is reached at).
struct WireGuardKnownHost: Sendable, Hashable {
    let name: String
    /// Bare IPs, no prefix length.
    let addresses: [String]
}

/// The aliases earlier versions kept, keyed by public key, as a JSON string in
/// preferences. `WireGuardPeerLabelStore` imports them once and owns labels now.
enum WireGuardAliases {
    static let defaultsKey = "wireGuardPeerAliases"

    static func decode(_ stored: String) -> [String: String] {
        guard let data = stored.data(using: .utf8), !stored.isEmpty,
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dictionary
    }

    static func encode(_ aliases: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(aliases), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Sets (or, for a blank name, removes) one alias.
    static func setting(_ alias: String, for publicKey: String, in stored: String) -> String {
        var aliases = decode(stored)
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { aliases[publicKey] = nil } else { aliases[publicKey] = trimmed }
        return encode(aliases)
    }
}

/// One peer as the detail section shows it.
struct WireGuardPeerRow: Identifiable, Sendable, Hashable {
    enum NameSource: Sendable, Hashable {
        /// The user's own alias.
        case alias
        /// An allowed IP or the endpoint matched a known machine.
        case machine
    }

    let peer: WireGuardPeer
    let name: String?
    let nameSource: NameSource?
    /// The name the peer would have without the user's label: the machine its
    /// address matched, or `nil` (the shortened key is shown then).
    var autoName: String?
    /// The user's note for this peer, when there is one.
    var note: String?
    /// The icon of the peer row: the type the user chose, else one read off the
    /// matched machine's name; `nil` for an unknown peer on Auto (no icon).
    var deviceType: PeerDeviceType?
    /// Whether `deviceType` is the user's own choice (as opposed to guessed).
    var deviceTypeIsUserChosen = false
    /// No handshake for more than `WireGuardPeerPresenter.staleAfter` (or never).
    let isStale: Bool

    var id: String { peer.id }
}

enum WireGuardPeerPresenter {
    /// A peer that has not completed a handshake for this long is dimmed. WireGuard
    /// re-handshakes about every two minutes while traffic flows.
    static let staleAfter: TimeInterval = 180

    /// Peers with the most recent handshake first, never-seen peers last.
    static func rows(
        for interface: WireGuardInterface,
        aliases: [String: String] = [:],
        notes: [String: String] = [:],
        deviceTypes: [String: PeerDeviceType] = [:],
        knownHosts: [WireGuardKnownHost] = [],
        now: Date = Date()
    ) -> [WireGuardPeerRow] {
        interface.peers
            .sorted { lhs, rhs in
                switch (lhs.latestHandshake, rhs.latestHandshake) {
                case (let a?, let b?): a != b ? a > b : lhs.publicKey < rhs.publicKey
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.publicKey < rhs.publicKey
                }
            }
            .map { peer in
                let (name, source) = displayName(for: peer, aliases: aliases, knownHosts: knownHosts)
                let auto = displayName(for: peer, aliases: [:], knownHosts: knownHosts).0
                let note = notes[peer.publicKey].flatMap { $0.isEmpty ? nil : $0 }
                let chosen = deviceTypes[peer.publicKey]
                let guessed = auto.flatMap(PeerDeviceType.inferred(fromName:))
                return WireGuardPeerRow(
                    peer: peer, name: name, nameSource: source, autoName: auto, note: note,
                    deviceType: PeerDeviceType.resolved(user: chosen, inferred: guessed, builtIn: nil),
                    deviceTypeIsUserChosen: chosen != nil,
                    isStale: isStale(peer, now: now)
                )
            }
    }

    /// Every peer as it is shown in the list: its name, or its shortened key.
    static func peerNames(_ rows: [WireGuardPeerRow]) -> [String] {
        rows.map { $0.name ?? WireGuardFormat.shortKey($0.peer.publicKey) }
    }

    /// The first few names of the peers that have one ("Mac Studio, Phone +2"),
    /// for the interface row's header; `nil` when none of them is named.
    static func summary(of rows: [WireGuardPeerRow], limit: Int = 3) -> String? {
        let names = rows.compactMap(\.name)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) +\(names.count - limit)" : shown
    }

    static func isStale(_ peer: WireGuardPeer, now: Date = Date()) -> Bool {
        guard let handshake = peer.latestHandshake else { return true }
        return now.timeIntervalSince(handshake) > staleAfter
    }

    /// The user's label first (even over a machine match); otherwise the first known machine whose address is one of
    /// the peer's allowed IPs (a `/32` or a plain address), then one whose
    /// address is the peer's endpoint host.
    static func displayName(
        for peer: WireGuardPeer, aliases: [String: String], knownHosts: [WireGuardKnownHost]
    ) -> (String?, WireGuardPeerRow.NameSource?) {
        if let alias = aliases[peer.publicKey], !alias.isEmpty { return (alias, .alias) }
        let allowed = Set(peer.allowedIPs.compactMap(hostAddress(of:)))
        if let host = knownHosts.first(where: { !allowed.isDisjoint(with: $0.addresses) }) { return (host.name, .machine) }
        if let endpointHost = endpointHost(peer.endpoint),
           let host = knownHosts.first(where: { $0.addresses.contains(endpointHost) }) { return (host.name, .machine) }
        return (nil, nil)
    }

    /// `10.10.0.1/32` -> `10.10.0.1`; a wider range (`10.10.0.0/24`, `0.0.0.0/0`)
    /// identifies no single host and gives `nil`.
    static func hostAddress(of allowedIP: String) -> String? {
        let parts = allowedIP.split(separator: "/", omittingEmptySubsequences: false)
        guard let address = parts.first, !address.isEmpty else { return nil }
        if parts.count == 2, let prefix = Int(parts[1]) {
            let isV6 = address.contains(":")
            guard prefix == (isV6 ? 128 : 32) else { return nil }
        }
        return String(address)
    }

    /// `203.0.113.7:51820` -> `203.0.113.7`; `[2001:db8::1]:51820` -> `2001:db8::1`.
    static func endpointHost(_ endpoint: String?) -> String? {
        guard let endpoint, !endpoint.isEmpty else { return nil }
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let colon = endpoint.lastIndex(of: ":"), endpoint.filter({ $0 == ":" }).count == 1 else { return endpoint }
        return String(endpoint[..<colon])
    }

    /// Known hosts from WireGuard interfaces seen on each machine, plus the IP
    /// literal an external machine is reached at.
    static func knownHosts(
        interfaces: [(machine: String, interface: WireGuardInterface)],
        endpoints: [(label: String, host: String)] = []
    ) -> [WireGuardKnownHost] {
        var byName: [String: [String]] = [:]
        var order: [String] = []
        func add(_ name: String, _ addresses: [String]) {
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(contentsOf: addresses)
        }
        for (machine, interface) in interfaces {
            add(machine, interface.addresses.compactMap { $0.split(separator: "/").first.map(String.init) })
        }
        for (label, host) in endpoints where isIPLiteral(host) { add(label, [host]) }
        return order.map { WireGuardKnownHost(name: $0, addresses: byName[$0] ?? []) }
    }

    static func isIPLiteral(_ text: String) -> Bool {
        let v4 = text.split(separator: ".", omittingEmptySubsequences: false)
        if v4.count == 4, v4.allSatisfy({ UInt8($0) != nil }) { return true }
        return text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }
}
