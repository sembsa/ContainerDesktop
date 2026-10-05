import AppKit
import Foundation
import os

/// Builds the `ssh` command lines for an external machine. Pure, so the
/// argument order (and the absence of anything user-controlled in option
/// position) is unit-tested.
enum SSHCommand {
    private static let common = [
        // Never prompt: a GUI app has no terminal to answer on.
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        // Trust on first use, refuse if a known key later changes.
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    private static func connectionOptions(for endpoint: DockerEndpoint) -> [String] {
        var args = common
        // 22 is "unspecified": an ssh_config alias (`Host studio`) keeps its own
        // Port. Only a non-default port is passed, and so overrides the config.
        if endpoint.sshPort != DockerEndpoint.defaultSSHPort { args += ["-p", "\(endpoint.sshPort)"] }
        if let key = endpoint.identityFile, !key.isEmpty {
            args += ["-i", DockerEndpoint.expandingTilde(key), "-o", "IdentitiesOnly=yes"]
        }
        return args
    }

    /// Forwards a local unix socket to the remote engine socket.
    static func tunnel(endpoint: DockerEndpoint, localSocket: String, remoteSocket: String) -> [String] {
        ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=15"]
            + connectionOptions(for: endpoint)
            + ["-L", "\(localSocket):\(remoteSocket)", endpoint.sshTarget]
    }

    /// Runs `command` on the remote machine. Every word is single-quoted,
    /// because ssh joins the arguments into one string for the remote shell.
    static func remote(endpoint: DockerEndpoint, command: [String], tty: Bool = false) -> [String] {
        connectionOptions(for: endpoint) + (tty ? ["-t"] : []) + [endpoint.sshTarget] + [command.map(shellQuoted).joined(separator: " ")]
    }

    /// Runs the read-only probe script, fed on stdin.
    static func probe(endpoint: DockerEndpoint) -> [String] {
        connectionOptions(for: endpoint) + [endpoint.sshTarget, "/bin/sh", "-s"]
    }

    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Prints the remote user's home directory, to expand a leading `~/`.
    static func homeDirectory(endpoint: DockerEndpoint) -> [String] {
        connectionOptions(for: endpoint) + [endpoint.sshTarget, "printf", "%s", "\"$HOME\""]
    }
}

/// Owns the `ssh -L` processes behind external machines: one per endpoint,
/// restarted when its connection settings change, torn down on quit.
actor SSHTunnelManager {
    static let shared = SSHTunnelManager()

    private struct Tunnel {
        let process: Process
        let signature: String
        let localSocket: String
    }

    /// Keyed by `DockerEndpoint.tunnelKey`: machine id plus engine socket.
    private var tunnels: [String: Tunnel] = [:]
    /// Mirrors `tunnels` for synchronous readers (the terminal launcher).
    private nonisolated let sockets = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private nonisolated let processes = OSAllocatedUnfairLock<[String: Process]>(initialState: [:])

    private var terminationObserver: NSObjectProtocol?

    init() {
        // An orphaned `ssh -N` would otherwise outlive the app.
        let processes = self.processes
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            processes.withLock { $0.values.forEach { if $0.isRunning { $0.terminate() } } }
        }
    }

    /// The local socket a docker CLI should talk to, if a tunnel is up.
    nonisolated func currentSocket(for endpoint: DockerEndpoint) -> String? {
        sockets.withLock { $0[endpoint.tunnelKey] }
    }

    /// Returns the local socket for `endpoint`, opening (or re-opening) the tunnel.
    func socketPath(for endpoint: DockerEndpoint) async throws -> String {
        let key = endpoint.tunnelKey
        if let existing = tunnels[key],
           existing.signature == endpoint.connectionSignature,
           existing.process.isRunning,
           FileManager.default.fileExists(atPath: existing.localSocket) {
            return existing.localSocket
        }
        closeTunnel(key)

        let remote = try await resolveRemoteSocket(for: endpoint)
        let local = "/tmp/cdesk-\(endpoint.id.uuidString.prefix(8).lowercased())-\(Int.random(in: 1000...9999)).sock"
        try? FileManager.default.removeItem(atPath: local)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHCommand.tunnel(endpoint: endpoint, localSocket: local, remoteSocket: remote)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw CLIError.command(exitCode: -1, stderr: error.localizedDescription)
        }

        // The socket appearing is the only reliable "ready" signal; a failed
        // connection exits instead.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if !process.isRunning {
                let data = errPipe.fileHandleForReading.availableData
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIError.command(exitCode: process.terminationStatus, stderr: text.isEmpty ? "ssh exited" : text)
            }
            if FileManager.default.fileExists(atPath: local) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard FileManager.default.fileExists(atPath: local) else {
            process.terminate()
            throw CLIError.timeout(seconds: 15, command: "ssh \(endpoint.sshTarget)")
        }

        tunnels[key] = Tunnel(process: process, signature: endpoint.connectionSignature, localSocket: local)
        sockets.withLock { $0[key] = local }
        processes.withLock { $0[key] = process }
        return local
    }

    /// Closes every tunnel that belongs to a machine.
    func close(_ machine: UUID) {
        for key in tunnels.keys where key.hasPrefix(machine.uuidString + "|") { closeTunnel(key) }
    }

    private func closeTunnel(_ key: String) {
        if let tunnel = tunnels.removeValue(forKey: key) {
            if tunnel.process.isRunning { tunnel.process.terminate() }
            try? FileManager.default.removeItem(atPath: tunnel.localSocket)
        }
        sockets.withLock { _ = $0.removeValue(forKey: key) }
        processes.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// `~/x` means the *remote* home, which only the remote knows.
    private func resolveRemoteSocket(for endpoint: DockerEndpoint) async throws -> String {
        let path = endpoint.effectiveSocketPath
        guard path.hasPrefix("~/") else { return path }
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: SSHCommand.homeDirectory(endpoint: endpoint),
            timeout: .seconds(20)
        )
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw CLIError.command(exitCode: 1, stderr: "Could not determine the remote home directory.")
        }
        return home + path.dropFirst(1)
    }
}
