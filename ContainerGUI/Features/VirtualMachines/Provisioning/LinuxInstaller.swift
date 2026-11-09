import CryptoKit
import Foundation

/// Creates an Ubuntu machine from the official ARM64 cloud image and a
/// cloud-init seed (`LinuxCloudInit`). There is no installer: the first boot
/// configures the system, then powers it off.
///
/// "Done" works exactly as for Windows: `vm.json` says `installing`, the guest
/// powers itself off at the end of cloud-init (`power_state`), and whoever next
/// sees the machine stopped finishes it — `WindowsInstaller.finishIfNeeded`,
/// which drops the seed CD and clears the flag. A `cloud-init status` poll
/// would not do: it reports "done" a moment before `power_state` takes the
/// guest down.
enum LinuxInstaller {

    struct Request: Sendable {
        var name: String
        var username: String
        var password: String
        var cpus: Int
        var memoryMiB: Int
        var diskGiB: Int
        var desktop: Bool
        var language: LinuxCloudInit.Language
        var keyboard: String
    }

    enum Phase: Sendable, Equatable {
        case downloadingImage(Double)
        case preparingDisk
        case booting
        case configuring
    }

    enum Failure: LocalizedError {
        case imageDownload(String)
        case firmwareMissing

        var errorDescription: String? {
            switch self {
            case .imageDownload(let detail): String(localized: "Nie udało się pobrać obrazu Ubuntu: \(detail)")
            case .firmwareMissing: String(localized: "Brak firmware UEFI QEMU. Zainstaluj QEMU: brew install qemu")
            }
        }
    }

    /// Pinned to a dated release directory: `current/` moves. The checksum is
    /// the image's line in that directory's SHA256SUMS.
    static let imageURL = URL(string: "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-arm64.img")!
    static let imageSHA256 = "50e24e1fb79e89116e939d90aa7738f7af48c442fa1bc2510131e0b39c50348e"
    static let imageSize: Int64 = 616_522_752

    /// Named after the release, so a newer pin downloads beside the old one
    /// instead of being mistaken for it.
    static var cachedImage: URL {
        WindowsInstaller.cacheDirectory.appending(path: "ubuntu-24.04-arm64-20261017.img")
    }

    static let seedFile = "seed.iso"

    // MARK: - Create

    /// Returns once the guest is booting with its seed; cloud-init then takes
    /// about a minute on its own (more with a desktop) and powers the machine off.
    static func create(_ request: Request, in root: URL = VirtualMachineStore.directory,
                       progress: @escaping @Sendable (Phase) async -> Void) async throws -> VirtualMachine {
        let image = try await cloudImage(progress: progress)
        await progress(.preparingDisk)

        let id = WindowsInstaller.uniqueID(for: request.name, in: root, fallback: "ubuntu")
        let dir = root.appending(path: id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            // A clone of the cached image (APFS copies it in no time and no
            // space) rather than an overlay on it: the machine must survive the
            // cache being cleared or moved to a newer release.
            let disk = dir.appending(path: "disk.qcow2")
            try fm.copyItem(at: image, to: disk)
            try await VMEngine.qemuImg(["resize", disk.path, "\(request.diskGiB)G"])
            guard fm.fileExists(atPath: WindowsInstaller.firmwareVars) else { throw Failure.firmwareMissing }
            try fm.copyItem(atPath: WindowsInstaller.firmwareVars, toPath: dir.appending(path: "vars.fd").path)

            let options = LinuxCloudInit.Options(
                hostname: LinuxCloudInit.hostname(from: id), username: request.username,
                password: request.password, desktop: request.desktop,
                language: request.language, keyboard: request.keyboard)
            try await LinuxCloudInit.buildSeedISO(options, instanceID: "\(id)-\(UUID().uuidString.prefix(8))",
                                                  output: dir.appending(path: seedFile))

            var vm = VirtualMachine(
                name: request.name, os: "linux", cpus: request.cpus, memoryMiB: request.memoryMiB,
                disk: "disk.qcow2", extraDrives: [.init(path: seedFile, cdrom: false, virtio: true)],
                vncPassword: VMEngine.randomPassword())
            vm.id = id
            vm.installing = true
            vm.display = .virtioGPU
            try vm.save(to: dir)

            await progress(.booting)
            vm = try await VMEngine.start(vm, in: dir)
            await progress(.configuring)
            return vm
        } catch {
            if !VMEngine.isRunning(dir) { try? fm.removeItem(at: dir) }
            throw error
        }
    }

    // MARK: - Image

    /// The cloud image, downloaded and checked once, then shared by every machine.
    static func cloudImage(progress: @escaping @Sendable (Phase) async -> Void) async throws -> URL {
        let target = cachedImage
        // `download` moves a file into place only after `verify` passed.
        if FileManager.default.fileExists(atPath: target.path) { return target }
        await progress(.downloadingImage(0))
        do {
            try await WindowsInstaller.download(imageURL, to: target, expectedSize: imageSize, verify: { file in
                guard try sha256(of: file) == imageSHA256 else {
                    throw WindowsInstaller.DownloadFailure(detail: String(localized: "suma kontrolna się nie zgadza"))
                }
            }, progress: { await progress(.downloadingImage($0)) })
        } catch let failure as WindowsInstaller.DownloadFailure {
            throw Failure.imageDownload(failure.detail)
        }
        return target
    }

    /// Hex SHA-256 of a file, read in pieces rather than all at once.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
