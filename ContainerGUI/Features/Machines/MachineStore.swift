import Foundation
import Observation

@MainActor @Observable
final class MachineStore {
    var items: [MachineInfo] = []
    var isLoading = false
    var error: CLIError?
    /// Machines with an action in flight, so the UI can disable their controls
    /// instead of letting a second stop or boot pile onto the first.
    var busyNames: Set<String> = []

    private let cli = ContainerCLI.shared

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            items = try await cli.json(["machine", "ls"], as: [MachineInfo].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    // MARK: - Create

    /// Streams `machine create`, which fetches and unpacks an image before booting
    /// the VM. A one-shot call with a timeout is the wrong shape for that: the
    /// CLI reports `[1/3] Fetching image` style progress worth showing.
    nonisolated func createStream(_ options: MachineCommands.CreateOptions) -> AsyncThrowingStream<String, Error> {
        ContainerCLI.shared.streamChecked(MachineCommands.create(options))
    }

    // MARK: - Lifecycle

    /// Boots a stopped machine. There is no `machine start` subcommand — this goes
    /// through `machine run`, which boots the machine if necessary.
    func boot(_ machine: MachineInfo) async throws {
        try await withBusy(machine.name) {
            try await cli.run(MachineCommands.boot(name: machine.name), timeout: .seconds(300))
        }
        await refresh()
    }

    func stop(_ machine: MachineInfo) async throws {
        try await withBusy(machine.name) {
            try await cli.run(["machine", "stop", machine.name], timeout: .seconds(300))
        }
        await refresh()
    }

    func delete(_ machine: MachineInfo) async throws {
        try await withBusy(machine.name) {
            try await cli.run(["machine", "delete", machine.name], timeout: .seconds(300))
        }
        await refresh()
    }

    func setDefault(_ machine: MachineInfo) async throws {
        try await cli.run(["machine", "set-default", machine.name])
        await refresh()
    }

    // MARK: - Configuration

    /// Applies `machine set`. Returns the CLI's own reply, which is where the
    /// "changes take effect after restarting" note comes from — worth showing
    /// verbatim, because `machine ls` starts reporting the new numbers straight
    /// away while the running VM still has the old ones.
    @discardableResult
    func apply(_ settings: [MachineCommands.Setting], to machine: MachineInfo) async throws -> String {
        let arguments = MachineCommands.set(name: machine.name, settings: settings)
        guard !arguments.isEmpty else { return "" }
        let output = try await withBusy(machine.name) {
            try await cli.run(arguments, timeout: .seconds(60))
        }
        await refresh()
        return output
    }

    // MARK: - Provisioning

    /// Streams `apk add` inside the machine, so a 260 MB desktop install reports
    /// progress instead of hanging behind a spinner.
    nonisolated func provisionStream(packages: [String], on name: String) -> AsyncThrowingStream<String, Error> {
        let arguments = MachineCommands.install(packages: packages, on: name)
        guard !arguments.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return ContainerCLI.shared.streamChecked(arguments)
    }

    /// Waits until the machine will actually run a command.
    ///
    /// `machine create` returns before that is true: running anything two seconds
    /// later fails with "Operation not supported by device", which is what made
    /// a template's packages fail to install on a machine that had just been
    /// created. Verified by creating a machine and probing it in a loop.
    func waitUntilReady(_ name: String, attempts: Int = 30) async -> Bool {
        for _ in 0..<attempts {
            if (try? await cli.run(MachineCommands.readinessProbe(name: name), timeout: .seconds(30))) != nil {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: - Desktop

    /// Passwords live here and nowhere else — in memory, for this run of the app.
    /// Writing a VNC password to UserDefaults would leave it on disk in the clear;
    /// if it is lost, connecting again simply mints a new one.
    private(set) var desktopPasswords: [String: String] = [:]

    /// Whether the machine already carries the desktop stack.
    ///
    /// The probe is the window manager rather than the VNC server, and that is
    /// deliberate: a machine provisioned before fluxbox was found to segfault has
    /// x11vnc but no working window manager, and connecting to it shows a black
    /// screen. Asking about icewm makes those machines offer the install again,
    /// which repairs them.
    func hasDesktop(_ machine: MachineInfo) async -> Bool {
        do {
            _ = try await cli.run(
                ["machine", "run", "-n", machine.name, "--", "which", "icewm"],
                timeout: .seconds(60)
            )
            return true
        } catch {
            return false
        }
    }

    /// Stores a password, brings the X server, window manager and VNC server up,
    /// and hands back the password to show once.
    ///
    /// The three services are started blind rather than probed first: none of them
    /// survives a machine restart — Alpine's init does not run in a machine, which
    /// the boot log says out loud — and starting one that is already up merely
    /// fails, which is why those failures are ignored while the password write is
    /// not.
    @discardableResult
    func startDesktop(_ machine: MachineInfo) async throws -> String {
        let password = desktopPasswords[machine.name] ?? MachineDesktop.generatePassword()
        try await withBusy(machine.name) {
            try await cli.run(
                MachineCommands.desktopStorePassword(name: machine.name, password: password),
                timeout: .seconds(60)
            )
            for arguments in [
                MachineCommands.desktopDisplayServer(name: machine.name),
                MachineCommands.desktopWindowManager(name: machine.name),
                MachineCommands.desktopTerminal(name: machine.name),
                MachineCommands.desktopVNCServer(name: machine.name),
            ] {
                _ = try? await cli.run(arguments, timeout: .seconds(60))
            }
        }
        desktopPasswords[machine.name] = password
        await refresh()
        return password
    }

    // MARK: - Inspect

    /// `machine inspect` prints JSON already and rejects `--format`, hence
    /// `appendFormat: false`. It answers with a single-element array.
    func inspect(_ name: String) async throws -> MachineInspect {
        let results = try await cli.json(
            ["machine", "inspect", name],
            as: [MachineInspect].self,
            appendFormat: false
        )
        guard let first = results.first else {
            throw CLIError.decoding(String(localized: "pusta odpowiedź"))
        }
        return first
    }

    // MARK: - Helpers

    private func withBusy<T>(_ name: String, _ action: () async throws -> T) async throws -> T {
        busyNames.insert(name)
        defer { busyNames.remove(name) }
        return try await action()
    }
}
