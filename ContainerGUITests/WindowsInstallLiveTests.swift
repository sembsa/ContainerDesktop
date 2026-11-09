import XCTest

/// A whole Windows install through `WindowsInstaller`, the code behind the
/// assistant: setup media, disk, the install run, the switch to a normal run,
/// and a first boot that must reach the agent at 1280×800.
///
/// Takes ~25 minutes and 8 GB of RAM, so it has its own switch:
/// `TEST_RUNNER_CD_LIVE_INSTALL=1`, with the ISO in `TEST_RUNNER_CD_WINDOWS_ISO`.
/// Deletes the machine when it passes.
final class WindowsInstallLiveTests: XCTestCase {

    func testUnattendedInstallReachesTheAgentAt1280x800() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CD_LIVE_INSTALL"] == "1", "set CD_LIVE_INSTALL=1 to run")
        let iso = URL(fileURLWithPath: try XCTUnwrap(env["CD_WINDOWS_ISO"], "CD_WINDOWS_ISO"))
        let guestTools = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ContainerGUI/Resources/GuestTools")

        let request = WindowsInstaller.Request(
            name: "Windows live install", windowsISO: iso, username: "tester",
            password: "Ab&<9-zZ", cpus: 4, memoryMiB: 8192, diskGiB: 64)
        let vm = try await WindowsInstaller.create(request, guestTools: guestTools) { phase in
            print("LIVE-INSTALL: \(phase) at \(Date())")
        }
        let dir = vm.directory
        print("LIVE-INSTALL: started \(vm.id), VNC \(vm.vncPort)")

        // Setup powers the guest off when cd-setup.cmd is done.
        let finished = await VMEngine.waitUntilStopped(dir, timeout: .seconds(45 * 60))
        XCTAssertTrue(finished, "Setup did not finish within 45 minutes")
        print("LIVE-INSTALL: setup finished at \(Date())")

        let done = try XCTUnwrap(WindowsInstaller.finishIfNeeded(try XCTUnwrap(VirtualMachineStore.load(dir))))
        XCTAssertEqual(done.display, .virtioGPU)
        XCTAssertTrue(done.extraDrives.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "setup.iso").path))

        _ = try await VMEngine.start(done, in: dir)
        let agent = QGAClient.shared(for: dir)
        var info = ""
        for _ in 0..<90 {
            if let answer = try? await agent.info() { info = answer; break }
            try await Task.sleep(for: .seconds(2))
        }
        print("LIVE-INSTALL: agent \(info)")
        XCTAssertFalse(info.isEmpty, "agent never answered")

        let video = try await agent.runScript(
            "powershell -NoProfile -Command \"(Get-CimInstance Win32_VideoController | Select-Object -First 1 | ForEach-Object { '{0}x{1}' -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution })\"")
        let whoami = try await agent.exec("cmd.exe", ["/c", "whoami"])
        print("LIVE-INSTALL: screen \(video.output.trimmingCharacters(in: .whitespacesAndNewlines)), user \(whoami.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertTrue(video.output.contains("1280x800"))
        XCTAssertTrue(whoami.output.lowercased().contains("tester"))

        try await VMEngine.stop(done, in: dir)
        _ = await VMEngine.waitUntilStopped(dir, timeout: .seconds(120))
        try FileManager.default.removeItem(at: dir)
    }
}
