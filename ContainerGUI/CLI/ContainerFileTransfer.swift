import Foundation

/// Copies files in and out of a container with `tar`, for containers whose own
/// `cp` is broken.
///
/// Every container carries its own copy of the guest agent (`vminitd`), baked
/// into an `initfs` when the container is *created*. Upgrading the `container`
/// package does not refresh it, so after an upgrade every pre-existing container
/// runs an agent older than the CLI talking to it — and on 1.4.1 that agent
/// answers every copy request with `path not found`, for paths that plainly
/// exist. Downloads fail loudly; uploads exit 0 and write nothing.
///
/// `exec` still works, and so does `tar` inside the container, which is why this
/// route survives where `cp` does not. Verified against a container created
/// before the upgrade: a 1.2 MB PNG came back byte-identical (matching md5), and
/// an upload arrived intact.
enum ContainerFileTransfer {

    /// Splits a container path into the directory `tar -C` runs in and the entry
    /// name inside it. `tar` cannot be handed an absolute path without either
    /// complaining or storing it, so every transfer is expressed this way.
    static func split(_ path: String) -> (directory: String, name: String) {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed != "/", !trimmed.isEmpty else { return ("/", ".") }

        let asNSString = trimmed as NSString
        let name = asNSString.lastPathComponent
        let directory = asNSString.deletingLastPathComponent
        return (directory.isEmpty ? "/" : directory, name.isEmpty ? "." : name)
    }

    // MARK: - Download

    /// Pulls `source` out of the container and writes it to `localURL`.
    static func download(
        containerID: String,
        source: String,
        to localURL: URL,
        cli: ContainerCLI = .shared
    ) async throws {
        let (directory, name) = split(source)
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archive = workspace.appendingPathComponent("transfer.tar")
        let result = try await cli.runRedirecting(
            ["exec", containerID, "tar", "-cf", "-", "-C", directory, name],
            outputPath: archive.path
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: "")
        }

        let extracted = workspace.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await runHostTar(["-xf", archive.path, "-C", extracted.path])

        let produced = extracted.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw CLIError.command(
                exitCode: 1,
                stderr: String(format: String(localized: "Nie udało się odczytać %@ z kontenera."), source)
            )
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: produced, to: localURL)
    }

    // MARK: - Upload

    /// Pushes `localURL` into the container at `destination`, which may be either
    /// a target directory or a full target path.
    static func upload(
        containerID: String,
        localURL: URL,
        destination: String,
        cli: ContainerCLI = .shared
    ) async throws {
        let name = localURL.lastPathComponent
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // `--no-xattrs` keeps macOS from adding a provenance header that busybox
        // tar inside the container warns about on every single file.
        let archive = workspace.appendingPathComponent("transfer.tar")
        try await runHostTar([
            "--no-xattrs", "-cf", archive.path,
            "-C", localURL.deletingLastPathComponent().path, name,
        ])

        let destinationIsDirectory = await isDirectory(destination, in: containerID, cli: cli)
        let targetDirectory = destinationIsDirectory ? destination : split(destination).directory
        let finalName = destinationIsDirectory ? name : split(destination).name

        let result = try await cli.runRedirecting(
            ["exec", "-i", containerID, "tar", "-xf", "-", "-C", targetDirectory],
            inputPath: archive.path
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: "")
        }

        // `tar` restores the entry under its own name, so a destination that
        // renames the file needs one more step.
        if finalName != name {
            let from = join(targetDirectory, name)
            let to = join(targetDirectory, finalName)
            try await cli.run(["exec", containerID, "mv", from, to], timeout: .seconds(60))
        }
    }

    // MARK: - Helpers

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func isDirectory(_ path: String, in containerID: String, cli: ContainerCLI) async -> Bool {
        guard let result = try? await cli.runRaw(
            ["exec", containerID, "test", "-d", path], timeout: .seconds(20)
        ) else { return false }
        return result.exitCode == 0
    }

    /// The host's own `tar`, used to pack and unpack the archive locally.
    private static func runHostTar(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/tar",
            arguments: arguments,
            timeout: .seconds(600)
        )
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-desktop-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
