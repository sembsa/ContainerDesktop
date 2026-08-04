import XCTest

/// Verifies how much log history the app asks `container logs` for.
///
/// The CLI prints the *entire* log when `-n` is omitted, which is what made the
/// log viewer crawl on long-running containers — so which cases pass `-n` and
/// which deliberately do not is worth pinning down.
final class LogTailLimitTests: XCTestCase {

    // MARK: - CLI arguments

    func testTailedLimitsAskForOneExtraLine() {
        // One more than wanted: the CLI hands back a truncated first line
        // (apple/container#2022, still present in 1.2.0), which the view drops.
        XCTAssertEqual(LogTailLimit.last200.arguments, ["-n", "201"])
        XCTAssertEqual(LogTailLimit.last1000.arguments, ["-n", "1001"])
        XCTAssertEqual(LogTailLimit.last5000.arguments, ["-n", "5001"])
    }

    func testEverythingOmitsTheFlag() {
        // Omitting -n is exactly what asks the CLI for the whole log.
        XCTAssertEqual(LogTailLimit.all.arguments, [])
    }

    // MARK: - Retention

    func testRetainsTwiceTheRequestedLines() {
        // Headroom above the fetched backlog, so following a live container does
        // not start trimming immediately.
        XCTAssertEqual(LogTailLimit.last200.retainedLines, 400)
        XCTAssertEqual(LogTailLimit.last1000.retainedLines, 2000)
        XCTAssertEqual(LogTailLimit.last5000.retainedLines, 10_000)
    }

    func testEverythingStillHasACeiling() {
        // Unbounded growth would eventually take the app down with it.
        XCTAssertEqual(LogTailLimit.all.retainedLines, 100_000)
    }

    // MARK: - Defaults

    func testDefaultTailsRatherThanFetchingEverything() {
        XCTAssertEqual(LogTailLimit.default, .last1000)
        XCTAssertFalse(LogTailLimit.default.arguments.isEmpty)
    }

    func testRawValuesAreStableAcrossReleases() {
        // Stored in UserDefaults; changing them silently resets the user's choice.
        XCTAssertEqual(LogTailLimit.storageKey, "logTailLines")
        XCTAssertEqual(LogTailLimit.all.rawValue, 0)
        XCTAssertEqual(LogTailLimit(rawValue: 1000), .last1000)
        XCTAssertNil(LogTailLimit(rawValue: 777))
    }
}
