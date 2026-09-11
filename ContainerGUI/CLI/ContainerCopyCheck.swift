import Foundation

/// Confirms that an uploaded file actually arrived inside a container.
///
/// `container cp` cannot be trusted to report its own failures. With a
/// version-skewed apiserver — the state a `.pkg` upgrade leaves behind — copying
/// *into* a container exits 0 and echoes the destination while writing nothing
/// at all. Copying *out* at least fails loudly; the upload direction does not,
/// so without this check the app cheerfully tells people their file was
/// transferred when it never left the host.
enum ContainerCopyCheck {
    enum Outcome: Equatable {
        case present
        case missing
        /// The check itself could not run — a `scratch` or distroless image has
        /// no `test` binary. The copy may well have worked, so this must never
        /// be reported to the user as a failure.
        case unverifiable
    }

    /// Where the file should have landed.
    ///
    /// `cp` accepts both a full target path (`/etc/app.conf`) and a target
    /// directory (`/etc`), and the two need different probes: `/etc` exists
    /// whether or not the copy happened, so checking the destination itself
    /// would pass every time.
    static func expectedPath(localPath: String, destination: String, destinationIsDirectory: Bool) -> String {
        guard destinationIsDirectory else { return destination }
        let name = (localPath as NSString).lastPathComponent
        guard !name.isEmpty else { return destination }
        return destination.hasSuffix("/") ? destination + name : destination + "/" + name
    }

    /// Looks for the file inside a running container.
    static func verify(
        containerID: String,
        localPath: String,
        destination: String,
        cli: ContainerCLI = .shared
    ) async -> Outcome {
        let isDirectory = await probe(["test", "-d", destination], in: containerID, cli: cli)
        guard isDirectory != .unverifiable else { return .unverifiable }

        let expected = expectedPath(
            localPath: localPath,
            destination: destination,
            destinationIsDirectory: isDirectory == .present
        )
        return await probe(["test", "-e", expected], in: containerID, cli: cli)
    }

    /// `container exec` propagates the command's exit status faithfully —
    /// verified against a live 1.4.1 CLI, including through `sh -c`. (The
    /// exit-code-swallowing quirk documented elsewhere is specific to
    /// `machine run`.) `test` is invoked directly rather than through a shell so
    /// there is no quoting to get wrong.
    private static func probe(_ command: [String], in containerID: String, cli: ContainerCLI) async -> Outcome {
        guard let result = try? await cli.runRaw(
            ["exec", containerID] + command, timeout: .seconds(20)
        ) else { return .unverifiable }

        switch result.exitCode {
        case 0: return .present
        case 1: return .missing
        // 126/127 mean `test` is not in the image at all; anything else is the
        // CLI failing rather than the file being absent.
        default: return .unverifiable
        }
    }

    /// The error shown when a copy reported success but left nothing behind.
    static func silentFailure(destination: String) -> CLIError {
        .command(
            exitCode: 0,
            stderr: String(
                format: String(localized: "Polecenie kopiowania zakończyło się powodzeniem, ale plik nie pojawił się w kontenerze pod ścieżką %@. Najczęstsza przyczyna: po aktualizacji pakietu container usługa w tle nadal działa w starszej wersji — uruchom ją ponownie."),
                destination
            )
        )
    }
}
