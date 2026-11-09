import XCTest

/// Drives a real QEMU machine through the engine the app uses. Skipped unless
/// `CD_LIVE=1`; the machine is `CD_VM` (default `win-spike`) under the app's
/// vms directory and has to be a Windows guest with the agent installed.
/// Leaves the machine running, started by the launcher.
final class VirtualMachineLiveTests: XCTestCase {
    private var dir: URL {
        VirtualMachineStore.directory.appending(path: ProcessInfo.processInfo.environment["CD_VM"] ?? "win-spike")
    }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CD_LIVE"] == "1", "set CD_LIVE=1 to run")
    }

    func testStopStartAgentClockAndSnapshots() async throws {
        let vm = try XCTUnwrap(VirtualMachineStore.load(dir))
        let agent = QGAClient.shared(for: dir)

        if vm.isRunning {
            try await waitForAgent(agent)
            try await VMEngine.stop(vm, in: dir)
            let stopped = await VMEngine.waitUntilStopped(dir, timeout: .seconds(120))
            XCTAssertTrue(stopped, "graceful stop")
            print("LIVE: stopped gracefully")
        }

        let started = try await VMEngine.start(try XCTUnwrap(VirtualMachineStore.load(dir)), in: dir)
        print("LIVE: started, VNC port \(started.vncPort)")
        let banner = try rfbBanner(port: started.vncPort)
        print("LIVE: VNC banner \(banner.debugDescription)")
        XCTAssertEqual(banner, "RFB 003.008\n")

        try await waitForAgent(agent)
        let bootedAt = Date()
        print("LIVE: agent \(try await agent.info())")

        let ver = try await agent.exec("cmd.exe", ["/c", "ver"])
        print("LIVE: ver -> \(ver.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertTrue(ver.output.contains("Windows"))

        // `ver` has no diacritics (the guest UI is English), but cmd prints file
        // names in the OEM code page: a file written through the agent, whose
        // paths are UTF-8, comes back from `dir` as CP852.
        let name = "cd-zażółć-ĄĘŚŃŹ.txt"
        try await agent.writeFile("C:\\Windows\\Temp\\\(name)", Data("x".utf8))
        let listing = try await agent.exec("cmd.exe", ["/c", "dir", "/b", "C:\\Windows\\Temp\\cd-*.txt"])
        print("LIVE: dir bytes \(listing.stdout.map { String(format: "%02X", $0) }.joined(separator: " "))")
        print("LIVE: dir -> \(listing.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertTrue(listing.output.contains(name), listing.output)
        let readBack = try await agent.readFile("C:\\Windows\\Temp\\\(name)")
        XCTAssertEqual(readBack, Data("x".utf8))
        _ = try await agent.runScript("@del /q C:\\Windows\\Temp\\cd-*.txt")

        // Clock: the guest's UTC and its local wall clock against the host's.
        let guestNow = try await agent.time()
        let drift = guestNow.timeIntervalSinceNow
        print("LIVE: guest-get-time drift \(String(format: "%.1f", drift)) s, \(Date().timeIntervalSince(bootedAt)) s after agent came up")
        XCTAssertLessThan(abs(drift), 120)
        let wall = try await agent.runScript("@echo off\r\necho %DATE% %TIME%")
        let host = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        print("LIVE: guest wall clock \(wall.output.trimmingCharacters(in: .whitespacesAndNewlines)) / host \(host)")

        // Snapshots, live.
        let tag = "cd-live-\(VMEngine.suggestedSnapshotTag())"
        let saveStart = Date()
        try await VMEngine.createSnapshot(tag, of: vm, in: dir)
        print("LIVE: snapshot-save took \(Int(Date().timeIntervalSince(saveStart))) s")
        let raw = try await QMPClient.shared(for: dir).hmp("info snapshots")
        print("LIVE: info snapshots -> \(raw.debugDescription)")
        let listed = try await VMEngine.snapshots(of: vm, in: dir)
        XCTAssertTrue(listed.contains { $0.tag == tag }, "\(listed)")
        try await VMEngine.deleteSnapshot(tag, of: vm, in: dir)
        let after = try await VMEngine.snapshots(of: vm, in: dir)
        XCTAssertFalse(after.contains { $0.tag == tag })
        print("LIVE: snapshot \(tag) created, listed, deleted; still running: \(VMEngine.isRunning(dir))")
        XCTAssertTrue(VMEngine.isRunning(dir))
        await agent.close()
    }

    /// Runs before the test above (alphabetical): stops the machine, clones
    /// it, and on the clone checks a live restore really goes back in time,
    /// force stop, and the offline `qemu-img` snapshot path. The clone is
    /// deleted afterwards so the original may boot again.
    func testCloneLiveRestoreForceStopAndOfflineSnapshots() async throws {
        let original = try XCTUnwrap(VirtualMachineStore.load(dir))
        if original.isRunning {
            let agent = QGAClient.shared(for: dir)
            try await waitForAgent(agent)
            try await VMEngine.stop(original, in: dir)
            let stopped = await VMEngine.waitUntilStopped(dir, timeout: .seconds(120))
            XCTAssertTrue(stopped)
        }
        var clone = try await VMEngine.clone(original, named: "Live clone", in: dir)
        let cloneDir = VirtualMachineStore.directory.appending(path: clone.id)
        defer {
            if let pid = VirtualMachineStore.runningPID(pidFile: cloneDir.appending(path: "qemu.pid")) { kill(pid, SIGKILL) }
            if let log = try? String(contentsOf: cloneDir.appending(path: "qemu.log"), encoding: .utf8) {
                print("LIVE: clone qemu.log -> \(log.debugDescription)")
            }
            try? FileManager.default.removeItem(at: cloneDir)
        }
        print("LIVE: cloned into \(clone.id), disk \(try FileManager.default.attributesOfItem(atPath: cloneDir.appending(path: "disk.qcow2").path)[.size] ?? 0) bytes")

        do {
            _ = try await VMEngine.start(original, in: dir)
            XCTFail("the clone's base must refuse to start")
        } catch QEMULauncher.Failure.backsAClone(let name) {
            print("LIVE: original refused to start, backs \(name)")
        }

        clone.memoryMiB = 4096
        try clone.save(to: cloneDir)
        clone = try await VMEngine.start(clone, in: cloneDir)
        let agent = QGAClient.shared(for: cloneDir)
        try await waitForAgent(agent)
        let marker = "C:\\Windows\\Temp\\cd-marker.txt"
        print("LIVE: clone agent up")
        try await agent.writeFile(marker, Data("before".utf8))
        try await VMEngine.createSnapshot("live-a", of: clone, in: cloneDir)
        try await agent.writeFile(marker, Data("after".utf8))
        print("LIVE: clone snapshot saved, marker rewritten")
        try await VMEngine.restoreSnapshot("live-a", of: clone, in: cloneDir)
        await agent.close()
        try await waitForAgent(agent)
        let restored = String(decoding: try await agent.readFile(marker), as: UTF8.self)
        print("LIVE: marker after live restore -> \(restored)")
        XCTAssertEqual(restored, "before")
        // Saving in a process that has loaded state must work too.
        try await VMEngine.createSnapshot("live-c", of: clone, in: cloneDir)
        try await VMEngine.createSnapshot("live-d", of: clone, in: cloneDir)
        print("LIVE: two more live snapshots after the restore")
        await agent.close()

        try await VMEngine.forceStop(clone, in: cloneDir)
        let forced = await VMEngine.waitUntilStopped(cloneDir, timeout: .seconds(20))
        XCTAssertTrue(forced)
        print("LIVE: force stop ok")

        try await VMEngine.createSnapshot("offline-b", of: clone, in: cloneDir)
        let offline = try await VMEngine.snapshots(of: clone, in: cloneDir)
        print("LIVE: offline snapshots -> \(offline.map { "\($0.tag) \($0.vmStateSize)" })")
        XCTAssertEqual(Set(offline.map(\.tag)), ["live-a", "live-c", "live-d", "offline-b"])
        try await VMEngine.restoreSnapshot("offline-b", of: clone, in: cloneDir)
        XCTAssertFalse(VMEngine.isRunning(cloneDir), "a disk-only restore of a stopped machine leaves it stopped")
        for tag in ["offline-b", "live-a", "live-c", "live-d"] {
            try await VMEngine.deleteSnapshot(tag, of: clone, in: cloneDir)
        }
        let remaining = try await VMEngine.snapshots(of: clone, in: cloneDir)
        XCTAssertEqual(remaining, [])
    }

    private func waitForAgent(_ agent: QGAClient, timeout: Duration = .seconds(240)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await agent.ping()) != nil { return }
            try await Task.sleep(for: .seconds(2))
        }
        XCTFail("guest agent did not answer")
        throw QEMUSocket.Failure.timeout
    }

    /// The first 12 bytes a VNC server sends.
    private func rfbBanner(port: UInt16) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        var bytes = [UInt8](repeating: 0, count: 12)
        var got = 0
        while got < 12 {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, 12 - got) }
            guard n > 0 else { break }
            got += n
        }
        return String(decoding: bytes[0..<got], as: UTF8.self)
    }
}
