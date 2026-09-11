import XCTest
import CoreGraphics

/// Geometry of the activity strip drawn next to the status item glyph.
///
/// It is about ten points wide in a menu bar; nothing here can be checked by
/// looking at it, so it is checked here instead.
final class MenuBarIconLayoutTests: XCTestCase {

    private let origin = CGPoint(x: 20, y: 2)
    private let maxHeight: CGFloat = 12

    func testNewestSampleSitsOnTheRight() throws {
        let bars = MenuBarIconLayout.bars(
            for: [0.1, 0.2, 0.3, 0.4, 0.5, 1.0], origin: origin, maxHeight: maxHeight
        )
        XCTAssertEqual(bars.count, MenuBarIconLayout.barCount)
        XCTAssertEqual(try XCTUnwrap(bars.last).height, maxHeight, accuracy: 0.001)
        XCTAssertGreaterThan(bars.last!.minX, bars.first!.minX)
    }

    func testOnlyTheMostRecentSamplesAreDrawn() throws {
        let many = Array(repeating: 0.5, count: 40) + [1.0]
        let bars = MenuBarIconLayout.bars(for: many, origin: origin, maxHeight: maxHeight)
        XCTAssertEqual(bars.count, MenuBarIconLayout.barCount)
        XCTAssertEqual(try XCTUnwrap(bars.last).height, maxHeight, accuracy: 0.001)
    }

    func testAShortHistoryFillsInFromTheRight() {
        // Two samples stretched across the whole strip would read as a full
        // history that happens to be very coarse.
        let bars = MenuBarIconLayout.bars(for: [0.5, 1.0], origin: origin, maxHeight: maxHeight)
        XCTAssertEqual(bars.count, 2)

        let full = MenuBarIconLayout.bars(
            for: Array(repeating: 1.0, count: MenuBarIconLayout.barCount),
            origin: origin, maxHeight: maxHeight
        )
        XCTAssertEqual(bars.last!.minX, full.last!.minX, accuracy: 0.001)
        XCTAssertGreaterThan(bars.first!.minX, full.first!.minX)
    }

    func testAnIdleSampleStillDrawsSomething() {
        let bars = MenuBarIconLayout.bars(for: [0, 0, 0], origin: origin, maxHeight: maxHeight)
        XCTAssertTrue(bars.allSatisfy { $0.height == MenuBarIconLayout.minimumBarHeight })
    }

    func testNothingIsDrawnWithoutSamples() {
        XCTAssertTrue(MenuBarIconLayout.bars(for: [], origin: origin, maxHeight: maxHeight).isEmpty)
    }

    func testBarsStayInsideTheMenuBarGrid() {
        let bars = MenuBarIconLayout.bars(for: [2.0, -1.0, 0.5], origin: origin, maxHeight: maxHeight)
        for bar in bars {
            XCTAssertGreaterThanOrEqual(bar.height, MenuBarIconLayout.minimumBarHeight)
            XCTAssertLessThanOrEqual(bar.maxY, origin.y + maxHeight)
        }
    }

    func testTheStripFitsBesideTheGlyph() {
        // The whole image has to stay inside the 17 pt menu bar height, and wide
        // enough that the bars are not clipped.
        XCTAssertEqual(MenuBarIconLayout.height, 17)
        XCTAssertGreaterThan(MenuBarIconLayout.totalWidth, MenuBarIconLayout.glyphWidth)
        let bars = MenuBarIconLayout.bars(
            for: Array(repeating: 1.0, count: MenuBarIconLayout.barCount),
            origin: CGPoint(x: MenuBarIconLayout.glyphWidth + MenuBarIconLayout.gap, y: 2),
            maxHeight: MenuBarIconLayout.height - 5
        )
        XCTAssertLessThanOrEqual(bars.last!.maxX, MenuBarIconLayout.totalWidth)
    }
}
