import Foundation
import Observation

@MainActor @Observable
final class VolumeStore {
    var items: [VolumeInfo] = []
    var isLoading = false
    var error: CLIError?

    private let cli = ContainerCLI.shared

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            items = try await cli.json(["volume", "ls"], as: [VolumeInfo].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    func create(name: String, size: String?) async throws {
        var args = ["volume", "create"]
        if let size, !size.isEmpty { args.append(contentsOf: ["-s", size]) }
        args.append(name)
        try await cli.run(args)
        await refresh()
    }

    func remove(_ volume: VolumeInfo) async throws {
        try await cli.run(["volume", "rm", volume.name])
        await refresh()
    }

    func prune() async throws {
        try await cli.run(["volume", "prune"])
        await refresh()
    }

    func inspect(_ name: String) async throws -> String {
        try await cli.run(["volume", "inspect", name])
    }

    // MARK: - File browsing (via an ephemeral helper container + cp)

    /// Image used as a throwaway helper to mount the volume. Alpine is small and
    /// ships `ls`/`sh`; it is pulled automatically if missing.
    private let helperImage = "alpine:latest"

    func listFiles(_ volume: VolumeInfo, path: String) async throws -> [FileEntry] {
        let output = try await cli.run(
            ["run", "--rm", "--progress", "none", "-v", "\(volume.name):/volume", helperImage, "ls", "-la", mountedPath(path)]
        )
        return FileEntry.parse(lsOutput: output)
    }

    func copyToVolume(_ volume: VolumeInfo, localPath: String, destination: String) async throws {
        try await withHelper(volume) { helper in
            try await self.cli.run(["cp", localPath, "\(helper):\(self.mountedPath(destination))"])
        }
    }

    func copyFromVolume(_ volume: VolumeInfo, source: String, localPath: String) async throws {
        try await withHelper(volume) { helper in
            try await self.cli.run(["cp", "\(helper):\(self.mountedPath(source))", localPath])
        }
    }

    private func withHelper(_ volume: VolumeInfo, _ body: (String) async throws -> Void) async throws {
        let helper = "cgui-helper-" + UUID().uuidString.prefix(8).lowercased()
        try await cli.run(["run", "-d", "--progress", "none", "--name", helper, "-v", "\(volume.name):/volume", helperImage, "sleep", "120"])
        do {
            try await body(helper)
            _ = try? await cli.run(["rm", "--force", helper])
        } catch {
            _ = try? await cli.run(["rm", "--force", helper])
            throw error
        }
    }

    /// Maps a volume-rooted path (e.g. `/sub/file`) to the helper mount (`/volume/sub/file`).
    private func mountedPath(_ path: String) -> String {
        path == "/" || path.isEmpty ? "/volume" : "/volume" + (path.hasPrefix("/") ? path : "/" + path)
    }
}
