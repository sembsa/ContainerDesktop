import Foundation

/// How much history to ask the CLI for.
///
/// `container logs` prints *everything* when `-n` is omitted, which for a
/// long-running container means megabytes streamed line by line before the first
/// screenful is usable. Tailing is the default; the whole log stays one click
/// away.
enum LogTailLimit: Int, CaseIterable, Identifiable {
    case last200 = 200
    case last1000 = 1000
    case last5000 = 5000
    case all = 0

    static let storageKey = "logTailLines"
    static let `default` = LogTailLimit.last1000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "wszystko")
        default: String(format: String(localized: "ostatnie %d"), rawValue)
        }
    }

    /// Arguments for `container logs`. Omitting `-n` is what asks for everything.
    ///
    /// One line more than asked for: the CLI's tail reader seeks back in 1 KiB
    /// chunks and hands back the *first* line cut mid-way, so it arrives as a
    /// fragment (apple/container#2022, still present in 1.2.0). The extra line is
    /// dropped on arrival, leaving exactly `rawValue` intact ones.
    var arguments: [String] {
        self == .all ? [] : ["-n", "\(rawValue + 1)"]
    }

    /// Lines kept in memory. "Everything" still needs a ceiling — without one a
    /// container that has been chatting for weeks would grow the view until the
    /// app dies. Beyond it the oldest lines are dropped, newest always kept.
    var retainedLines: Int {
        self == .all ? 100_000 : rawValue * 2
    }
}
