import SwiftUI
import Charts

// MARK: - Private helper types

private struct DatedSample: Identifiable {
    let id: UUID
    let date: Date
    let sample: StatsSample

    init(date: Date, sample: StatsSample) {
        self.id = UUID()
        self.date = date
        self.sample = sample
    }
}

private struct RatePoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
    let series: String

    init(date: Date, value: Double, series: String) {
        self.id = UUID()
        self.date = date
        self.value = value
        self.series = series
    }
}

// MARK: - TimeWindow

private enum TimeWindow: Int, CaseIterable, Identifiable {
    case oneMinute = 60, twoMinutes = 120, fiveMinutes = 300, fifteenMinutes = 900
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .oneMinute:     "1 min"
        case .twoMinutes:    "2 min"
        case .fiveMinutes:   "5 min"
        case .fifteenMinutes: "15 min"
        }
    }
}

// MARK: - StatChart style

private enum StatChartStyle {
    case area(Color)
    case lines([String: Color])
}

// MARK: - StatChart

private struct StatChart: View {
    let points: [RatePoint]
    let xDomain: ClosedRange<Date>
    let style: StatChartStyle
    let stepped: Bool
    let valueText: (Double) -> String

    @State private var hoverDate: Date?
    @State private var tooltipSize: CGSize = .zero

    var body: some View {
        if points.count < 2 {
            Text("Zbieranie danych…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(height: 120)
        } else {
            chartView
        }
    }

    // MARK: Chart view (split by style so View-level modifiers can be applied)

    @ViewBuilder
    private var chartView: some View {
        switch style {
        case .area:
            baseChart
                .frame(height: 120)
                .chartOverlay { proxy in hoverOverlay(proxy: proxy) }

        case .lines(let colorMap):
            baseChart
                .chartForegroundStyleScale(mapping: { (name: String) -> Color in
                    colorMap[name] ?? .primary
                })
                .chartLegend(position: .top, alignment: .trailing)
                .frame(height: 120)
                .chartOverlay { proxy in hoverOverlay(proxy: proxy) }
        }
    }

    // MARK: Base chart (marks only, no size / overlay)

    private var baseChart: some View {
        Chart {
            areaOrLineMarks
            if let hd = hoverDate {
                hoverMarks(hd: hd)
            }
        }
        .chartXScale(domain: xDomain)
        .statsTimeAxis()
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
    }

    // MARK: Main chart marks

    @ChartContentBuilder
    private var areaOrLineMarks: some ChartContent {
        switch style {
        case .area(let color):
            let interp: InterpolationMethod = stepped ? .stepEnd : .monotone
            ForEach(points) { pt in
                AreaMark(
                    x: .value("Czas", pt.date),
                    y: .value("Wartość", pt.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.35), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(interp)

                LineMark(
                    x: .value("Czas", pt.date),
                    y: .value("Wartość", pt.value)
                )
                .foregroundStyle(color)
                .interpolationMethod(interp)
            }

        case .lines:
            ForEach(points) { pt in
                LineMark(
                    x: .value("Czas", pt.date),
                    y: .value("Wartość", pt.value),
                    series: .value("Seria", pt.series)
                )
                .foregroundStyle(by: .value("Seria", pt.series))
                .interpolationMethod(.monotone)
            }
        }
    }

    // MARK: Hover helpers

    private var seriesColors: [String: Color] {
        switch style {
        case .area(let c): [points.first?.series ?? "": c]
        case .lines(let m): m
        }
    }

    private func snappedDate(for hd: Date) -> Date? {
        points.min(by: {
            abs($0.date.timeIntervalSince(hd)) < abs($1.date.timeIntervalSince(hd))
        })?.date
    }

    // MARK: Hover overlay (GeometryReader on top of chart)

    /// The tooltip is drawn here (overlay), NOT as a mark annotation: an
    /// annotation reserves layout space inside the chart, which rescales the
    /// plot and re-triggers hover under the cursor — visible as flicker.
    @ViewBuilder
    private func hoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let plotFrame = proxy.plotFrame {
                            let origin = geo[plotFrame].origin
                            hoverDate = proxy.value(
                                atX: location.x - origin.x,
                                as: Date.self
                            )
                        }
                    case .ended:
                        hoverDate = nil
                    }
                }

