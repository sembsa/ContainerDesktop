import SwiftUI

/// Maps a normalised series onto a drawing rectangle.
///
/// Kept apart from the view so the geometry can be tested: an off-by-one in the
/// x spacing, or a flipped y, is invisible in code review and obvious in a test.
enum SparklineGeometry {
    /// `values` are `0...1`, oldest first. The first point sits on the leading
    /// edge and the last on the trailing edge, so the series always fills the
    /// width it is given.
    static func points(for values: [Double], in rect: CGRect) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        guard values.count > 1 else {
            // One sample has no run to spread across; draw it flat.
            let y = rect.maxY - CGFloat(values[0]) * rect.height
            return [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)]
        }
        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - CGFloat(min(max(value, 0), 1)) * rect.height
            )
        }
    }
}

/// A series SwiftUI can interpolate between two states.
///
/// Without this a `Shape` has `EmptyAnimatableData`, so the path snaps to its
/// new position — a visible jolt every time a sample arrives. Series of
/// different lengths are padded at the front, which is where a growing history
/// gains its samples.
struct AnimatableSeries: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableSeries { AnimatableSeries(values: []) }

    private static func aligned(_ lhs: [Double], _ rhs: [Double]) -> ([Double], [Double]) {
        let width = max(lhs.count, rhs.count)
        let pad: ([Double]) -> [Double] = { Array(repeating: 0, count: width - $0.count) + $0 }
        return (pad(lhs), pad(rhs))
    }

    static func + (lhs: AnimatableSeries, rhs: AnimatableSeries) -> AnimatableSeries {
        let (a, b) = aligned(lhs.values, rhs.values)
        return AnimatableSeries(values: zip(a, b).map(+))
    }

    static func - (lhs: AnimatableSeries, rhs: AnimatableSeries) -> AnimatableSeries {
        let (a, b) = aligned(lhs.values, rhs.values)
        return AnimatableSeries(values: zip(a, b).map(-))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

/// The line through a normalised series, optionally closed into an area.
struct SparklineShape: Shape {
    var values: [Double]
    var filled: Bool

    var animatableData: AnimatableSeries {
        get { AnimatableSeries(values: values) }
        set { values = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        let points = SparklineGeometry.points(for: values, in: rect)
        guard let first = points.first else { return Path() }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }

        guard filled, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A small filled area chart, for CPU history in the menu bar.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    /// Drawn behind the series so an idle container still reads as a chart
    /// rather than an empty gap.
    var showsBaseline = true

    var body: some View {
        ZStack {
            if showsBaseline {
                Rectangle()
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            SparklineShape(values: values, filled: true)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.45), tint.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            SparklineShape(values: values, filled: false)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .animation(.easeOut(duration: 0.45), value: values)
        .drawingGroup()
        .accessibilityHidden(true)
    }
}
