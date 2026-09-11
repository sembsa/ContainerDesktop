import Foundation

/// Assigns each compose project a stable colour slot.
///
/// The menu bar marks every container with its project's colour, so containers
/// from one stack read as a group without nesting them under headers.
///
/// The hash is written out rather than taken from `hashValue`: Swift seeds that
/// randomly per process, so the colours would be reshuffled on every launch.
enum ProjectAccent {
    /// Number of distinct colours the UI provides.
    static let paletteSize = 6

    /// A stable slot in `0..<paletteSize`, or nil for a container that belongs
    /// to no compose project.
    static func slot(for project: String?) -> Int? {
        guard let project, !project.isEmpty else { return nil }
        return Int(fnv1a(project) % UInt64(paletteSize))
    }

    /// FNV-1a, 64-bit — small, deterministic, and good enough to spread a
    /// handful of project names across six slots.
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
