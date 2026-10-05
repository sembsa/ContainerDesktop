import XCTest

/// `wg show all dump` and the `ifconfig` / `ip -o addr` fallbacks. Every key in
/// the fixtures is a synthetic placeholder that says so ("FAKE-…"); no real key
/// is, or may ever be, committed here.
final class WireGuardProbeTests: XCTestCase {
    private func fixtureText(_ name: String, ext: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext)
        return try String(contentsOf: XCTUnwrap(url, "missing fixture \(name).\(ext)"), encoding: .utf8)
    }

    // MARK: - dump

    func testParsesInterfacesAndPeers() throws {
        let interfaces = WireGuardProbe.parseDump(try fixtureText("wg-dump-synthetic", ext: "tsv"))
        XCTAssertEqual(interfaces.map(\.name), ["wg0", "wg1"])

        let wg0 = interfaces[0]
        XCTAssertEqual(wg0.listenPort, 51820)
        XCTAssertEqual(wg0.publicKey, "FAKE-PUBLIC-KEY-HUB-AAAAAAAAAAAAAAAAAAAAAAAAAA=")
        XCTAssertEqual(wg0.peers.count, 2)
        XCTAssertEqual(wg0.source, .dump)

        let first = wg0.peers[0]
        XCTAssertEqual(first.publicKey, "FAKE-PEER-PUBKEY-ONE-BBBBBBBBBBBBBBBBBBBBBBB=")
        XCTAssertEqual(first.endpoint, "203.0.113.10:51820")
        XCTAssertEqual(first.allowedIPs, ["10.10.0.1/32"])
        XCTAssertEqual(first.latestHandshake, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(first.rxBytes, 123_456_789)
        XCTAssertEqual(first.txBytes, 987_654_321)
        XCTAssertEqual(first.keepalive, 25)

        let second = wg0.peers[1]
        XCTAssertNil(second.endpoint, "(none) is no endpoint")
        XCTAssertEqual(second.allowedIPs, ["10.10.0.3/32", "192.168.50.0/24"])
        XCTAssertNil(second.latestHandshake, "0 means never")
        XCTAssertEqual(second.rxBytes, 0)
        XCTAssertNil(second.keepalive, "off is no keepalive")
    }

    func testListenPortZeroAndFwmarkAreTolerated() throws {
        let wg1 = try XCTUnwrap(WireGuardProbe.parseDump(fixtureText("wg-dump-synthetic", ext: "tsv")).last)
        XCTAssertNil(wg1.listenPort)
        XCTAssertTrue(wg1.peers.isEmpty)
    }

    /// The private and preshared keys are read from the dump and thrown away:
    /// nothing in the parsed result — however it is rendered — contains them.
    func testSecretsNeverSurviveParsing() throws {
        let dump = try fixtureText("wg-dump-synthetic", ext: "tsv")
        XCTAssertTrue(dump.contains("FAKE-PRIVATE-KEY"), "the fixture must contain the secrets for this test to mean anything")
        let parsed = WireGuardProbe.parseDump(dump)
        let rendered = String(reflecting: parsed) + String(describing: parsed) + String(describing: parsed.map(NetworkEntry.init(wireGuard:)))
        XCTAssertFalse(rendered.contains("PRIVATE"))
        XCTAssertFalse(rendered.contains("PRESHARED"))
        XCTAssertFalse(rendered.contains("DO-NOT-USE"))
        XCTAssertFalse(rendered.contains("ZZZZ"))
    }

    func testMalformedDumpLinesAreSkipped() {
        let dump = "garbage\nwg0\tonly\ttwo\n\n\t\t\t\t\n"
        XCTAssertTrue(WireGuardProbe.parseDump(dump).isEmpty)
    }

    func testPeerWithoutInterfaceRowIsKept() {
        let row = ["wg9", "FAKE-PEER-PUBKEY-X=", "(none)", "198.51.100.7:1", "10.9.0.2/32", "5", "1", "2", "0"].joined(separator: "\t")
        let parsed = WireGuardProbe.parseDump(row)
        XCTAssertEqual(parsed.first?.name, "wg9")
        XCTAssertEqual(parsed.first?.peers.count, 1)
    }

    // MARK: - script output -> scan

    private func dumpLines(_ dump: String) -> String {
        // What the remote awk emits: secrets blanked to "-", each row tagged "D ".
        dump.split(separator: "\n").map { line -> String in
            var f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.count == 5 { f[1] = "-" } else if f.count >= 9 { f[2] = "-" }
            return "D " + f.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    func testLinuxHubWithRoot() throws {
        let output = """
        OS Linux
        WGBIN /usr/bin/wg
        WGSTATUS ok
        \(dumpLines(try fixtureText("wg-dump-synthetic", ext: "tsv")))
        L 3005: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\\    link/none
        A 2: eth0    inet 167.233.101.159/32 metric 100 scope global dynamic eth0\\       valid_lft 78387sec preferred_lft 78387sec
        A 3005: wg0    inet 10.10.0.254/24 scope global wg0\\       valid_lft forever preferred_lft forever
        A 3005: wg0    inet6 fe80::1/64 scope link \\       valid_lft forever preferred_lft forever
        """
        let scan = WireGuardProbe.parse(output)
        XCTAssertEqual(scan.status, .ok)
        XCTAssertEqual(scan.wgBinary, "/usr/bin/wg")
        XCTAssertFalse(scan.usedSudo)
        let wg0 = try XCTUnwrap(scan.interfaces.first { $0.name == "wg0" })
        XCTAssertEqual(wg0.addresses, ["10.10.0.254/24"])
        XCTAssertEqual(wg0.subnets, ["10.10.0.0/24"])
        XCTAssertEqual(wg0.peers.count, 2)
        XCTAssertFalse(wg0.peerDetailsNeedRoot)
        let wg1 = try XCTUnwrap(scan.interfaces.first { $0.name == "wg1" })
        XCTAssertTrue(wg1.addresses.isEmpty)
    }

    func testMacWithoutRootFallsBackToIfconfig() throws {
        let output = """
        OS Darwin
        WGBIN /opt/homebrew/bin/wg
        SUDO tried
        WGSTATUS needsroot
        F lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        F \tinet 127.0.0.1 netmask 0xff000000
        F utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420
        F \tinet 10.10.0.3 --> 10.10.0.3 netmask 0xffffffff
        F utun1: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        F \tinet6 fe80::1%utun1 prefixlen 64 scopeid 0x13
        F utun2: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
        F \tinet 100.64.0.9 --> 100.64.0.9 netmask 0xffffffff
        """
        let scan = WireGuardProbe.parse(output)
        XCTAssertEqual(scan.status, .needsRoot)
        XCTAssertTrue(scan.sudoAttempted)
        XCTAssertFalse(scan.usedSudo)
        XCTAssertEqual(scan.interfaces.map(\.name), ["utun0"], "only the MTU-1420 utun with an IPv4 address looks like WireGuard")
        let utun0 = scan.interfaces[0]
        XCTAssertEqual(utun0.addresses, ["10.10.0.3/32"])
        XCTAssertEqual(utun0.subnets, ["10.10.0.3/32"])
        XCTAssertTrue(utun0.peers.isEmpty)
        XCTAssertTrue(utun0.peerDetailsNeedRoot)
        XCTAssertEqual(utun0.source, .addressOnly)
        XCTAssertTrue(utun0.inferred)
    }

    func testStudioNetmaskIsNarrowedToSubnet() {
        let output = """
        OS Darwin
        WGSTATUS needsroot
        F utun12: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420
        F \tinet 10.10.0.1 --> 10.10.0.1 netmask 0xffffff00
        """
        let interface = WireGuardProbe.parse(output).interfaces.first
        XCTAssertEqual(interface?.addresses, ["10.10.0.1/24"])
        XCTAssertEqual(interface?.subnets, ["10.10.0.0/24"])
    }

    func testMacDumpWithNameMapGetsTheUtunAddress() throws {
        let output = """
        OS Darwin
        WGBIN /opt/homebrew/bin/wg
        SUDO tried
        SUDO ok
        WGSTATUS ok
        D wg0\t-\tFAKE-PUBLIC-KEY-MAC-EEEEEEEEEEEEEEEEEEEEEEEEE=\t0\toff
        D wg0\tFAKE-PEER-PUBKEY-HUB-FFFFFFFFFFFFFFFFFFFFFFFFF=\t-\t203.0.113.1:51820\t10.10.0.0/24\t1790000100\t10\t20\t25
        M wg0 utun0
        F utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420
        F \tinet 10.10.0.3 --> 10.10.0.3 netmask 0xffffffff
        """
        let scan = WireGuardProbe.parse(output)
        XCTAssertEqual(scan.status, .ok)
        XCTAssertTrue(scan.usedSudo)
        let wg0 = try XCTUnwrap(scan.interfaces.first)
        XCTAssertEqual(wg0.name, "wg0")
        XCTAssertEqual(wg0.addresses, ["10.10.0.3/32"])
        XCTAssertEqual(wg0.peers.count, 1)
        XCTAssertFalse(wg0.peerDetailsNeedRoot)
    }

    func testSingleDumpInterfaceIsMatchedToTheOnlyUtunWithoutAMap() throws {
        let output = """
        OS Darwin
        WGSTATUS ok
        D wg0\t-\tFAKE-PUBLIC-KEY-MAC-EEEEEEEEEEEEEEEEEEEEEEEEE=\t0\toff
        F utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420
        F \tinet 10.10.0.7 --> 10.10.0.7 netmask 0xffffffff
        """
        let wg0 = try XCTUnwrap(WireGuardProbe.parse(output).interfaces.first)
        XCTAssertEqual(wg0.addresses, ["10.10.0.7/32"])
        XCTAssertTrue(wg0.inferred)
    }

    func testWgMissingStillShowsAnInterfaceByAddress() throws {
        let output = """
        OS Linux
        WGSTATUS missing
        L 7: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN
        A 7: wg0    inet 10.8.0.1/24 scope global wg0\\       valid_lft forever preferred_lft forever
        A 2: eth0    inet 192.0.2.5/24 scope global eth0\\       valid_lft forever preferred_lft forever
        """
        let scan = WireGuardProbe.parse(output)
        XCTAssertEqual(scan.status, .missing)
        let wg0 = try XCTUnwrap(scan.interfaces.first)
        XCTAssertEqual(scan.interfaces.count, 1)
        XCTAssertTrue(wg0.wgMissing)
        XCTAssertFalse(wg0.peerDetailsNeedRoot)
        XCTAssertEqual(wg0.subnets, ["10.8.0.0/24"])
    }

    func testNoWireGuardAnywhereGivesNothing() {
        let scan = WireGuardProbe.parse("OS Linux\nWGSTATUS missing\nA 2: eth0    inet 192.0.2.5/24 scope global eth0\\\n")
        XCTAssertTrue(scan.interfaces.isEmpty)
    }

    func testLinuxIfconfigFormatIsUnderstood() {
        let devices = WireGuardProbe.parseIfconfig([
            "wg0: flags=209<UP,POINTOPOINT,RUNNING,NOARP>  mtu 1420",
            "        inet 10.10.0.254  netmask 255.255.255.0  destination 10.10.0.254",
        ])
        XCTAssertEqual(devices["wg0"]?.mtu, 1420)
        XCTAssertEqual(devices["wg0"]?.addresses, [.init(ip: "10.10.0.254", prefix: 24)])
        XCTAssertTrue(devices["wg0"]?.looksLikeWireGuard == true)
    }

    func testSubnetArithmetic() {
        XCTAssertEqual(WireGuardProbe.Address(ip: "10.10.0.254", prefix: 24).subnet, "10.10.0.0/24")
        XCTAssertEqual(WireGuardProbe.Address(ip: "192.168.50.77", prefix: 20).subnet, "192.168.48.0/20")
        XCTAssertEqual(WireGuardProbe.Address(ip: "10.0.0.1", prefix: 0).subnet, "0.0.0.0/0")
        XCTAssertNil(WireGuardProbe.Address(ip: "fd00::1", prefix: 64).subnet)
        XCTAssertEqual(WireGuardProbe.prefixLength(netmask: "0xffffff00"), 24)
        XCTAssertEqual(WireGuardProbe.prefixLength(netmask: "255.255.0.0"), 16)
        XCTAssertNil(WireGuardProbe.prefixLength(netmask: "nonsense"))
    }

    func testWireGuardEntryCarriesTheInterface() throws {
        let scan = WireGuardProbe.parse("""
        OS Linux
        WGSTATUS ok
        D wg0\t-\tFAKE-PUBLIC-KEY-HUB-AAAAAAAAAAAAAAAAAAAAAAAAAA=\t51820\toff
        L 3: wg0: <POINTOPOINT> mtu 1420
        A 3: wg0    inet 10.10.0.254/24 scope global wg0\\
        """)
        let entry = NetworkEntry(wireGuard: try XCTUnwrap(scan.interfaces.first))
        XCTAssertEqual(entry.kind, .wireguard)
        XCTAssertEqual(entry.name, "wg0")
        XCTAssertEqual(entry.ipv4Subnet, "10.10.0.0/24")
        XCTAssertEqual(entry.driver, "WireGuard")
        XCTAssertEqual(entry.wireGuard?.listenPort, 51820)
    }

    // MARK: - The script itself

    func testScriptBlanksSecretsBeforeAnythingIsPrinted() {
        let script = WireGuardProbe.script(trySudo: true)
        XCTAssertTrue(script.contains("NF==5{$2=\"-\"}"), "interface private key column must be blanked")
        XCTAssertTrue(script.contains("NF>=9{$3=\"-\"}"), "peer preshared key column must be blanked")
        XCTAssertTrue(script.contains("show all dump"))
    }

    func testScriptIsReadOnlyAndNeverPrompts() {
        for trySudo in [true, false] {
            let script = WireGuardProbe.script(trySudo: trySudo)
            XCTAssertTrue(script.contains("TRY_SUDO=\(trySudo ? 1 : 0)"))
            XCTAssertTrue(script.contains("sudo -n"))
            XCTAssertFalse(script.contains("sudo -S"), "no password is ever fed to sudo")
            XCTAssertFalse(script.contains("sudo -A"))
            XCTAssertFalse(script.contains("read "), "nothing is read from the user")
            XCTAssertFalse(script.contains(".conf"), "wg-quick configs hold private keys and are never opened")
            XCTAssertFalse(script.contains("genkey"))
            for word in ["wg set", "wg-quick", "wg setconf", " rm ", "> /", "tee "] {
                XCTAssertFalse(script.contains(word), word)
            }
        }
    }

    func testScriptUsesAbsoluteCandidatePaths() {
        let script = WireGuardProbe.script(trySudo: false)
        for path in ["/opt/homebrew/bin/wg", "/usr/local/bin/wg", "/usr/bin/wg"] {
            XCTAssertTrue(script.contains("\"\(path)\""), path)
        }
    }

    /// The generated script must be valid shell.
    func testScriptParsesAsShell() async throws {
        for trySudo in [true, false] {
            let result = try await ProcessRunner.run(
                executable: "/bin/sh", arguments: ["-n", "-c", WireGuardProbe.script(trySudo: trySudo)], timeout: .seconds(10)
            )
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }
    }

    // MARK: - Display

    func testHandshakeIsHumanized() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en_US")
        let text = WireGuardFormat.handshake(now.addingTimeInterval(-125), now: now, locale: locale)
        XCTAssertTrue(text.contains("2") && text.contains("min"), text)
        XCTAssertTrue(text.contains("ago"), text)
        XCTAssertEqual(WireGuardFormat.handshake(nil, now: now, locale: locale), String(localized: "nigdy"))
    }

    func testShortKeyKeepsTheEndsOnly() {
        XCTAssertEqual(WireGuardFormat.shortKey("FAKE-PUBLIC-KEY-HUB-AAAAAAAAAAAAAAAAAAAAAAAAAA="), "FAKE-PUB…AAA=")
        XCTAssertEqual(WireGuardFormat.shortKey("short"), "short")
    }
}
