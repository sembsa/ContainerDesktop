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

    /// Which graphical environment the machine already carries, if any.
    func installedEnvironment(_ machine: MachineInfo) async -> MachineDesktopEnvironment? {
        for environment in MachineDesktopEnvironment.allCases {
            let probe = MachineCommands.whichProbe(name: machine.name, binary: environment.marker)
            if (try? await cli.run(probe, timeout: .seconds(60))) != nil { return environment }
        }
        return nil
    }

    /// Waits for a process to appear inside the machine.
    ///
    /// The probe is a direct `pgrep`, never `sh -c`: exit codes do not survive the
    /// shell form — `machine run -- /bin/sh -c 'exit 3'` reports 0 — so a shell
    /// probe would always say yes.
    func waitForProcess(_ process: String, in name: String, attempts: Int = 20) async -> Bool {
        for _ in 0..<attempts {
            let probe = MachineCommands.processProbe(name: name, process: process)
            if (try? await cli.run(probe, timeout: .seconds(30))) != nil { return true }
            try? await Task.sleep(for: .milliseconds(750))
        }
        return false
    }

    /// Stores a password, brings the session up in order, and hands back the
    /// password to show once.
    ///
    /// Each step waits for the previous one to actually be running. Firing them
    /// back to back is what left a connected session with a terminal it could not
    /// type into: the window manager started before the X server was listening,
    /// died, and nothing was there to give any window focus — while every command
    /// had reported success, because a detached start reports success immediately.
    ///
    /// None of these survive a machine restart (Alpine's init does not run in a
    /// machine, which its boot log says out loud), so this is safe to call again
    /// and is how a stopped-and-started machine gets its desktop back.
    @discardableResult
    func startDesktop(
        _ machine: MachineInfo,
        environment: MachineDesktopEnvironment
    ) async throws -> String {
        let password = desktopPasswords[machine.name] ?? MachineDesktop.generatePassword()
        let name = machine.name
        try await withBusy(name) {
            try await cli.run(
                MachineCommands.desktopStorePassword(name: name, password: password),
                timeout: .seconds(60)
            )

            _ = try? await cli.run(MachineCommands.desktopDisplayServer(name: name), timeout: .seconds(60))
            guard await waitForProcess("Xvfb", in: name) else {
                throw CLIError.command(exitCode: -1, stderr: String(localized: "Serwer X nie wystartował."))
            }

            _ = try? await cli.run(
                MachineCommands.desktopSession(name: name, environment: environment),
                timeout: .seconds(120)
            )
            guard await waitForProcess(environment.probeProcess, in: name) else {
                throw CLIError.command(exitCode: -1, stderr: String(localized: "Środowisko graficzne nie wystartowało."))
            }

            if !environment.providesTerminal {
                _ = try? await cli.run(MachineCommands.desktopTerminal(name: name), timeout: .seconds(60))
            }

            _ = try? await cli.run(MachineCommands.desktopVNCServer(name: name), timeout: .seconds(60))
            guard await waitForProcess("x11vnc", in: name) else {
                throw CLIError.command(exitCode: -1, stderr: String(localized: "Serwer VNC nie wystartował."))
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
