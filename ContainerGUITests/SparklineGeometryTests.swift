import XCTest
import CoreGraphics

/// The geometry behind the menu bar's sparklines.
///
/// A flipped y axis or an off-by-one in the spacing reads as perfectly
/// reasonable code and draws a nonsense chart, so the mapping is pinned here.
final class SparklineGeometryTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 100, height: 20)

    func testTheSeriesSpansTheFullWidth() {
        let points = SparklineGeometry.points(for: [0, 0.5, 1], in: rect)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.x, 0)
        XCTAssertEqual(points.last?.x, 100)
        XCTAssertEqual(points[1].x, 50)
    }

    func testHighValuesDrawHigherOnScreen() {
        // y grows downwards, so 1.0 must land at the TOP of the rectangle.
        let points = SparklineGeometry.points(for: [0, 1], in: rect)
        XCTAssertEqual(points[0].y, 20, "zero powinno leżeć na dole")
        XCTAssertEqual(points[1].y, 0, "maksimum powinno leżeć na górze")
    }

    func testASingleSampleIsDrawnFlatAcross() {
        // Otherwise the first tick after launch renders as a single invisible dot.
        let points = SparklineGeometry.points(for: [0.5], in: rect)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], CGPoint(x: 0, y: 10))
        XCTAssertEqual(points[1], CGPoint(x: 100, y: 10))
    }

    func testNoSamplesDrawNothing() {
        XCTAssertTrue(SparklineGeometry.points(for: [], in: rect).isEmpty)
    }

    func testValuesOutsideTheUnitRangeAreClampedToTheBox() {
        let points = SparklineGeometry.points(for: [-1, 2], in: rect)
        XCTAssertEqual(points[0].y, 20)
        XCTAssertEqual(points[1].y, 0)
    }

    func testAnOffsetRectangleIsRespected() {
        let offset = CGRect(x: 10, y: 5, width: 50, height: 10)
        let points = SparklineGeometry.points(for: [0, 1], in: offset)
        XCTAssertEqual(points.first, CGPoint(x: 10, y: 15))
        XCTAssertEqual(points.last, CGPoint(x: 60, y: 5))
    }
}
