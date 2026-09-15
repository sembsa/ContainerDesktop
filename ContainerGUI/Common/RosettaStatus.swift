import Foundation

/// Whether Rosetta is available, and how to install it.
///
/// `container` turns Rosetta on for *any* `amd64` image running on an arm64
/// host — the `--rosetta` flag is not required for it
/// (`config.rosetta = management.rosetta || (host == arm64 && requested == amd64)`).
/// So without Rosetta, every x86-64 image simply fails to run, and a major
/// macOS upgrade is the usual reason it goes missing.
enum RosettaStatus {

    enum Availability: Equatable, Sendable {
        /// Not an Apple silicon Mac; Rosetta is meaningless here.
        case notApplicable
        case installed
        case missing
    }

    /// Installed by `softwareupdate --install-rosetta`.
    static let runtimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    static let installExecutable = "/usr/sbin/softwareupdate"

    /// `--agree-to-license` accepts Apple's licence on the user's behalf.
    /// Without it the installer waits for a terminal confirmation that a GUI app
    /// cannot answer, so the UI says plainly what the button agrees to.
    static let installArguments = ["--install-rosetta", "--agree-to-license"]

    /// Decided from inputs rather than read from the machine, so the rule can be
    /// tested on any host.
    static func availability(architecture: String, runtimeExists: Bool) -> Availability {
        guard architecture == "arm64" else { return .notApplicable }
        return runtimeExists ? .installed : .missing
    }

    /// The running Mac.
    ///
    /// Deliberately a file check and not `arch -x86_64 …`: running an x86-64
    /// binary without Rosetta makes macOS put up its own install dialog, and an
    /// app should not spring that on someone merely by launching.
    static func current(
        architecture: String = hostArchitecture(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Availability {
        // Short-circuit before touching the disk: on a machine where Rosetta is
        // meaningless there is nothing worth looking for.
        guard architecture == "arm64" else { return .notApplicable }
        return availability(architecture: architecture, runtimeExists: fileExists(runtimePath))
    }

    static func hostArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    static func install() async throws {
        try await ElevatedCommand.run(
            executable: installExecutable,
            arguments: installArguments,
            timeout: .seconds(900)
        )
    }
}
