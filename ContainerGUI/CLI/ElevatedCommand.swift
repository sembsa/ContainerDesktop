import Foundation

/// Runs a command with administrator privileges through the standard macOS
/// authentication dialog.
///
/// The command is spliced into an AppleScript string literal, which `osascript`
/// then hands to a shell — two layers of quoting, each with its own escape
/// rules. `appleScript(executable:arguments:)` is kept pure so both layers can
/// be tested rather than reasoned about.
enum ElevatedCommand {

    static func run(
        executable: String,
        arguments: [String],
        timeout: Duration? = .seconds(600)
    ) async throws {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", appleScript(executable: executable, arguments: arguments)],
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// The AppleScript that runs `executable arguments…` as an administrator.
    static func appleScript(executable: String, arguments: [String]) -> String {
        let shellCommand = ([executable] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
        return "do shell script \"\(appleScriptQuote(shellCommand))\" with administrator privileges"
    }

    /// Single quotes for the shell; an embedded quote closes, escapes and reopens.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Backslashes first — escaping quotes first would then double their own
    /// backslashes.
    static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
