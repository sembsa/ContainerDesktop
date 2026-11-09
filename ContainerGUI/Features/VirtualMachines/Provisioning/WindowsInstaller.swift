import Foundation

/// Creates a Windows machine from an ISO and runs Setup unattended, end to end:
/// setup media, disk, firmware, the install run, and the switch to a normal run
/// once Setup powers the guest off.
///
/// The install survives the app quitting: QEMU runs detached, `vm.json` says
/// `installing`, and whoever next sees the machine stopped finishes it
/// (`finishIfNeeded`).
enum WindowsInstaller {

    struct Request: Sendable {
        var name: String
        var windowsISO: URL
        var username: String
        var password: String
        var cpus: Int
        var memoryMiB: Int
        var diskGiB: Int
    }

    enum Phase: Sendable, Equatable {
        case downloadingDrivers(Double)
        case preparingMedia
        case booting
        case installing
    }

    enum Failure: LocalizedError {
        case driversDownload(String)
        case firmwareMissing

        var errorDescription: String? {
            switch self {
            case .driversDownload(let detail): String(localized: "Nie udało się pobrać sterowników virtio-win: \(detail)")
            case .firmwareMissing: String(localized: "Brak firmware UEFI QEMU. Zainstaluj QEMU: brew install qemu")
            }
        }
    }

    /// Pinned, so the driver set Setup was proven with is the one it gets. The
    /// `stable-virtio` link moves.
    static let virtioURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!
    static let virtioSize: Int64 = 877_373_440

    static var cacheDirectory: URL {
        VirtualMachineStore.directory.deletingLastPathComponent().appending(path: "cache")
    }

    static let firmwareVars = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"

    // MARK: - Create

    /// Returns once Setup is running; it then takes about 20 minutes on its own.
    static func create(_ request: Request, guestTools: URL = Bundle.main.resourceURL!,
                       in root: URL = VirtualMachineStore.directory,
                       progress: @escaping @Sendable (Phase) async -> Void) async throws -> VirtualMachine {
        let virtio = try await virtioISO(progress: progress)
        await progress(.preparingMedia)

        let id = uniqueID(for: request.name, in: root)
        let dir = root.appending(path: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            // Read the language before QEMU opens the ISO: a still-mounted image
            // fails QEMU's "consistent read" lock.
            let locale = await WindowsSetupMedia.language(ofISO: request.windowsISO) ?? "pl-PL"
            let setupISO = dir.appending(path: "setup.iso")
            try await WindowsSetupMedia.buildISO(
                WindowsSetupMedia.Options(vmName: request.name, username: request.username,
                                          password: request.password, locale: locale),
                output: setupISO,
                guestTools: guestTools
            )
            _ = try await VMEngine.qemuImg(["create", "-f", "qcow2", dir.appending(path: "disk.qcow2").path, "\(request.diskGiB)G"])
            guard FileManager.default.fileExists(atPath: firmwareVars) else { throw Failure.firmwareMissing }
            try FileManager.default.copyItem(atPath: firmwareVars, toPath: dir.appending(path: "vars.fd").path)

            var vm = VirtualMachine(
                name: request.name, os: "windows", cpus: request.cpus, memoryMiB: request.memoryMiB,
                disk: "disk.qcow2",
                extraDrives: WindowsQEMUArguments.installDrives(.init(windowsISO: request.windowsISO, setupISO: setupISO, virtioISO: virtio)),
                vncPassword: VMEngine.randomPassword()
            )
            vm.id = id
            vm.installing = true
            vm.display = .ramfb
            try vm.save(to: dir)

            await progress(.booting)
            vm = try await VMEngine.start(vm, in: dir)
            await pressThroughBootPrompt(dir)
            await progress(.installing)
            return vm
        } catch {
            // Nothing half-made is left behind for the list to trip over.
            if !VMEngine.isRunning(dir) { try? FileManager.default.removeItem(at: dir) }
            throw error
        }
    }

    /// "Press any key to boot from CD or DVD" waits ~5 s. Enter every half
    /// second for 15 s gets past it; longer would land on Setup's progress
    /// screen, where Cancel has the focus.
    private static func pressThroughBootPrompt(_ dir: URL) async {
        let plan = WindowsQEMUArguments.bootKeypress
        let qmp = QMPClient.shared(for: dir)
        let clock = ContinuousClock()
        let end = clock.now + plan.duration
        while clock.now < end {
            try? await qmp.sendKey("ret")
            try? await Task.sleep(for: plan.interval)
        }
    }

    // MARK: - Finish

    /// Setup ends by powering the guest off. A stopped machine still marked
    /// `installing` is therefore done: detach the install media and switch to
    /// the display whose driver Setup staged. Returns the updated machine, or nil
    /// if there was nothing to do.
    @discardableResult
    static func finishIfNeeded(_ vm: VirtualMachine) -> VirtualMachine? {
        let dir = vm.directory
        guard vm.installing, !VMEngine.isRunning(dir) else { return nil }
        var vm = vm
        vm.installing = false
        vm.extraDrives = []
        vm.display = .virtioGPU
        guard (try? vm.save(to: dir)) != nil else { return nil }
        try? FileManager.default.removeItem(at: dir.appending(path: "setup.iso"))
        return vm
    }

    // MARK: - Pieces

    static func uniqueID(for name: String, in root: URL = VirtualMachineStore.directory) -> String {
        let slug = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = String((slug.isEmpty ? "windows" : slug).prefix(24))
        var id = base, n = 2
        while FileManager.default.fileExists(atPath: root.appending(path: id).path) {
            id = "\(base)-\(n)"; n += 1
        }
        return id
    }

    /// The virtio-win ISO, downloaded once into the cache and shared by every install.
    static func virtioISO(progress: @escaping @Sendable (Phase) async -> Void) async throws -> URL {
        let target = cacheDirectory.appending(path: virtioURL.lastPathComponent)
        if let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64, size == virtioSize {
            return target
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        await progress(.downloadingDrivers(0))
        let observer = DownloadProgress { fraction in Task { await progress(.downloadingDrivers(fraction)) } }
        let (temp, response) = try await URLSession.shared.download(from: virtioURL, delegate: observer)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.driversDownload("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path))?[.size] as? Int64
        guard size == virtioSize else { throw Failure.driversDownload(String(localized: "niepełny plik")) }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}

/// Reports a download's progress; the async `download(from:delegate:)` calls
/// the task delegate's write callbacks.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var lastReported = -1.0

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : WindowsInstaller.virtioSize
        let fraction = Double(totalBytesWritten) / Double(expected)
        // One update per percent is plenty for a progress bar.
        guard fraction - lastReported >= 0.01 else { return }
        lastReported = fraction
        report(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

extension VirtualMachineStore {
    /// `refresh`, after switching over any install that finished while nobody
    /// watched (sheet closed, app quit) — the first time it is seen stopped.
    /// Lives here rather than in `refresh` so the model stays free of the
    /// installer for the targets that share it (tests, cd-mcp).
    func refreshFinishingInstalls() {
        for vm in Self.scan(Self.directory) { WindowsInstaller.finishIfNeeded(vm) }
        refresh()
    }
}
