import XCTest

/// The vector arithmetic SwiftUI uses to interpolate a sparkline between two
/// states. Without it the chart snaps; with it wrong, the chart flickers.
final class AnimatableSeriesTests: XCTestCase {

    func testAdditionIsElementwise() {
        let sum = AnimatableSeries(values: [1, 2, 3]) + AnimatableSeries(values: [10, 20, 30])
        XCTAssertEqual(sum.values, [11, 22, 33])
    }

    func testSubtractionIsElementwise() {
        let diff = AnimatableSeries(values: [10, 20]) - AnimatableSeries(values: [1, 2])
        XCTAssertEqual(diff.values, [9, 18])
    }

    func testShorterSeriesArePaddedAtTheFront() {
        // A history grows by appending, so the missing samples are the old ones.
        let sum = AnimatableSeries(values: [5]) + AnimatableSeries(values: [1, 2, 3])
        XCTAssertEqual(sum.values, [1, 2, 8])
    }

    func testScalingMultipliesEveryValue() {
        var series = AnimatableSeries(values: [1, 2, 3])
        series.scale(by: 0.5)
        XCTAssertEqual(series.values, [0.5, 1, 1.5])
    }

    func testMagnitudeIsTheSumOfSquares() {
        XCTAssertEqual(AnimatableSeries(values: [3, 4]).magnitudeSquared, 25, accuracy: 0.0001)
    }

    func testZeroIsAdditivelyNeutral() {
        let series = AnimatableSeries(values: [1, 2, 3])
        XCTAssertEqual((series + .zero).values, [1, 2, 3])
        XCTAssertEqual((series - series).values, [0, 0, 0])
        XCTAssertEqual(AnimatableSeries.zero.magnitudeSquared, 0)
    }

    func testHalfwayBetweenTwoStatesIsTheMidpoint() {
        // This is what SwiftUI actually does mid-animation.
        let from = AnimatableSeries(values: [0, 0])
        let to = AnimatableSeries(values: [1, 0.5])
        var midpoint = to - from
        midpoint.scale(by: 0.5)
        XCTAssertEqual((from + midpoint).values, [0.5, 0.25])
    }
}
