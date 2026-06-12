import Foundation
import os

/// The single point of contact with the `container` binary. Serializes nothing
/// (the CLI is concurrency-safe), but isolates `Process` usage off the main actor.
actor ContainerCLI {
    static let shared = ContainerCLI()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The outcome of a finished one-shot process.
    struct CommandResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Wraps a non-Sendable `Process` so it can cross concurrency domains
    /// (termination handler / watchdog) without capturing the actor.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Bridges the one-shot termination signal to async/await. The process's
    /// `terminationHandler` (a background thread) and the awaiting task race to
    /// set/consume the continuation; the lock makes the hand-off exactly-once.
    private final class TerminationGate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Never>?, fired: Bool)>(
            initialState: (nil, false)
        )

        /// Called from the terminationHandler. Resumes the waiter if present.
        func signal() {
            let waiter = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                if state.fired { return nil }
                state.fired = true
                let c = state.continuation
                state.continuation = nil
                return c
            }
            waiter?.resume()
        }

        /// Suspends until `signal()` is (or was already) called.
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { state -> Bool in
                    if state.fired { return true }
                    state.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    // MARK: - One-shot text command

    /// Runs a command and returns trimmed stdout. Throws on non-zero exit.
    @discardableResult
    func run(_ arguments: [String], timeout: Duration? = .seconds(60)) async throws -> String {
        let result = try await execute(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        return result.stdout
    }

    /// Runs a command feeding `input` to stdin (e.g. `registry login --password-stdin`).
    @discardableResult
    func run(_ arguments: [String], input: String, timeout: Duration? = .seconds(60)) async throws -> String {
        let result = try await execute(arguments, input: input, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        return result.stdout
    }

    // MARK: - One-shot JSON command

    /// Runs a command and decodes its JSON output. When `appendFormat` is true,
    /// `--format json` is appended (list/stats style); pass `false` for commands
    /// like `inspect` that already emit JSON.
    func json<T: Decodable>(
        _ arguments: [String],
        as type: T.Type = T.self,
        appendFormat: Bool = true,
        timeout: Duration? = .seconds(60)
    ) async throws -> T {
        var args = arguments
        if appendFormat { args.append(contentsOf: ["--format", "json"]) }
        let result = try await execute(args, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw CLIError.decoding(String(localized: "pusta odpowiedź"))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
    }

    // MARK: - Raw one-shot command

    /// Runs a command and returns its raw result without throwing on a non-zero
    /// exit code. Still throws `notInstalled` (binary missing) and `timeout`.
    func runRaw(_ arguments: [String], timeout: Duration? = .seconds(60)) async throws -> CommandResult {
        try await execute(arguments, timeout: timeout)
    }

    // MARK: - Streaming command

    /// Returns a line stream for long-lived commands (`logs -f`, `stats`).
    nonisolated func stream(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        guard let binary = BinaryResolver.resolve() else {
            return AsyncThrowingStream { $0.finish(throwing: CLIError.notInstalled) }
        }
        return ProcessLineReader(binary: binary, arguments: arguments).lines()
    }

    /// Like `stream`, but finishes the stream with `CLIError.command` if the
    /// process exits non-zero (suitable for `pull`/`build` style commands where
    /// a non-zero exit is a real failure to surface to the user).
    nonisolated func streamChecked(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        guard let binary = BinaryResolver.resolve() else {
            return AsyncThrowingStream { $0.finish(throwing: CLIError.notInstalled) }
        }
        return ProcessLineReader(binary: binary, arguments: arguments, failOnNonZeroExit: true).lines()
    }

    // MARK: - Process execution

    private func execute(
        _ arguments: [String],
        input: String? = nil,
        timeout: Duration?
    ) async throws -> CommandResult {
        guard let binary = BinaryResolver.resolve() else { throw CLIError.notInstalled }
        return try await runProcess(executable: binary, arguments: arguments, input: input, timeout: timeout)
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: Duration?
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if input != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            // Detach stdin so the child can never block (or hang us) reading the
            // GUI's inherited standard input.
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
        }

        let box = ProcessBox(process)
        let didTimeOut = OSAllocatedUnfairLock<Bool>(initialState: false)
        let gate = TerminationGate()

        // Wire the termination handler BEFORE launching. It runs on a background
        // thread and only touches the gate/box — never the actor.
        box.process.terminationHandler = { _ in gate.signal() }

        // Launch. A failure here means the binary couldn't be exec'd. The handler
        // never fires in that case, so we surface the error directly.
        do {
            try box.process.run()
        } catch {
            box.process.terminationHandler = nil
            throw CLIError.notInstalled
        }

        // Feed stdin if requested. Safe now that the process is running.
        if let input, let inPipe, let data = input.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
            try? inPipe.fileHandleForWriting.close()
        }

        // Watchdog: only when a timeout is requested. Captures the box + flag,
        // not the actor.
        var watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task.detached {
                try? await Task.sleep(for: timeout)
                guard box.process.isRunning else { return }
                didTimeOut.withLock { $0 = true }
                box.process.terminate()
                try? await Task.sleep(for: .seconds(3))
                if box.process.isRunning {
                    kill(box.process.processIdentifier, SIGKILL)
                }
            }
        }

        // Start draining both pipes BEFORE awaiting termination, so a child that
        // emits more than a pipe buffer's worth of output can't block on write
        // (which would otherwise deadlock against us waiting for it to exit).
        async let outString = Self.readAll(outPipe.fileHandleForReading)
        async let errString = Self.readAll(errPipe.fileHandleForReading)
        let (out, err) = await (outString, errString)

        // EOF on both pipes implies the process has closed its descriptors; await
        // the actual termination signal to read a definitive exit status.
        await gate.wait()

        // Process is done — cancel the watchdog so it can't fire post-hoc.
        watchdog?.cancel()

        if didTimeOut.withLock({ $0 }) {
            throw CLIError.timeout(
                seconds: Int(timeout?.components.seconds ?? 0),
                command: arguments.joined(separator: " ")
            )
        }

        return CommandResult(
            stdout: out.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: err,
            exitCode: box.process.terminationStatus
        )
    }

    /// Runs a command with administrator privileges via `osascript`, prompting
    /// the user with the standard macOS authentication dialog. Required for
    /// commands the CLI documents as administrator-only (e.g. `system dns create`).
    func runElevated(_ arguments: [String], timeout: Duration? = .seconds(120)) async throws {
        guard let binary = BinaryResolver.resolve() else { throw CLIError.notInstalled }
        let shellCommand = ([binary] + arguments).map(Self.shellQuote).joined(separator: " ")
        let appleScript = "do shell script \"\(Self.appleScriptQuote(shellCommand))\" with administrator privileges"
        let result = try await runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            input: nil,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func readAll(_ handle: FileHandle) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
