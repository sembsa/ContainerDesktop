import Foundation

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func bytes(_ value: Int?) -> String {
        bytes(value.map(Int64.init))
    }

    static func memory(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// A CPU reading for a tight space.
    ///
    /// Whole percents once there is anything to see, one decimal below 10% —
    /// otherwise every idle container reads a flat "0%" and the sparkline next
    /// to it appears to be lying.
    static func cpu(_ percent: Double?) -> String {
        guard let percent, percent.isFinite, percent >= 0 else { return "—" }
        if percent < 10 {
            return percent.formatted(.number.precision(.fractionLength(1))) + "%"
        }
        return percent.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }
}
