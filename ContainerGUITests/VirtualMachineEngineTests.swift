import XCTest

final class VirtualMachineEngineTests: XCTestCase {
    private let spikeDir = URL(fileURLWithPath: "/Users/someone/Library/Application Support/ContainerDesktop/vms/win-spike")

    // MARK: - vm.json

    func testSpikeVMJSONFromBeforeTheSchemaStillReads() throws {
        let json = #"{ "name": "Windows 11 (spike)", "os": "windows", "vncPort": 5907, "vncPassword": "abcd2345" }"#
        let vm = try JSONDecoder().decode(VirtualMachine.self, from: Data(json.utf8))
        XCTAssertEqual(vm.name, "Windows 11 (spike)")
        XCTAssertEqual(vm.vncPort, 5907)
        XCTAssertEqual(vm.cpus, 4)
        XCTAssertEqual(vm.memoryMiB, 8192)
        XCTAssertEqual(vm.disk, "disk.qcow2")
        XCTAssertEqual(vm.extraDrives, [])
        XCTAssertNil(vm.backingMachine)
    }

    func testVMJSONRoundTripsWithoutRuntimeFields() throws {
        var vm = VirtualMachine(name: "W", cpus: 6, memoryMiB: 12288, disk: "win.qcow2",
                                extraDrives: [.init(path: "/isos/virtio.iso")], vncPort: 5903, vncPassword: "x")
        vm.id = "w"
        vm.isRunning = true
        let data = try JSONEncoder().encode(vm)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("isRunning"))
        XCTAssertFalse(text.contains("\"id\""))
        var back = try JSONDecoder().decode(VirtualMachine.self, from: data)
        back.id = "w"
        back.isRunning = true
        XCTAssertEqual(back, vm)
    }

    // MARK: - Launcher

    func testArgumentsMirrorTheSpikeWithLocalTimeAndANamedDisk() {
        var vm = VirtualMachine(name: "Windows 11 (spike)", disk: "win.qcow2",
                                extraDrives: [.init(path: "/tools/virtio-win.iso")])
        vm.id = "win-spike"
        let paths = QEMULauncher.paths(for: spikeDir)
        let args = QEMULauncher.arguments(for: vm, paths: paths, vncDisplay: 7)
        let joined = args.joined(separator: " ")

        XCTAssertFalse(args.contains("-daemonize"))
        XCTAssertTrue(joined.contains("-rtc base=localtime"))
        XCTAssertTrue(joined.contains("-smp 4 -m 8192M"))
        XCTAssertTrue(joined.contains("file=\(spikeDir.path)/win.qcow2,format=qcow2,if=none,id=d0,node-name=disk0"))
        XCTAssertTrue(joined.contains("file=\(spikeDir.path)/vars.fd"))
        XCTAssertTrue(joined.contains("file=/tools/virtio-win.iso,if=none,id=x0,media=cdrom,readonly=on -device usb-storage,drive=x0,removable=on"))
        XCTAssertTrue(joined.contains("-vnc 127.0.0.1:7,password=on"))
        XCTAssertTrue(joined.contains("socket,path=\(spikeDir.path)/qga.sock,server=on,wait=off,id=qga0"))
        XCTAssertTrue(joined.contains("-qmp unix:\(spikeDir.path)/qmp.sock,server=on,wait=off"))
        // Every socket path is absolute: QEMU runs with the VM directory as cwd,
        // but the clients connect from wherever the app happens to be.
        XCTAssertTrue(paths.qmp.hasPrefix("/"))
    }

    func testLinuxGetsAUTCClockAndItsSeedOverVirtio() {
        var vm = VirtualMachine(name: "Ubuntu", os: "linux",
                                extraDrives: [.init(path: "seed.iso", cdrom: false, virtio: true)])
        vm.id = "ubuntu"
        let joined = QEMULauncher.arguments(for: vm, paths: QEMULauncher.paths(for: spikeDir), vncDisplay: 7)
            .joined(separator: " ")
        XCTAssertTrue(joined.contains("-rtc base=utc"))
        XCTAssertTrue(joined.contains("file=\(spikeDir.path)/seed.iso,if=none,id=x0,readonly=on -device virtio-blk-pci,drive=x0 "))
    }

    func testCommasInPathsAreDoubled() {
        var vm = VirtualMachine(name: "x", disk: "a,b.qcow2")
        vm.id = "x"
        let args = QEMULauncher.arguments(for: vm, paths: QEMULauncher.paths(for: URL(fileURLWithPath: "/vms/x")), vncDisplay: 1)
        XCTAssertTrue(args.contains("file=/vms/x/a,,b.qcow2,format=qcow2,if=none,id=d0,node-name=disk0"))
    }

    func testShortDirectoryKeepsItsSockets() {
        let paths = QEMULauncher.paths(for: spikeDir)
        XCTAssertEqual(paths.socketDirectory, spikeDir)
        XCTAssertLessThanOrEqual(paths.qga.utf8.count, QEMULauncher.maxSocketPathBytes)
    }

    func testLongDirectoryFallsBackToAShortStableOne() {
        let long = URL(fileURLWithPath: "/Users/someone/Library/Application Support/ContainerDesktop/vms/"
                       + String(repeating: "a-very-long-machine-name-", count: 3))
        let first = QEMULauncher.paths(for: long)
        let second = QEMULauncher.paths(for: long)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.socketDirectory.path.hasPrefix("/tmp/cd-vm-"))
        XCTAssertLessThanOrEqual(first.qmp.utf8.count, QEMULauncher.maxSocketPathBytes)
        XCTAssertEqual(first.pidFile.deletingLastPathComponent().path, long.path, "only the sockets move")
        XCTAssertNotEqual(QEMULauncher.paths(for: long.appending(path: "x")).socketDirectory, first.socketDirectory)
    }

    func testFreeDisplaySkipsAPortInUse() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(5998).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try XCTSkipIf(bound != 0, "port 5998 is taken by something else")
        listen(fd, 1)
        XCTAssertEqual(QEMULauncher.freeVNCDisplay(in: 98...99), 99)
    }

    // MARK: - OEM text

    func testCP852DecodesPolishLetters() {
        let bytes = Data([0xA5, 0x86, 0xA9, 0x88, 0xE4, 0xA2, 0x98, 0xAB, 0xBE, 0x20,
                          0xA4, 0x8F, 0xA8, 0x9D, 0xE3, 0xE0, 0x97, 0x8D, 0xBD])
        XCTAssertEqual(OEMText.decode(bytes), "ąćęłńóśźż ĄĆĘŁŃÓŚŹŻ")
    }

    func testValidUTF8IsTakenAsIs() {
        XCTAssertEqual(OEMText.decode(Data("Wyświetla zawartość".utf8)), "Wyświetla zawartość")
    }

    func testCP852TableIsComplete() {
        XCTAssertEqual(OEMText.cp852High.count, 128)
    }

    // MARK: - Snapshots

    func testParsesQemuImgSnapshotList() {
        // Verbatim from qemu-img 11.1.3.
        let output = """
        Snapshot list:
        ID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT
        1       first                 0 B 2026-11-09 10:04:56  0000:00:00.000          0
        2       2026-11-09-104200      0 B 2026-11-09 10:04:56  0000:00:00.000          0
        """
        let snapshots = VMSnapshotParser.parse(output)
        XCTAssertEqual(snapshots.map(\.tag), ["first", "2026-11-09-104200"])
        XCTAssertEqual(snapshots.first?.vmStateSize, "0 B")
        XCTAssertNotNil(snapshots.first?.date)
    }

    func testParsesHMPInfoSnapshotsFromThePartialSection() {
        // Verbatim from QEMU 11.1.3 after `snapshot-save` on the boot disk only:
        // the UEFI vars flash has no snapshot, so HMP calls ours "partial".
        let output = "List of snapshots present on all disks:\r\nNone\r\n\r\nList of partial (non-loadable) snapshots on 'd0':\r\nID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT\r\n1       cd-probe         3.13 GiB 2026-11-09 10:08:52  0000:00:59.946         --\r\n"
        let snapshots = VMSnapshotParser.parse(output)
        XCTAssertEqual(snapshots.map(\.tag), ["cd-probe"])
        XCTAssertEqual(snapshots.first?.vmStateSize, "3.13 GiB")
        XCTAssertNotNil(snapshots.first?.date)
    }

    func testATagListedInTwoSectionsCountsOnce() {
        let output = """
        List of snapshots present on all disks:
        ID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT
        --      a                 1 GiB 2026-11-09 10:08:52  0000:00:59.946         --
        List of partial (non-loadable) snapshots on 'd0':
        ID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT
        1       a                 1 GiB 2026-11-09 10:08:52  0000:00:59.946         --
        """
        XCTAssertEqual(VMSnapshotParser.parse(output).map(\.tag), ["a"])
    }

    func testNoSnapshotsParsesToNothing() {
        XCTAssertEqual(VMSnapshotParser.parse("There is no snapshot available.\r\n"), [])
        XCTAssertEqual(VMSnapshotParser.parse(""), [])
    }

    func testSanitizedTagsAreOneWord() {
        XCTAssertEqual(VMSnapshotParser.sanitize("przed aktualizacją 1/2"), "przed-aktualizacją-1-2")
    }
}