            if let hd = hoverDate,
               let snapped = snappedDate(for: hd),
               let plotFrame = proxy.plotFrame,
               let xInPlot = proxy.position(forX: snapped) {
                let plot = geo[plotFrame]
                let x = plot.origin.x + xInPlot
                tooltipView(
                    snapped: snapped,
                    snappedPoints: points.filter { $0.date == snapped },
                    seriesColors: seriesColors
                )
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                .position(tooltipPosition(lineX: x, in: geo.size))
                .allowsHitTesting(false)
            }
        }
    }

    /// Places the tooltip BESIDE the rule line (right by default, flips left
    /// near the edge) so it never covers the snapped point markers.
    private func tooltipPosition(lineX: CGFloat, in size: CGSize) -> CGPoint {
        let gap: CGFloat = 10
        let width = max(tooltipSize.width, 80)
        let height = max(tooltipSize.height, 36)
        let fitsRight = lineX + gap + width <= size.width - 4
        let x = fitsRight ? lineX + gap + width / 2 : lineX - gap - width / 2
        return CGPoint(x: x, y: 6 + height / 2)
    }

    // MARK: Hover marks

    @ChartContentBuilder
    private func hoverMarks(hd: Date) -> some ChartContent {
        if let snapped = snappedDate(for: hd) {
            let colors = seriesColors

            RuleMark(x: .value("Czas", snapped))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))

            ForEach(points.filter { $0.date == snapped }) { pt in
                PointMark(
                    x: .value("Czas", pt.date),
                    y: .value("Wartość", pt.value)
                )
                .symbolSize(40)
                .foregroundStyle(colors[pt.series] ?? .primary)
            }
        }
    }

    // MARK: Tooltip

    private func tooltipView(
        snapped: Date,
        snappedPoints: [RatePoint],
        seriesColors: [String: Color]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapped.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(snappedPoints) { pt in
                HStack(spacing: 4) {
                    Circle()
                        .fill(seriesColors[pt.series] ?? .primary)
                        .frame(width: 6, height: 6)
                    Text(valueText(pt.value))
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - StatsView

struct StatsView: View {
    let containerID: String

    @State private var history: [DatedSample] = []
    @State private var window: TimeWindow = .twoMinutes

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 12)]
    private let historyLimit = 900

    // MARK: Visible history (filtered to current window)

    private var visibleHistory: [DatedSample] {
        let cutoff = (history.last?.date ?? .now).addingTimeInterval(-Double(window.rawValue))
        return history.filter { $0.date >= cutoff }
    }

    // MARK: xDomain (shared)

    private var xDomain: ClosedRange<Date> {
        let now = history.last?.date ?? .now
        return now.addingTimeInterval(-Double(window.rawValue))...now
    }

    // MARK: Computed series (derived from visibleHistory)

    private var cpuPoints: [RatePoint] {
        ratePoints(
            in: visibleHistory,
            series: "CPU",
            lhs: { $0.cpuUsageUsec },
            rhs: { $0.cpuUsageUsec },
            transform: { delta, dt in max(0, Double(delta) / (dt * 1_000_000) * 100) }
        )
    }

    private var memoryPoints: [RatePoint] {
        visibleHistory.compactMap { ds in
            guard let bytes = ds.sample.memoryUsageBytes else { return nil }
            return RatePoint(date: ds.date, value: Double(bytes) / 1_048_576, series: String(localized: "Pamięć"))
        }
    }

    private var networkPoints: [RatePoint] {
        var result: [RatePoint] = []
        let vh = visibleHistory
        for i in 1..<vh.count {
            let prev = vh[i - 1]; let next = vh[i]
            let dt = next.date.timeIntervalSince(prev.date)
            guard dt > 0 else { continue }
            if let p = prev.sample.networkRxBytes, let n = next.sample.networkRxBytes {
                result.append(RatePoint(date: next.date, value: max(0, Double(n - p) / dt), series: String(localized: "Odebrane")))
            }
            if let p = prev.sample.networkTxBytes, let n = next.sample.networkTxBytes {
                result.append(RatePoint(date: next.date, value: max(0, Double(n - p) / dt), series: String(localized: "Wysłane")))
            }
        }
        return result
    }

    private var diskPoints: [RatePoint] {
        var result: [RatePoint] = []
        let vh = visibleHistory
        for i in 1..<vh.count {
            let prev = vh[i - 1]; let next = vh[i]
            let dt = next.date.timeIntervalSince(prev.date)
            guard dt > 0 else { continue }
            if let p = prev.sample.blockReadBytes, let n = next.sample.blockReadBytes {
                result.append(RatePoint(date: next.date, value: max(0, Double(n - p) / dt), series: String(localized: "Odczyt")))
            }
            if let p = prev.sample.blockWriteBytes, let n = next.sample.blockWriteBytes {
                result.append(RatePoint(date: next.date, value: max(0, Double(n - p) / dt), series: String(localized: "Zapis")))
            }
        }
        return result
    }

    private var processPoints: [RatePoint] {
        visibleHistory.compactMap { ds in
            guard let n = ds.sample.numProcesses else { return nil }
            return RatePoint(date: ds.date, value: Double(n), series: String(localized: "Procesy"))
        }
    }

    private var lastSample: StatsSample? { history.last?.sample }

    // MARK: Body

    var body: some View {
        ScrollView {
            if history.isEmpty {
                ProgressView("Wczytywanie statystyk…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else {
                // Time window picker
                HStack {
                    Text("Ostatnie \(window.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Okno", selection: $window) {
                        ForEach(TimeWindow.allCases) { w in
                            Text(w.label).tag(w)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 12) {
                    cpuCard
                    memoryCard
                    networkCard
                    diskCard
                    processCard
                }
                .padding(12)

                if let s = lastSample {
                    Text(String(format: String(localized: "Łącznie od startu — Sieć: ↓ %@ ↑ %@ · Dysk: odczyt %@, zapis %@"), Format.bytes(s.networkRxBytes), Format.bytes(s.networkTxBytes), Format.bytes(s.blockReadBytes), Format.bytes(s.blockWriteBytes)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .task(id: containerID) {
            history = []
            await pollStats()
        }
    }

    // MARK: - Cards

    private var cpuCard: some View {
        let currentCPU: String = {
            guard let last = cpuPoints.last else { return "—" }
            return String(format: "%.1f %%", last.value)
        }()

        return StatCard(title: "CPU", currentValue: currentCPU, tip: String(localized: "Procent czasu procesora zużywany przez kontener. Może przekraczać 100%, gdy kontener używa wielu rdzeni."), accent: .blue) {
            StatChart(
                points: cpuPoints,
                xDomain: xDomain,
                style: .area(.blue),
                stepped: false,
                valueText: { String(format: "%.1f %%", $0) }
            )
        }
    }

    private var memoryCard: some View {
        let currentMem: String = {
            guard let s = lastSample else { return "—" }
            let used = Format.memory(s.memoryUsageBytes)
            let limit = Format.memory(s.memoryLimitBytes)
            if let fraction = s.memoryFraction {
                return String(format: "%@ / %@ (%.1f %%)", used, limit, fraction * 100)
            }
            return "\(used) / \(limit)"
        }()

        return StatCard(title: String(localized: "Pamięć"), currentValue: currentMem, accent: .green) {
            StatChart(
                points: memoryPoints,
                xDomain: xDomain,
                style: .area(.green),
                stepped: false,
                valueText: { String(format: "%.1f MB", $0) }
            )
        }
    }

    private var networkCard: some View {
        let lastRx: Double = networkPoints.last(where: { $0.series == String(localized: "Odebrane") })?.value ?? 0
        let lastTx: Double = networkPoints.last(where: { $0.series == String(localized: "Wysłane") })?.value ?? 0
        let rxStr = Format.bytes(Int64(lastRx)) + "/s"
        let txStr = Format.bytes(Int64(lastTx)) + "/s"
        let currentNet = "↓ \(rxStr)  ↑ \(txStr)"

        return StatCard(title: String(localized: "Sieć"), currentValue: currentNet, tip: String(localized: "Przepływ danych na sekundę (nie suma). Łączne liczniki od startu są pod wykresami."), accent: .purple) {
            StatChart(
                points: networkPoints,
                xDomain: xDomain,
                style: .lines([String(localized: "Odebrane"): .purple, String(localized: "Wysłane"): .orange]),
                stepped: false,
                valueText: { Format.bytes(Int64($0)) + "/s" }
            )
        }
    }

    private var diskCard: some View {
        let lastRead: Double = diskPoints.last(where: { $0.series == String(localized: "Odczyt") })?.value ?? 0
        let lastWrite: Double = diskPoints.last(where: { $0.series == String(localized: "Zapis") })?.value ?? 0
        let readStr = Format.bytes(Int64(lastRead)) + "/s"
        let writeStr = Format.bytes(Int64(lastWrite)) + "/s"
        let currentDisk = "R \(readStr)  W \(writeStr)"

        return StatCard(title: String(localized: "Dysk"), currentValue: currentDisk, tip: String(localized: "Odczyt i zapis na sekundę (nie suma). Łączne liczniki od startu są pod wykresami."), accent: .teal) {
            StatChart(
                points: diskPoints,
                xDomain: xDomain,
                style: .lines([String(localized: "Odczyt"): .teal, String(localized: "Zapis"): .pink]),
                stepped: false,
                valueText: { Format.bytes(Int64($0)) + "/s" }
            )
        }
    }

    private var processCard: some View {
        let currentProc: String = lastSample?.numProcesses.map(String.init) ?? "—"

        return StatCard(title: String(localized: "Procesy"), currentValue: currentProc, accent: .indigo) {
            StatChart(
                points: processPoints,
                xDomain: xDomain,
                style: .area(.indigo),
                stepped: true,
                valueText: { String(Int($0)) }
            )
        }
    }

    // MARK: - Helpers

    private func ratePoints(
        in source: [DatedSample],
        series: String,
        lhs: (StatsSample) -> Int64?,
        rhs: (StatsSample) -> Int64?,
        transform: (Int64, Double) -> Double
    ) -> [RatePoint] {
        var result: [RatePoint] = []
        for i in 1..<source.count {
            let prev = source[i - 1]
            let next = source[i]
            let dt = next.date.timeIntervalSince(prev.date)
            guard dt > 0,
                  let p = lhs(prev.sample),
                  let n = rhs(next.sample) else { continue }
            result.append(RatePoint(date: next.date, value: transform(n - p, dt), series: series))
        }
        return result
    }

    // MARK: - Polling

    private func pollStats() async {
        while !Task.isCancelled {
            if let samples = try? await ContainerCLI.shared.json(
                ["stats", "--no-stream", containerID],
                as: [StatsSample].self
            ), let s = samples.first {
                let dated = DatedSample(date: .now, sample: s)
                if history.count >= historyLimit {
                    history.removeFirst()
                }
                history.append(dated)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - Shared time axis

private extension View {
    /// Sparse time labels (HH:mm:ss) shared by all stat charts.
    func statsTimeAxis() -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
    }
}

// MARK: - StatCard

private struct StatCard<ChartContent: View>: View {
    let title: String
    let currentValue: String
    var tip: String? = nil
    var accent: Color = .secondary
    @ViewBuilder let chartContent: () -> ChartContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tip {
                    InfoTip(text: tip)
                }
            }
            Text(currentValue)
                .font(.title3.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            chartContent()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}
