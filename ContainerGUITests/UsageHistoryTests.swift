import XCTest

/// The rolling CPU history behind the menu bar's sparklines.
///
/// Samples arrive from the app's existing three-second refresh, so forty of
/// them cover about two minutes. Nothing here talks to the CLI — the history is
/// pure bookkeeping over numbers the app already collects.
final class UsageHistoryTests: XCTestCase {

    // MARK: - The ring buffer

    func testSamplesArriveOldestFirst() {
        var history = UsageHistory()
        history.record(1)
        history.record(2)
        history.record(3)
        XCTAssertEqual(history.samples, [1, 2, 3])
        XCTAssertEqual(history.latest, 3)
    }

    func testTheOldestSampleFallsOffTheEnd() {
        var history = UsageHistory()
        for value in 0..<(UsageHistory.capacity + 5) {
            history.record(Double(value))
        }
        XCTAssertEqual(history.samples.count, UsageHistory.capacity)
        XCTAssertEqual(history.samples.first, 5)
        XCTAssertEqual(history.samples.last, Double(UsageHistory.capacity + 4))
    }

    func testAnEmptyHistoryHasNoLatestValue() {
        XCTAssertNil(UsageHistory().latest)
        XCTAssertTrue(UsageHistory().normalised().isEmpty)
    }

    func testNegativeAndAbsurdSamplesAreClamped() {
        // A CPU delta across a container restart can compute negative, and a
        // wildly short interval can compute far past 100%.
        var history = UsageHistory()
        history.record(-5)
        history.record(10_000)
        XCTAssertEqual(history.samples, [0, UsageHistory.ceiling])
    }

    // MARK: - Scaling for drawing

    func testAnIdleSeriesStaysFlatInsteadOfAmplifyingNoise() {
        // Scaling purely to the series' own peak would draw 0.2% vs 0.4% as a
        // dramatic mountain range. The floor keeps quiet containers looking quiet.
        var history = UsageHistory()
        for value in [0.2, 0.4, 0.3] { history.record(value) }
        let drawn = history.normalised()
        XCTAssertTrue(drawn.allSatisfy { $0 < 0.05 }, "\(drawn)")
    }

    func testABusySeriesUsesTheFullHeight() {
        var history = UsageHistory()
        for value in [10.0, 40.0, 80.0] { history.record(value) }
        let drawn = history.normalised()
        XCTAssertEqual(drawn.last ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(drawn.first ?? 0, 10.0 / 80.0, accuracy: 0.001)
    }

    func testEveryDrawnValueStaysInsideTheBox() {
        var history = UsageHistory()
        for value in [0.0, 5.0, 120.0, 60.0] { history.record(value) }
        XCTAssertTrue(history.normalised().allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: - Many containers at once

    func testEachContainerKeepsItsOwnSeries() {
        var histories = UsageHistories()
        histories.record(["a": 10, "b": 20])
        histories.record(["a": 30, "b": 40])

        XCTAssertEqual(histories[container: "a"]?.samples, [10, 30])
        XCTAssertEqual(histories[container: "b"]?.samples, [20, 40])
    }

    func testTheTotalIsTheSumAcrossContainers() {
        var histories = UsageHistories()
        histories.record(["a": 10, "b": 20])
        XCTAssertEqual(histories.total.samples, [30])
        XCTAssertEqual(histories.total.latest, 30)
    }

    func testAContainerThatStopsLosesItsHistory() {
        // Otherwise a stopped container's sparkline would hang around showing
        // activity that ended minutes ago.
        var histories = UsageHistories()
        histories.record(["a": 10, "b": 20])
        histories.record(["a": 30])

        XCTAssertNotNil(histories[container: "a"])
        XCTAssertNil(histories[container: "b"])
    }

    func testNothingRunningStillRecordsAZeroTotal() {
        // The aggregate graph should show the line dropping to the floor rather
        // than freezing at the last busy value.
        var histories = UsageHistories()
        histories.record(["a": 40])
        histories.record([:])
        XCTAssertEqual(histories.total.samples, [40, 0])
        XCTAssertTrue(histories.isEmpty)
    }
}
