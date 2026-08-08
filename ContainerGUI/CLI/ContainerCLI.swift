import Foundation

/// The single point of contact with the `container` binary. Serializes nothing
/// (the CLI is concurrency-safe), but isolates `Process` usage off the main actor.
actor ContainerCLI {
    static let shared = ContainerCLI()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Process plumbing lives in `ProcessRunner`, shared with `HelmCLI`.
    typealias CommandResult = ProcessRunner.CommandResult

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
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            input: input,
            timeout: timeout
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
}
