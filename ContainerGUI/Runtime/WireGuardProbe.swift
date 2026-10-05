import Foundation

/// Finds WireGuard interfaces on a machine — this Mac or an external one — with
/// one read-only shell script, and turns its output into `WireGuardScan`.
///
/// **Secrets.** `wg show all dump` prints each interface's *private key* (and
/// each peer's preshared key). The script blanks those two columns with `awk`
/// before anything is written to stdout, so the keys never leave the machine
/// that holds them; the parser, which ignores those columns as well, is the
/// second line of defence. `WireGuardInterface` / `WireGuardPeer` have no field
/// that could hold either key, and nothing here logs command output.
///
/// **Privileges.** `wg` needs root. The script tries it as the connecting user
/// first; only if that fails and the user is not root does it try `sudo -n`
/// (non-interactive: it fails at once instead of prompting, and no password is
/// ever sent or stored). When neither works the interface is still shown from
/// `ifconfig` / `ip -o addr`, flagged "peer details need root".
enum WireGuardProbe {
    /// Where `wg` is looked for, by absolute path, before `command -v`.
    static let wgCandidates = ["/opt/homebrew/bin/wg", "/usr/local/bin/wg", "/usr/bin/wg"]

    /// Output lines are `<tag> <payload>`:
    /// `OS`, `WGBIN`, `SUDO` (`tried`/`ok`), `WGSTATUS` (`ok`/`needsroot`/`missing`),
    /// `D` dump row (secrets blanked), `M` macOS name map, `F` ifconfig line,
    /// `L` `ip -o link … type wireguard` line, `A` `ip -o addr` line.
    static func script(trySudo: Bool) -> String {
        let candidates = wgCandidates.map { "\"\($0)\"" }.joined(separator: " ")
        return #"""
        PATH="$PATH:/sbin:/usr/sbin:/usr/bin:/bin"
        TRY_SUDO=\#(trySudo ? 1 : 0)
        OS=$(uname -s)
        echo "OS $OS"
        WG=""
        for c in \#(candidates); do
          if [ -f "$c" ] && [ -x "$c" ]; then WG=$c; break; fi
        done
        if [ -z "$WG" ]; then
          c=$(command -v wg 2>/dev/null)
          case "$c" in /*) if [ -f "$c" ] && [ -x "$c" ]; then WG=$c; fi ;; esac
        fi
        PRIV=""
        STATUS=missing
        out=""
        if [ -n "$WG" ]; then
          echo "WGBIN $WG"
          STATUS=needsroot
          out=$("$WG" show all dump 2>/dev/null </dev/null)
          if [ $? -eq 0 ]; then
            STATUS=ok
          else
            out=""
            if [ "$TRY_SUDO" = "1" ] && [ "$(id -u)" != "0" ]; then
              echo "SUDO tried"
              out=$(sudo -n "$WG" show all dump 2>/dev/null </dev/null)
              if [ $? -eq 0 ]; then STATUS=ok; PRIV="sudo -n"; echo "SUDO ok"; else out=""; fi
            fi
          fi
        fi
        echo "WGSTATUS $STATUS"
        if [ "$STATUS" = "ok" ]; then
          printf '%s\n' "$out" | awk -F'\t' 'BEGIN{OFS="\t"} NF==5{$2="-"} NF>=9{$3="-"} {print "D " $0}'
          out=""
          for f in /var/run/wireguard/*.name; do
            [ -e "$f" ] || continue
            n=$(basename "$f" .name)
            v=$(cat "$f" 2>/dev/null </dev/null)
            if [ -z "$v" ] && [ -n "$PRIV" ]; then v=$($PRIV cat "$f" 2>/dev/null </dev/null); fi
            if [ -n "$v" ]; then echo "M $n $v"; fi
          done
        fi
        if [ "$OS" = "Darwin" ]; then
          ifconfig 2>/dev/null | sed 's/^/F /'
        elif command -v ip >/dev/null 2>&1; then
          ip -o link show type wireguard 2>/dev/null | sed 's/^/L /'
          ip -o addr show 2>/dev/null | sed 's/^/A /'
        else
          ifconfig -a 2>/dev/null | sed 's/^/F /'
        fi
        exit 0
        """#
    }

    // MARK: - Running

    /// This Mac.
    static func scanLocal(trySudo: Bool) async throws -> WireGuardScan {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-s"], input: script(trySudo: trySudo), timeout: .seconds(20)
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: "")
        }
        return parse(result.stdout)
    }

    /// An external machine, over `ssh` with `BatchMode` (never prompts).
    static func scan(endpoint: DockerEndpoint, trySudo: Bool) async throws -> WireGuardScan {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: SSHCommand.probe(endpoint: endpoint),
            input: script(trySudo: trySudo),
            timeout: .seconds(30)
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: "")
        }
        return parse(result.stdout)
    }

    // MARK: - Parsing

    /// Turns the script's output into a scan. Total: unknown or malformed lines
    /// are skipped.
    static func parse(_ output: String, now: Date = Date()) -> WireGuardScan {
        var os = ""
        var binary: String?
        var sudoTried = false
        var sudoOK = false
        var status = WireGuardScan.Status.missing
        var dumpLines: [String] = []
        var nameMap: [String: String] = [:]
        var ifconfigLines: [String] = []
        var linkLines: [String] = []
        var addrLines: [String] = []

        for raw in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let space = raw.firstIndex(of: " ") else { continue }
            let tag = raw[..<space]
            let payload = String(raw[raw.index(after: space)...])
            switch tag {
            case "OS": os = payload.trimmingCharacters(in: .whitespaces)
            case "WGBIN": binary = payload.trimmingCharacters(in: .whitespaces)
            case "SUDO":
                if payload.hasPrefix("tried") { sudoTried = true }
                if payload.hasPrefix("ok") { sudoOK = true }
            case "WGSTATUS":
                switch payload.trimmingCharacters(in: .whitespaces) {
                case "ok": status = .ok
                case "needsroot": status = .needsRoot
                default: status = .missing
                }
            case "D": dumpLines.append(payload)
            case "M":
                let parts = payload.split(separator: " ").map(String.init)
                if parts.count == 2 { nameMap[parts[0]] = parts[1] }
            case "F": ifconfigLines.append(payload)
            case "L": linkLines.append(payload)
            case "A": addrLines.append(payload)
            default: continue
            }
        }

        // What the network stack knows, by device name.
        var devices = Self.parseIfconfig(ifconfigLines)
        for (name, addresses) in Self.parseIPAddr(addrLines) {
            devices[name, default: Device(name: name)].addresses.append(contentsOf: addresses)
        }
        for name in Self.parseIPLinkNames(linkLines) {
            devices[name, default: Device(name: name)].isWireGuardLink = true
        }

        var interfaces: [WireGuardInterface] = []
        let dump = parseDump(dumpLines.joined(separator: "\n"), now: now)

        if status == .ok {
            // Devices that look like WireGuard but are not named in the dump
            // (macOS: `wg0` is `utunN`) are the candidates for the name map.
            let candidates = devices.values.filter(\.looksLikeWireGuard).map(\.name).sorted()
            for var interface in dump {
                let deviceName = nameMap[interface.name] ?? interface.name
                var device = devices[deviceName]
                if device == nil, os == "Darwin", dump.count == 1, candidates.count == 1 {
                    device = devices[candidates[0]]
                    interface.inferred = true
                }
                interface.addresses = device?.addresses.map(\.cidr) ?? []
                interface.subnets = Self.unique(device?.addresses.compactMap(\.subnet) ?? [])
                interfaces.append(interface)
            }
        } else {
            // No dump: report what the network stack shows, flagged as such.
            for device in devices.values.sorted(by: { $0.name < $1.name }) where device.looksLikeWireGuard {
                interfaces.append(WireGuardInterface(
                    name: device.name,
                    listenPort: nil,
                    publicKey: nil,
                    addresses: device.addresses.map(\.cidr),
                    subnets: Self.unique(device.addresses.compactMap(\.subnet)),
                    peers: [],
                    source: .addressOnly,
                    peerDetailsNeedRoot: status == .needsRoot,
                    wgMissing: status == .missing,
                    inferred: !device.isWireGuardLink && !device.name.hasPrefix("wg")
                ))
            }
        }
        return WireGuardScan(
            status: status, wgBinary: binary, sudoAttempted: sudoTried, usedSudo: sudoOK, interfaces: interfaces
        )
    }

    /// `wg show all dump`, tab separated.
    ///
    /// Interface row (5 columns): `iface  private-key  public-key  listen-port  fwmark`.
    /// Peer row (9 columns): `iface  public-key  preshared-key  endpoint  allowed-ips
    /// latest-handshake  rx  tx  persistent-keepalive`.
    /// The private key (interface column 2) and the preshared key (peer column 3)
    /// are never read into anything.
    static func parseDump(_ dump: String, now: Date = Date()) -> [WireGuardInterface] {
        var order: [String] = []
        var interfaces: [String: WireGuardInterface] = [:]

        for line in dump.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.count {
            case 5:
                let name = fields[0]
                guard !name.isEmpty else { continue }
                if interfaces[name] == nil { order.append(name) }
                interfaces[name] = WireGuardInterface(
                    name: name,
                    listenPort: Int(fields[3]).flatMap { $0 > 0 ? $0 : nil },
                    publicKey: Self.value(fields[2]),
                    addresses: [], subnets: [], peers: [],
                    source: .dump, peerDetailsNeedRoot: false
                )
            case 9...:
                let name = fields[0]
                guard !name.isEmpty, let publicKey = Self.value(fields[1]) else { continue }
                if interfaces[name] == nil {
                    // A peer without its interface row: keep the peer anyway.
                    order.append(name)
                    interfaces[name] = WireGuardInterface(
                        name: name, listenPort: nil, publicKey: nil, addresses: [], subnets: [], peers: [],
                        source: .dump, peerDetailsNeedRoot: false
                    )
                }
                let allowed = fields[4] == "(none)" ? [] : fields[4].split(separator: ",").map(String.init)
                let handshake = TimeInterval(fields[5]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                interfaces[name]?.peers.append(WireGuardPeer(
                    publicKey: publicKey,
                    endpoint: Self.value(fields[3]),
                    allowedIPs: allowed,
                    latestHandshake: handshake,
                    rxBytes: Int64(fields[6]) ?? 0,
                    txBytes: Int64(fields[7]) ?? 0,
                    keepalive: Int(fields[8])
                ))
            default:
                continue
            }
        }
        return order.compactMap { interfaces[$0] }
    }

    /// `(none)` / `off` / empty -> nil.
    private static func value(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "(none)" || trimmed == "off" ? nil : trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Network stack

    struct Address: Sendable, Hashable {
        let ip: String
        let prefix: Int
        var cidr: String { "\(ip)/\(prefix)" }
        /// The network the address sits in (IPv4 only).
        var subnet: String? { Self.network(ip: ip, prefix: prefix) }

        static func network(ip: String, prefix: Int) -> String? {
            let parts = ip.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4, parts.allSatisfy({ $0 < 256 }), (0...32).contains(prefix) else { return nil }
            let value = parts.reduce(UInt32(0)) { ($0 << 8) | $1 }
            let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
            let net = value & mask
            return "\(net >> 24).\((net >> 16) & 255).\((net >> 8) & 255).\(net & 255)/\(prefix)"
        }
    }

    struct Device: Sendable, Hashable {
        var name: String
        var mtu: Int?
        var pointToPoint = false
        var addresses: [Address] = []
        /// `ip -o link show type wireguard` listed it.
        var isWireGuardLink = false

        /// WireGuard devices are recognised by the kernel's link type (Linux),
        /// by a `wg*` name, or — on macOS, where `wg0` hides behind `utunN` —
        /// by `utun` with WireGuard's default MTU of 1420 and an IPv4 address.
        var looksLikeWireGuard: Bool {
            if isWireGuardLink || name.hasPrefix("wg") { return true }
            return name.hasPrefix("utun") && mtu == 1420 && addresses.contains { !$0.ip.contains(":") }
        }
    }

    /// `ifconfig` (macOS and net-tools): header `name: flags=… mtu N`, then
    /// `inet A [--> B] netmask 0xffffff00|255.255.255.0 …` or `inet6 A prefixlen N`.
    static func parseIfconfig(_ lines: [String]) -> [String: Device] {
        var devices: [String: Device] = [:]
        var current: String?
        for line in lines {
            if let first = line.first, !first.isWhitespace {
                guard let colon = line.firstIndex(of: ":") else { current = nil; continue }
                let name = String(line[..<colon])
                var device = Device(name: name)
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let index = words.firstIndex(of: "mtu"), index + 1 < words.count { device.mtu = Int(words[index + 1]) }
                device.pointToPoint = line.contains("POINTOPOINT")
                devices[name] = device
                current = name
                continue
            }
            guard let current else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let kind = words.first else { continue }
            if kind == "inet", words.count >= 2 {
                guard let maskIndex = words.firstIndex(of: "netmask"), maskIndex + 1 < words.count,
                      let prefix = prefixLength(netmask: words[maskIndex + 1]) else { continue }
                devices[current]?.addresses.append(Address(ip: words[1], prefix: prefix))
            } else if kind == "inet6", words.count >= 2 {
                let ip = String(words[1].split(separator: "%")[0])
                if ip.lowercased().hasPrefix("fe80") { continue }
                if let index = words.firstIndex(of: "prefixlen"), index + 1 < words.count, let prefix = Int(words[index + 1]) {
                    devices[current]?.addresses.append(Address(ip: ip, prefix: prefix))
                }
            }
        }
        return devices
    }

    /// `0xffffff00` or `255.255.255.0` -> 24.
    static func prefixLength(netmask: String) -> Int? {
        if netmask.hasPrefix("0x") {
            guard let value = UInt32(netmask.dropFirst(2), radix: 16) else { return nil }
            return value.nonzeroBitCount
        }
        let parts = netmask.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(UInt32(0)) { ($0 << 8) | $1 }.nonzeroBitCount
    }

    /// `ip -o addr`: `3005: wg0    inet 10.10.0.254/24 scope global wg0\ …`.
    /// Link-local IPv6 is dropped.
    static func parseIPAddr(_ lines: [String]) -> [String: [Address]] {
        var result: [String: [Address]] = [:]
        for line in lines {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count >= 4, words[2] == "inet" || words[2] == "inet6" else { continue }
            let name = String(words[1].split(separator: "@")[0])
            let parts = words[3].split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { continue }
            let ip = String(parts[0])
            if words[2] == "inet6", ip.lowercased().hasPrefix("fe80") { continue }
            result[name, default: []].append(Address(ip: ip, prefix: prefix))
        }
        return result
    }

    /// `ip -o link show type wireguard`: `3005: wg0: <POINTOPOINT,…` -> `wg0`.
    static func parseIPLinkNames(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count >= 2 else { return nil }
            var name = words[1]
            if name.hasSuffix(":") { name.removeLast() }
            return String(name.split(separator: "@")[0])
        }
    }
}

// MARK: - Display

/// Human-readable forms of the numbers a peer row shows.
enum WireGuardFormat {
    /// `latest handshake` as "2 min ago", or "never".
    static func handshake(_ date: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let date else { return String(localized: "nigdy") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "1.2 MB".
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// A key shown in a row: the first characters only, enough to compare with
    /// `wg show` by eye without filling the line.
    static func shortKey(_ key: String) -> String {
        key.count > 12 ? String(key.prefix(8)) + "…" + String(key.suffix(4)) : key
    }
}
