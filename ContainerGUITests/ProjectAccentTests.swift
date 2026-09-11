import XCTest

/// Colour slots for compose projects, and the CPU reading beside them.
final class ProjectAccentTests: XCTestCase {

    func testAProjectAlwaysLandsInTheSameSlot() {
        XCTAssertEqual(ProjectAccent.slot(for: "outline"), ProjectAccent.slot(for: "outline"))
    }

    func testSlotsStayInsideThePalette() {
        for name in ["outline", "wikijs", "gitea", "enova", "a", "bardzo-długa-nazwa-projektu"] {
            let slot = ProjectAccent.slot(for: name)
            XCTAssertNotNil(slot, name)
            XCTAssertTrue((0..<ProjectAccent.paletteSize).contains(slot!), "\(name) -> \(slot!)")
        }
    }

    func testTheHashIsNotSwiftsRandomlySeededOne() {
        // `hashValue` is seeded per process, which would reshuffle every colour
        // on each launch. Pinning a known value keeps that from creeping back in.
        XCTAssertEqual(ProjectAccent.slot(for: "outline"), 5)
        XCTAssertEqual(ProjectAccent.slot(for: "wikijs"), 4)
    }

    func testDifferentProjectsMostlyGetDifferentSlots() {
        let names = ["outline", "wikijs", "gitea", "keyforge", "sql", "redis"]
        let slots = Set(names.compactMap(ProjectAccent.slot(for:)))
        XCTAssertGreaterThanOrEqual(slots.count, 4, "za dużo kolizji: \(slots)")
    }

    func testAContainerWithoutAProjectHasNoColour() {
        XCTAssertNil(ProjectAccent.slot(for: nil))
        XCTAssertNil(ProjectAccent.slot(for: ""))
    }

    // MARK: - CPU reading

    func testCPUKeepsADecimalWhileItIsQuiet() {
        // A flat "0%" next to a moving sparkline reads as a bug.
        XCTAssertEqual(Format.cpu(0.4), "0,4%")
        XCTAssertEqual(Format.cpu(9.9), "9,9%")
    }

    func testCPUDropsTheDecimalOnceItMatters() {
        XCTAssertEqual(Format.cpu(12.4), "12%")
        XCTAssertEqual(Format.cpu(99.6), "100%")
    }

    func testCPUWithoutASampleShowsADash() {
        XCTAssertEqual(Format.cpu(nil), "—")
        XCTAssertEqual(Format.cpu(-1), "—")
        XCTAssertEqual(Format.cpu(.nan), "—")
    }
}
