import XCTest

/// Quoting for commands run with administrator privileges.
///
/// The command crosses two escaping layers — an AppleScript string literal and
/// then a shell — and a mistake in either is a command injection, not a
/// cosmetic bug.
final class ElevatedCommandTests: XCTestCase {

    func testAPlainCommandIsSingleQuotedPerArgument() {
        XCTAssertEqual(
            ElevatedCommand.appleScript(executable: "/usr/sbin/softwareupdate",
                                        arguments: ["--install-rosetta", "--agree-to-license"]),
            "do shell script \"'/usr/sbin/softwareupdate' '--install-rosetta' '--agree-to-license'\""
                + " with administrator privileges"
        )
    }

    func testASpaceInAPathCannotSplitTheCommand() {
        let script = ElevatedCommand.appleScript(
            executable: "/Applications/My App/tool", arguments: []
        )
        XCTAssertTrue(script.contains("'/Applications/My App/tool'"), script)
    }

    func testASingleQuoteCannotEscapeTheShellQuoting() {
        XCTAssertEqual(ElevatedCommand.shellQuote("it's"), "'it'\\''s'")
    }

    func testADoubleQuoteCannotCloseTheAppleScriptString() {
        XCTAssertEqual(ElevatedCommand.appleScriptQuote("say \"hi\""), "say \\\"hi\\\"")
    }

    func testBackslashesAreEscapedBeforeQuotes() {
        // The other order doubles the backslashes the quote escaping just added.
        XCTAssertEqual(ElevatedCommand.appleScriptQuote("a\\b"), "a\\\\b")
        XCTAssertEqual(ElevatedCommand.appleScriptQuote("\\\""), "\\\\\\\"")
    }

    func testAnArgumentTryingToChainAnotherCommandStaysOneArgument() {
        let script = ElevatedCommand.appleScript(
            executable: "/bin/echo", arguments: ["; rm -rf /"]
        )
        XCTAssertTrue(script.contains("'; rm -rf /'"), script)
        XCTAssertFalse(script.contains("\"; rm -rf /\""), script)
    }
}
