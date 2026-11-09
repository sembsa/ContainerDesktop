import Foundation

/// Registers the bundled `cd-mcp` server with AI agents.
///
/// The argv and the JSON snippet are pure so they are tested; running
/// `claude mcp add` edits the user's Claude Code config, which only the button may do.
enum MCPSetup {
    static let serverName = "container-desktop"

    /// Embedded by project.yml. `url(forAuxiliaryExecutable:)` would look in Contents/MacOS.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cd-mcp").path
    }

    static func addArguments(helperPath: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", helperPath]
    }

    /// `{"mcpServers":{"container-desktop":{"command":"<path>"}}}` — the format
    /// Claude Desktop, Cursor and most other clients read.
    static func configSnippet(helperPath: String) -> String {
        let object = ["mcpServers": [serverName: ["command": helperPath]]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func claudeCandidates(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude"]
    }

    /// A GUI app does not inherit the shell PATH, so the well-known places come
    /// first and the login shell (npm/nvm installs) last.
    static func resolveClaude() async -> String? {
        if let path = claudeCandidates().first(where: FileManager.default.isExecutableFile(atPath:)) {
            return path
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await ProcessRunner.run(
            executable: shell, arguments: ["-lc", "command -v claude"], timeout: .seconds(10)
        ), result.exitCode == 0 else { return nil }
        let path = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs `claude mcp add …` and returns what to show the user.
    static func addToClaudeCode() async -> (ok: Bool, message: String) {
        guard let claude = await resolveClaude() else {
            return (false, String(localized: "Nie znaleziono polecenia claude. Zainstaluj Claude Code albo użyj „Kopiuj konfigurację”."))
        }
        do {
            let result = try await ProcessRunner.run(
                executable: claude, arguments: addArguments(helperPath: helperPath), timeout: .seconds(30)
            )
            let output = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return (result.exitCode == 0, output.isEmpty ? String(localized: "Dodano do Claude Code.") : output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
