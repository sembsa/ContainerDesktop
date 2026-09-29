import XCTest

/// The name a log file is offered under.
///
/// The bit worth testing: a pod or namespace name arrives from a cluster, not
/// from this app, and a "/" in a save panel's name field is a second path
/// component rather than a character.
final class LogExportTests: XCTestCase {

    private let moment = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
    private let utc = TimeZone(identifier: "UTC")!

    func testTheSubjectComesFirstSoAFolderSortsByContainer() {
        let name = LogExport.suggestedName(for: "keyforge3d", at: moment, timeZone: utc)
        XCTAssertTrue(name.hasPrefix("keyforge3d-logi-"), name)
        XCTAssertTrue(name.hasSuffix(".log"), name)
    }

    func testTheStampIsSortableRatherThanLocalReadable() {
        XCTAssertEqual(
            LogExport.suggestedName(for: "x", at: moment, timeZone: utc),
            "x-logi-2026-09-21-1413.log"
        )
    }

    func testASlashInTheNameCannotOpenASecondPathComponent() {
        // Kubernetes hands out "namespace/pod"; a save panel would read that as
        // a directory that very likely does not exist.
        let name = LogExport.suggestedName(for: "default/web-0", at: moment, timeZone: utc)
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertTrue(name.hasPrefix("default-web-0-"), name)
    }

    func testColonsAndBackslashesGoTooBecauseTheyAreNotNamesEither() {
        let name = LogExport.suggestedName(for: #"a:b\c"#, at: moment, timeZone: utc)
        XCTAssertFalse(name.contains(":"), name)
        XCTAssertFalse(name.contains("\\"), name)
    }

    func testAnEmptySubjectStillProducesAUsableName() {
        let name = LogExport.suggestedName(for: "   ", at: moment, timeZone: utc)
        XCTAssertTrue(name.hasPrefix("log-logi-"), name)
    }

    func testTheFileEndsWithANewlineTheWayEveryOtherToolExpects() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try LogExport.write(["pierwsza", "druga"], to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "pierwsza\ndruga\n")
    }

    func testAnEmptyLogWritesAnEmptyFileRatherThanABareNewline() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try LogExport.write([], to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
    }
}
