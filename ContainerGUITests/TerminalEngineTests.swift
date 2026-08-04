import XCTest

/// Verifies the terminal engine flag and the command line handed to Ghostty.
///
/// Ghostty takes the child process as a single `command` config line, so the
/// quoting is the part that can silently break: the path to the `container` CLI
/// is user-configurable in Settings and may contain spaces.
final class TerminalEngineTests: XCTestCase {

    // MARK: - Raw command

    func testJoinsExecutableAndArguments() {
        let command = TerminalCommandLine.rawCommand(
            executable: "/usr/local/bin/container",
            arguments: ["exec", "-it", "acme-shop-api", "sh"]
        )
        XCTAssertEqual(command, "/usr/local/bin/container exec -it acme-shop-api sh")
    }

    func testQuotesExecutablePathContainingSpaces() {
        let command = TerminalCommandLine.rawCommand(
            executable: "/Users/me/My Tools/container",
            arguments: ["exec", "-it", "web", "sh"]
        )
        XCTAssertEqual(command, "\"/Users/me/My Tools/container\" exec -it web sh")
    }

    func testEscapesEmbeddedQuotes() {
        let command = TerminalCommandLine.rawCommand(
            executable: "/bin/container",
            arguments: ["exec", "-it", "od\"dziwny", "sh"]
        )
        XCTAssertEqual(command, "/bin/container exec -it \"od\\\"dziwny\" sh")
    }

    func testLeavesOrdinaryArgumentsUnquoted() {
        let command = TerminalCommandLine.rawCommand(executable: "container", arguments: ["ls"])
        XCTAssertEqual(command, "container ls")
    }

    // MARK: - Ghostty command line

    func testWrapsInShellThatClearsTheHostLoginBanner() {
        // Ghostty launches through `login -flp`, which prints "Last login: …" above
        // the container's prompt; `clear` before `exec` is what removes it.
        let command = TerminalCommandLine.string(
            executable: "/usr/local/bin/container",
            arguments: ["exec", "-it", "web", "sh"]
        )
        XCTAssertEqual(
            command,
            "/bin/sh -c \"clear; exec /usr/local/bin/container exec -it web sh\""
        )
    }

    func testEscapesQuotesOfTheInnerCommandForTheWrapper() {
        // A quoted path from rawCommand would otherwise close the wrapper's own
        // quoting and hand ghostty a command it cannot parse.
        let command = TerminalCommandLine.string(
            executable: "/Users/me/My Tools/container",
            arguments: ["exec", "-it", "web", "sh"]
        )
        XCTAssertEqual(
            command,
            "/bin/sh -c \"clear; exec \\\"/Users/me/My Tools/container\\\" exec -it web sh\""
        )
    }

    // MARK: - Engine flag

    func testDefaultEngineIsSwiftTerm() {
        // Ghostty's embedding API is not stable upstream, so it must stay opt-in.
        XCTAssertEqual(TerminalEngine.default, .swiftTerm)
    }

    func testUnknownStoredValueFallsBackToDefault() {
        XCTAssertNil(TerminalEngine(rawValue: "kitty"))
    }

    func testRawValuesAreStableAcrossReleases() {
        // These strings live in UserDefaults; renaming them silently resets the
        // user's choice back to the default.
        XCTAssertEqual(TerminalEngine.swiftTerm.rawValue, "swiftTerm")
        XCTAssertEqual(TerminalEngine.ghostty.rawValue, "ghostty")
        XCTAssertEqual(TerminalEngine.storageKey, "terminalEngine")
    }
}
