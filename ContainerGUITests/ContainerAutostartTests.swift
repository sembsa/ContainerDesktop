import XCTest

/// Starting chosen containers at login.
///
/// Nothing here runs the agent; what is checked is the script it would run and
/// the bookkeeping around the selection — the parts that are wrong silently.
final class ContainerAutostartTests: XCTestCase {

    // MARK: - The selection

    func testOnlyContainersThatStillExistSurvive() {
        // A deleted container must not haunt the list for ever.
        XCTAssertEqual(
            ContainerAutostart.pruned(selected: ["a", "gone", "c"], existing: ["a", "b", "c"]),
            ["a", "c"]
        )
    }

    func testTheOrderFollowsTheContainerListSoTheFileIsStable() {
        XCTAssertEqual(
            ContainerAutostart.pruned(selected: ["c", "a"], existing: ["a", "b", "c"]),
            ["a", "c"]
        )
    }

    func testAnEmptySelectionWritesAnEmptyFileRatherThanABlankLine() {
        XCTAssertEqual(ContainerAutostart.listContents([]), "")
        XCTAssertEqual(ContainerAutostart.listContents(["a"]), "a\n")
    }

    func testParsingIgnoresBlankLinesAndStrayWhitespace() {
        XCTAssertEqual(
            ContainerAutostart.parseList("a\n\n  b  \n\n"),
            ["a", "b"]
        )
    }

    func testTheListRoundTrips() {
        let ids = ["keyforge3d", "gitea", "sql2025"]
        XCTAssertEqual(ContainerAutostart.parseList(ContainerAutostart.listContents(ids)), ids)
    }

    // MARK: - The script

    func testReadinessIsAnchoredSoThatNotRunningCannotMatch() {
        // `container system status` prints "apiserver is not running…" when it
        // is down. A plain search for "running" would match that and the script
        // would carry on and start nothing.
        let script = ContainerAutostart.script(binary: "/usr/local/bin/container", listPath: "/tmp/l")
        XCTAssertTrue(script.contains("'^status[[:space:]]+running$'"), script)
    }

    func testTheWaitIsBounded() {
        // A login script that never returns is worse than one that gives up.
        let script = ContainerAutostart.script(binary: "/usr/local/bin/container", listPath: "/tmp/l")
        XCTAssertTrue(script.contains("-ge 60"), script)
        XCTAssertTrue(script.contains("exit 1"), script)
    }

    func testAMissingListIsNotAnError() {
        let script = ContainerAutostart.script(binary: "/usr/local/bin/container", listPath: "/tmp/l")
        XCTAssertTrue(script.contains("[ -f \"$LIST\" ] || exit 0"), script)
    }

    func testPathsWithSpacesSurviveTheShell() {
        let script = ContainerAutostart.script(
            binary: "/Applications/My Tools/container",
            listPath: "/Users/me/Application Support/list.txt"
        )
        XCTAssertTrue(script.contains("'/Applications/My Tools/container'"), script)
        XCTAssertTrue(script.contains("'/Users/me/Application Support/list.txt'"), script)
    }

    func testASingleQuoteInAPathCannotBreakOutOfTheQuoting() {
        XCTAssertEqual(ContainerAutostart.shellQuote("it's"), "'it'\\''s'")
    }

    // MARK: - The agent

    func testThePlistRunsOurScriptAtLogin() {
        let plist = ContainerAutostart.plist(scriptPath: "/tmp/start.sh")
        XCTAssertEqual(plist["Label"] as? String, ContainerAutostart.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/bin/sh", "/tmp/start.sh"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    }

    func testAnAgentThatIsNotOursIsLeftAlone() {
        XCTAssertEqual(ContainerAutostart.state(agentExists: false, agentIsOurs: false), .off)
        XCTAssertEqual(ContainerAutostart.state(agentExists: true, agentIsOurs: true), .on)
        XCTAssertEqual(ContainerAutostart.state(agentExists: true, agentIsOurs: false), .foreign)
    }

    func testTheAgentAndScriptLiveWhereTheyShould() {
        XCTAssertTrue(
            ContainerAutostart.agentURL.path.hasSuffix(
                "/Library/LaunchAgents/com.containerdesktop.ContainerGUI.containers.plist"
            ), ContainerAutostart.agentURL.path)
        XCTAssertTrue(
            ContainerAutostart.scriptURL.path.hasSuffix(
                "/Library/Application Support/ContainerDesktop/start-containers.sh"
            ), ContainerAutostart.scriptURL.path)
    }
}
