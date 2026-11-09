import CoreGraphics
import XCTest

final class VirtualMachineSettingsTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/vms/w")

    private func gpuArgument(_ resolution: String, screen: CGSize = CGSize(width: 1512, height: 982)) -> String? {
        var vm = VirtualMachine(name: "W")
        vm.id = "w"
        vm.display = .virtioGPU
        vm.resolution = resolution
        let args = QEMULauncher.arguments(for: vm, paths: QEMULauncher.paths(for: dir), vncDisplay: 1, screen: screen)
        return args.first { $0.hasPrefix("virtio-gpu-pci") }
    }

    // MARK: - Resolution

    func testEveryPresetReachesTheLauncher() {
        XCTAssertEqual(gpuArgument("1280x800"), "virtio-gpu-pci,xres=1280,yres=800")
        XCTAssertEqual(gpuArgument("1600x1000"), "virtio-gpu-pci,xres=1600,yres=1000")
        XCTAssertEqual(gpuArgument("1920x1200"), "virtio-gpu-pci,xres=1920,yres=1200")
        XCTAssertEqual(gpuArgument("2560x1600"), "virtio-gpu-pci,xres=2560,yres=1600")
    }

    func testFitUsesTheScreenRoundedDownToEight() {
        // A 14" MacBook Pro at its default scaling.
        XCTAssertEqual(gpuArgument("fit"), "virtio-gpu-pci,xres=1512,yres=976")
    }

    func testFitIsCappedKeepingTheAspectRatio() {
        // A 32" 6K display at "more space": 3008×1692 points → ×0.851.
        XCTAssertEqual(gpuArgument("fit", screen: CGSize(width: 3008, height: 1692)), "virtio-gpu-pci,xres=2560,yres=1440")
    }

    func testNonsenseAndAMissingScreenFallBackToTheDefault() {
        XCTAssertEqual(gpuArgument("huge"), "virtio-gpu-pci,xres=1280,yres=800")
        XCTAssertEqual(gpuArgument("fit", screen: .zero), "virtio-gpu-pci,xres=1280,yres=800")
    }

    func testRamfbIgnoresTheResolution() {
        var vm = VirtualMachine(name: "W")
        vm.resolution = "1920x1200"
        let args = QEMULauncher.arguments(for: vm, paths: QEMULauncher.paths(for: dir), vncDisplay: 1)
        XCTAssertTrue(args.contains("ramfb"))
        XCTAssertFalse(args.joined().contains("xres"))
    }

    func testOldVMJSONReadsWithTheDefaultResolutionAndRoundTrips() throws {
        let old = #"{ "name": "Windows live install", "display": "virtio-gpu", "cpus": 4, "memoryMiB": 8192 }"#
        var vm = try JSONDecoder().decode(VirtualMachine.self, from: Data(old.utf8))
        XCTAssertEqual(vm.resolution, "1280x800")
        vm.resolution = "fit"
        let back = try JSONDecoder().decode(VirtualMachine.self, from: JSONEncoder().encode(vm))
        XCTAssertEqual(back.resolution, "fit")
    }

    // MARK: - Delete

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vm-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func machine(_ id: String, backing: String? = nil) throws -> (VirtualMachine, URL) {
        let dir = root.appending(path: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var vm = VirtualMachine(name: id.uppercased(), backingMachine: backing)
        try vm.save(to: dir)
        try Data("disk".utf8).write(to: dir.appending(path: "disk.qcow2"))
        vm.id = id
        return (vm, dir)
    }

    func testDeleteRefusesARunningMachine() throws {
        let (vm, dir) = try machine("a")
        // kill(pid, 0) succeeds for this very process, so the machine counts as running.
        try "\(getpid())\n".write(to: dir.appending(path: "qemu.pid"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try VMEngine.delete(vm, in: dir)) { error in
            guard case VMEngine.Failure.mustBeStopped = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testDeleteRefusesTheBaseOfACloneAndNamesTheClone() throws {
        let (base, baseDir) = try machine("a")
        let (clone, cloneDir) = try machine("a-clone", backing: "a")
        XCTAssertThrowsError(try VMEngine.delete(base, in: baseDir)) { error in
            guard case VMEngine.Failure.backsAClone(let name) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "A-CLONE")
            XCTAssertTrue(error.localizedDescription.contains("A-CLONE"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDir.path))

        // The clone itself goes, and then so can its base.
        try VMEngine.delete(clone, in: cloneDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDir.path))
        try VMEngine.delete(base, in: baseDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDir.path))
    }

    func testSizeOnDiskCountsEveryFile() throws {
        let (_, dir) = try machine("a")
        try Data(count: 100_000).write(to: dir.appending(path: "vars.fd"))
        XCTAssertGreaterThanOrEqual(VMEngine.sizeOnDisk(dir), 100_000)
    }

    // MARK: - Thumbnail

    func testThumbnailIsScaledToWidthAndWritten() throws {
        let context = CGContext(data: nil, width: 1920, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = try XCTUnwrap(VMThumbnail.scaled(context.makeImage()!, toWidth: VMThumbnail.width))
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 300)
        try VMThumbnail.write(image, to: VMThumbnail.url(in: root))
        XCTAssertEqual(VMThumbnail.load(from: root)?.width, 480)
    }
}
