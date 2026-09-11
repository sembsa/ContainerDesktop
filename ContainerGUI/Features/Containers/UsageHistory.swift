import Foundation

/// A short rolling history of one container's CPU usage, for the menu bar's
/// sparklines.
///
/// Samples come from the app's existing three-second refresh — `ContainerStore`
/// already runs one `container stats --no-stream` per tick for every container,
/// whatever section is on screen — so keeping history costs a few kilobytes and
/// no extra process. Forty samples is about two minutes.
struct UsageHistory: Sendable, Hashable {
    static let capacity = 40

    /// CPU percentages are computed from a counter delta over elapsed time, so a
    /// container restart can produce a negative value and a very short interval
    /// an implausible one. Both are clamped rather than drawn.
    static let ceiling: Double = 100 * 64

    /// The smallest range a sparkline is scaled against.
    ///
    /// Scaling purely to a series' own peak would render 0.2% against 0.4% as a
    /// dramatic mountain range — every idle container would look busy. Below
    /// this, quiet stays quiet.
    static let drawingFloor: Double = 10

    private(set) var samples: [Double] = []

    init(samples: [Double] = []) {
        self.samples = samples
    }

    mutating func record(_ value: Double) {
        samples.append(min(max(value, 0), Self.ceiling))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    var latest: Double? { samples.last }

    var peak: Double { samples.max() ?? 0 }

    /// The series scaled into `0...1`, oldest first, ready to draw.
    func normalised() -> [Double] {
        guard !samples.isEmpty else { return [] }
        let range = max(peak, Self.drawingFloor)
        return samples.map { min(max($0 / range, 0), 1) }
    }
}

/// Every container's history, plus the aggregate across all of them.
struct UsageHistories: Sendable {
    private(set) var byContainer: [String: UsageHistory] = [:]
    private(set) var total = UsageHistory()

    init() {}

    subscript(container id: String) -> UsageHistory? { byContainer[id] }

    var isEmpty: Bool { byContainer.isEmpty }

    /// Appends one tick's worth of samples.
    ///
    /// Containers absent from `cpuPercentByContainer` lose their history — a
    /// stopped container's sparkline should not linger, showing activity that
    /// ended minutes ago. The total is still recorded when nothing is running,
    /// so the aggregate graph falls to the floor instead of freezing.
    mutating func record(_ cpuPercentByContainer: [String: Double]) {
        var updated: [String: UsageHistory] = [:]
        for (id, percent) in cpuPercentByContainer {
            var history = byContainer[id] ?? UsageHistory()
            history.record(percent)
            updated[id] = history
        }
        byContainer = updated
        total.record(cpuPercentByContainer.values.reduce(0, +))
    }
}
