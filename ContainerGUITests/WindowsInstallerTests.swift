import XCTest

/// The install flow's bookkeeping; the install itself was run live (test B).
final class WindowsInstallerTests: XCTestCase {

    func testMachineIDsAreSlugsAndNeverReuseAFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "windows-11"), withIntermediateDirectories: true)

        XCTAssertEqual(WindowsInstaller.uniqueID(for: "Windows 11", in: root), "windows-11-2")
        // Diacritics fold; ł has no decomposition, so it stays — a valid folder name either way.
        XCTAssertEqual(WindowsInstaller.uniqueID(for: "Zażółć gęślą", in: root), "zazołc-gesla")
        XCTAssertEqual(WindowsInstaller.uniqueID(for: "  ", in: root), "windows")
    }

    func testAnOlderVMJSONReadsAsAFinishedRamfbMachine() throws {
        let json = #"{"name":"Old","extraDrives":[{"path":"/x.iso"}]}"#
        let vm = try JSONDecoder().decode(VirtualMachine.self, from: Data(json.utf8))
        XCTAssertEqual(vm.display, .ramfb)
        XCTAssertFalse(vm.installing)
        XCTAssertNil(vm.extraDrives.first?.bootIndex)
    }

    func testInstallStateRoundTrips() throws {
        var vm = VirtualMachine(name: "New", extraDrives: [.init(path: "/w.iso", bootIndex: 2)])
        vm.installing = true
        vm.display = .virtioGPU
        let back = try JSONDecoder().decode(VirtualMachine.self, from: JSONEncoder().encode(vm))
        XCTAssertTrue(back.installing)
        XCTAssertEqual(back.display, .virtioGPU)
        XCTAssertEqual(back.extraDrives.first?.bootIndex, 2)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(vm), as: UTF8.self).contains(#""display":"virtio-gpu""#))
    }
}
