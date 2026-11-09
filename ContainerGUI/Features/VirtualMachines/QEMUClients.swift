import Foundation
import os

/// QEMU's own control socket: power, VNC password, snapshots.
///
/// The `-qmp` chardev serves one client at a time and leaves a second one
/// hanging, so there is exactly one of these per machine (`shared(for:)`).
actor QMPClient {
    private static let registry = OSAllocatedUnfairLock<[String: QMPClient]>(initialState: [:])

    static func shared(for directory: URL) -> QMPClient {
        let path = QEMULauncher.paths(for: directory).qmp
        return registry.withLock { clients in
            if let client = clients[path] { return client }
            let client = QMPClient(socketPath: path)
            clients[path] = client
            return client
        }
    }

    private let socket: QEMUSocket

    init(socketPath: String) {
        socket = QEMUSocket(path: socketPath) { socket in
            let greeting = try socket.receive(timeout: .seconds(5))
            guard greeting["QMP"] != nil else { throw QEMUSocket.Failure.protocolError("QMP greeting missing") }
            _ = try socket.execute("qmp_capabilities")
        }
    }

    /// `query-status`'s `status`: "running", "paused", "shutdown", …
    func status() async throws -> String {
        try await call { socket in
            (try socket.execute("query-status") as? [String: Any])?["status"] as? String ?? "unknown"
        }
    }

    /// The ACPI power button: the guest decides whether and how to shut down.
    func powerdown() async throws {
        try await call { _ = try $0.execute("system_powerdown") }
    }

    /// Resumes a machine started with `-S`.
    func cont() async throws {
        try await call { _ = try $0.execute("cont") }
    }

    /// Pulls the plug.
    func quit() async throws {
        do {
            try await call { _ = try $0.execute("quit") }
        } catch QEMUSocket.Failure.closed {
            // QEMU may hang up before the reply arrives; that is the point.
        }
        await socket.close()
    }

    func setVNCPassword(_ password: String) async throws {
        try await call { _ = try $0.execute("change-vnc-password", ["password": password]) }
    }

    /// An HMP command through QMP, returning what the monitor would print.
    func hmp(_ commandLine: String) async throws -> String {
        try await call {
            try $0.execute("human-monitor-command", ["command-line": commandLine]) as? String ?? ""
        }
    }

    // MARK: - Snapshots

    // HMP savevm/loadvm/delvm snapshot every writable drive, and the raw UEFI
    // vars flash cannot hold one ("Device 'pflash1' is writable but does not
    // support snapshots"). The QMP jobs take an explicit device list instead.
    // shortcut: the UEFI variables are therefore not part of a snapshot.

    func saveSnapshot(_ tag: String) async throws {
        try await runJob("snapshot-save", ["tag": tag, "vmstate": QEMULauncher.diskNode,
                                           "devices": [QEMULauncher.diskNode]])
    }

    /// Only into a freshly started, paused QEMU (`VMEngine.start(restoring:)`):
    /// loading into a process that has already saved or loaded state aborts it
    /// with "Assertion failed: (!auto_alloc || *pptr == NULL), function
    /// vmstate_load_next" (QEMU 11.1.3 with HVF; observed twice).
    func loadSnapshot(_ tag: String) async throws {
        try await runJob("snapshot-load", ["tag": tag, "vmstate": QEMULauncher.diskNode,
                                           "devices": [QEMULauncher.diskNode]])
    }

    func deleteSnapshot(_ tag: String) async throws {
        try await runJob("snapshot-delete", ["tag": tag, "devices": [QEMULauncher.diskNode]])
    }

    /// Starts a job and waits for it to conclude. Saving writes all of the
    /// guest's memory, so this can take a minute.
    private func runJob(_ command: String, _ arguments: [String: any Sendable],
                        timeout: Duration = .seconds(600)) async throws {
        do {
            try await pollJob(command, arguments, timeout: timeout)
        } catch {
            await socket.close()
            throw error
        }
        await socket.close()
    }

    /// One request, then the connection is let go: the `-qmp` chardev serves a
    /// single client, and holding it would hang anyone else's QMP tool
    /// (the spike's qmp.py included) while the app is open.
    private func call<T: Sendable>(_ body: @escaping @Sendable (QEMUSocket) throws -> T) async throws -> T {
        do {
            let value = try await socket.transact(body)
            await socket.close()
            return value
        } catch {
            await socket.close()
            throw error
        }
    }

    private func pollJob(_ command: String, _ arguments: [String: any Sendable], timeout: Duration) async throws {
        let id = "cd-\(UUID().uuidString.prefix(8))"
        try await socket.transact { socket in
            var args: [String: Any] = arguments
            args["job-id"] = id
            _ = try socket.execute(command, args)
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let outcome: String?? = try await socket.transact { socket in
                let jobs = try socket.execute("query-jobs") as? [[String: Any]] ?? []
                guard let job = jobs.first(where: { $0["id"] as? String == id }),
                      job["status"] as? String == "concluded" else { return nil }
                _ = try socket.execute("job-dismiss", ["id": id])
                return .some(job["error"] as? String)
            }
            if let outcome {
                if let error = outcome { throw QEMUSocket.Failure.qemu(error) }
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw QEMUSocket.Failure.timeout
    }
}

/// The guest agent inside the machine: commands, files, a clean shutdown.
///
/// The agent's chardev accepts a single client, and a client that went away
/// mid-reply blocks the next one — so, as with QMP, one owner per machine.
/// Every new connection starts with `guest-sync-delimited` and discards
/// everything until its own id comes back.
actor QGAClient {
    private static let registry = OSAllocatedUnfairLock<[String: QGAClient]>(initialState: [:])

    static func shared(for directory: URL) -> QGAClient {
        let path = QEMULauncher.paths(for: directory).qga
        return registry.withLock { clients in
            if let client = clients[path] { return client }
            let client = QGAClient(socketPath: path)
            clients[path] = client
            return client
        }
    }

    struct ExecResult: Sendable, Equatable {
        var exitCode: Int?
        var stdout: Data
        var stderr: Data
        /// Decoded the way a Windows console writes it.
        var output: String { OEMText.decode(stdout) }
        var errorOutput: String { OEMText.decode(stderr) }
    }

    /// Larger reads hang the Windows agent (1 MiB did, reliably).
    static let fileChunk = 256 * 1024

    private let socket: QEMUSocket

    init(socketPath: String) {
        socket = QEMUSocket(path: socketPath) { socket in
            // 0xFF resets the agent's JSON parser, whatever a previous client left in it.
            try socket.sendRaw([0xFF])
            let id = Int.random(in: 1...Int(Int32.max))
            try socket.send(["execute": "guest-sync-delimited", "arguments": ["id": id]])
            while true {
                let reply = try socket.receive(timeout: .seconds(5))
                if reply["return"] as? Int == id { return }
            }
        }
    }

    func close() async { await socket.close() }

    func ping() async throws {
        try await socket.transact { _ = try $0.execute("guest-ping", timeout: .seconds(5)) }
    }

    /// The agent's version.
    func info() async throws -> String {
        try await socket.transact {
            (try $0.execute("guest-info") as? [String: Any])?["version"] as? String ?? ""
        }
    }

    /// The guest's clock.
    func time() async throws -> Date {
        try await socket.transact {
            let nanos = try $0.execute("guest-get-time") as? Int ?? 0
            return Date(timeIntervalSince1970: Double(nanos) / 1e9)
        }
    }

    /// Asks the guest OS to shut down. The agent never answers this one on
    /// success — it is on its way out — so silence counts as yes.
    func shutdown(mode: String = "powerdown") async throws {
        do {
            try await socket.transact { socket in
                try socket.send(["execute": "guest-shutdown", "arguments": ["mode": mode]])
                let reply = try socket.receive(timeout: .seconds(3))
                if let error = reply["error"] as? [String: Any] {
                    throw QEMUSocket.Failure.qemu(error["desc"] as? String ?? "\(error)")
                }
            }
        } catch QEMUSocket.Failure.timeout {
        } catch QEMUSocket.Failure.closed {
        }
        await socket.close()
    }

    /// Runs a program and waits for it. Arguments go through glib's own
    /// re-quoting on Windows, so anything beyond plain words belongs in
    /// `runScript`.
    func exec(_ path: String, _ arguments: [String] = [], timeout: Duration = .seconds(120)) async throws -> ExecResult {
        let pid: Int = try await socket.transact { socket in
            let reply = try socket.execute("guest-exec", ["path": path, "arg": arguments, "capture-output": true])
            guard let pid = (reply as? [String: Any])?["pid"] as? Int else {
                throw QEMUSocket.Failure.protocolError("guest-exec returned no pid")
            }
            return pid
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let result: ExecResult? = try await socket.transact { socket in
                let status = try socket.execute("guest-exec-status", ["pid": pid]) as? [String: Any] ?? [:]
                guard status["exited"] as? Bool == true else { return nil }
                func data(_ key: String) -> Data {
                    (status[key] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                }
                return ExecResult(exitCode: status["exitcode"] as? Int, stdout: data("out-data"), stderr: data("err-data"))
            }
            if let result { return result }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw QEMUSocket.Failure.timeout
    }

    /// Runs a batch script on Windows without any command-line quoting: the
    /// script is written to a file and `cmd.exe /c <file>` runs it. Quoting
    /// through `cmd /c "…"` is not reliable — glib re-quotes the arguments and
    /// `copy` reads `+` as concatenation.
    func runScript(_ script: String, timeout: Duration = .seconds(300)) async throws -> ExecResult {
        let path = "C:\\Windows\\Temp\\cd-\(UUID().uuidString.prefix(8)).cmd"
        let body = script.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        try await writeFile(path, Data(body.utf8))
        let result = try await exec("cmd.exe", ["/c", path], timeout: timeout)
        _ = try? await exec("cmd.exe", ["/c", "del", "/q", path], timeout: .seconds(30))
        return result
    }

    func readFile(_ path: String) async throws -> Data {
        let handle = try await open(path, mode: "rb")
        var contents = Data()
        do {
            while true {
                let (chunk, eof): (Data, Bool) = try await socket.transact { socket in
                    let reply = try socket.execute("guest-file-read", ["handle": handle, "count": Self.fileChunk],
                                                   timeout: .seconds(60)) as? [String: Any] ?? [:]
                    let chunk = (reply["buf-b64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                    return (chunk, reply["eof"] as? Bool ?? chunk.isEmpty)
                }
                contents.append(chunk)
                if eof { break }
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
        return contents
    }

    func writeFile(_ path: String, _ data: Data) async throws {
        let handle = try await open(path, mode: "wb")
        do {
            var offset = 0
            repeat {
                let chunk = data.subdata(in: offset..<min(offset + Self.fileChunk, data.count))
                try await socket.transact { socket in
                    _ = try socket.execute("guest-file-write", ["handle": handle, "buf-b64": chunk.base64EncodedString()],
                                           timeout: .seconds(60))
                }
                offset += chunk.count
            } while offset < data.count
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
    }

    private func open(_ path: String, mode: String) async throws -> Int {
        try await socket.transact { socket in
            guard let handle = try socket.execute("guest-file-open", ["path": path, "mode": mode]) as? Int else {
                throw QEMUSocket.Failure.protocolError("guest-file-open returned no handle")
            }
            return handle
        }
    }

    private func closeFile(_ handle: Int) async throws {
        try await socket.transact { _ = try $0.execute("guest-file-close", ["handle": handle]) }
    }
}
