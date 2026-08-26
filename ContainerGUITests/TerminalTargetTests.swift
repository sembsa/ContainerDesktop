import XCTest

/// Verifies which shell the embedded terminal actually opens.
///
/// A container and a machine differ by nothing but these arguments, which is why
/// they live in one place instead of being spelled out in two near-identical views.
final class TerminalTargetTests: XCTestCase {

    // MARK: - Containers

    func testContainerOpensAShellThroughExec() {
        XCTAssertEqual(
            TerminalTarget.container(id: "acme-shop-api").arguments,
            ["exec", "-it", "acme-shop-api", "sh"]
        )
    }

    // MARK: - Machines

    func testMachineOpensItsLoginShell() {
        // No executable: `machine run` defaults to the login shell, which on a
        // machine is a real one — unlike a container, where `sh` has to be named.
        XCTAssertEqual(
            TerminalTarget.machine(name: "builder", asRoot: false).arguments,
            ["machine", "run", "-n", "builder", "-i", "-t"]
        )
    }

    func testMachineCanAskForRoot() {
        XCTAssertEqual(
            TerminalTarget.machine(name: "builder", asRoot: true).arguments,
            ["machine", "run", "-n", "builder", "-i", "-t", "--root"]
        )
    }

    func testMachineNeverAppendsACommand() {
        // Anything after the flags would need a `--` separator; the login shell
        // deliberately takes none, so the separator must not appear.
        let args = TerminalTarget.machine(name: "builder", asRoot: false).arguments
        XCTAssertFalse(args.contains("--"))
    }

    // MARK: - Composition with the Ghostty command line

    func testGhosttyCommandLineWrapsAMachineTarget() {
        // Ghostty takes one string, so the machine arguments have to survive the
        // same quoting path the container ones already do.
        let command = TerminalCommandLine.string(
            executable: "/usr/local/bin/container",
            arguments: TerminalTarget.machine(name: "builder", asRoot: false).arguments
        )
        XCTAssertEqual(
            command,
            "/bin/sh -c \"clear; exec /usr/local/bin/container machine run -n builder -i -t\""
        )
    }
}
