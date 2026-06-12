import XCTest

/// Verifies CLIError.from(exitCode:stderr:stdout:) factory and errorDescription.
final class CLIErrorMappingTests: XCTestCase {

    // MARK: - serviceNotRunning detection

    func testXPCConnectionErrorInStderrMapsToServiceNotRunning() {
        let error = CLIError.from(exitCode: 1, stderr: "XPC connection error: service unavailable", stdout: "")
        XCTAssertEqual(error, .serviceNotRunning)
    }

    func testApiServerNotRunningInStdoutMapsToServiceNotRunning() {
        // Real message from `container system status` on stdout when daemon is down
        let error = CLIError.from(
            exitCode: 1,
            stderr: "",
            stdout: "apiserver is not running and not registered with launchd"
        )
        XCTAssertEqual(error, .serviceNotRunning)
    }

    // MARK: - .command mapping

    func testEmptyStderrAndNonEmptyStdoutUsesStdout() {
        let error = CLIError.from(exitCode: 3, stderr: "", stdout: "coś poszło nie tak")
        XCTAssertEqual(error, .command(exitCode: 3, stderr: "coś poszło nie tak"))
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("coś poszło nie tak"),
                      "errorDescription powinno zawierać treść ze stdout, ale zawiera: \(desc)")
    }

    func testBothEmptyUsesExitCode() {
        let error = CLIError.from(exitCode: 7, stderr: "", stdout: "")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("7"),
                      "errorDescription powinno zawierać kod 7, ale zawiera: \(desc)")
    }

    // MARK: - errorDescription for other cases

    func testTimeoutErrorDescriptionContainsSecondsAndCommand() {
        let error = CLIError.timeout(seconds: 60, command: "system stop")
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "errorDescription nie może być puste dla .timeout")
        XCTAssertTrue(desc.contains("60"),
                      "errorDescription powinno zawierać \"60\", ale zawiera: \(desc)")
    }

    // MARK: - Equatable conformance

    func testEquatableCommandCase() {
        let lhs = CLIError.from(exitCode: 1, stderr: "boom", stdout: "")
        let rhs = CLIError.command(exitCode: 1, stderr: "boom")
        XCTAssertEqual(lhs, rhs)
    }
}
