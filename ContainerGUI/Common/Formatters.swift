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

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }
}
