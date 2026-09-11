import XCTest

/// When the release-notes window appears.
///
/// Getting this wrong is the difference between a useful one-off and a sheet
/// that greets people on every launch.
final class WhatsNewTests: XCTestCase {

    private let entries = [
        WhatsNew.Entry(version: "0.7.0", items: []),
        WhatsNew.Entry(version: "0.8.0", items: []),
    ]

    func testNotesAppearAfterAnUpgrade() {
        let entry = WhatsNew.entry(lastSeen: "0.6.0", current: "0.7.0", in: entries)
        XCTAssertEqual(entry?.version, "0.7.0")
    }

    func testNotesAppearForSomeoneWhoHasNeverSeenThisWindow() {
        // Everyone upgrading into the first release that has it stores nothing.
        XCTAssertEqual(WhatsNew.entry(lastSeen: nil, current: "0.7.0", in: entries)?.version, "0.7.0")
    }

    func testNotesDoNotComeBackOnTheNextLaunch() {
        XCTAssertNil(WhatsNew.entry(lastSeen: "0.7.0", current: "0.7.0", in: entries))
    }

    func testAVersionWithoutNotesShowsNothing() {
        XCTAssertNil(WhatsNew.entry(lastSeen: "0.6.0", current: "0.6.5", in: entries))
    }

    func testOnlyTheRunningVersionsNotesAreShown() {
        // Skipping 0.7.0 entirely must not queue up two sheets.
        XCTAssertEqual(WhatsNew.entry(lastSeen: "0.6.0", current: "0.8.0", in: entries)?.version, "0.8.0")
    }

    // MARK: - The shipped notes

    func testTheShippedNotesMatchTheAppVersion() {
        // A release whose notes were never written would silently show nothing;
        // this fails loudly instead.
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(WhatsNew.all.first { $0.version == "0.7.0" }, "brak wpisu dla 0.7.0 (wersja bundla: \(current ?? "?"))")
    }

    func testEveryShippedItemIsFilledIn() {
        for entry in WhatsNew.all {
            XCTAssertFalse(entry.items.isEmpty, entry.version)
            for item in entry.items {
                XCTAssertFalse(item.symbol.isEmpty, item.title)
                XCTAssertFalse(item.title.isEmpty, entry.version)
                XCTAssertFalse(item.detail.isEmpty, item.title)
            }
        }
    }
}
