import Foundation

/// What the app hands to its desktop widget.
///
/// A WidgetKit extension on macOS always runs sandboxed, so it cannot spawn the
/// `container` CLI the way the app does. Instead the app — which is not
/// sandboxed — writes this snapshot after every refresh, and the widget only
/// reads it. That also means the widget keeps showing the last known state when
/// the app isn't running, which is the honest thing for a glanceable surface.
///
/// Deliberately *not* an App Group container: app-group entitlements require a
/// provisioning profile, which an ad-hoc signed build cannot have. A plain file
/// under Application Support plus a read-only sandbox exception achieves the
/// same thing and keeps `xcodebuild` working with no signing identity.
struct WidgetSnapshot: Codable, Sendable, Hashable {
    var generatedAt: Date
    var serviceRunning: Bool
    var containers: [Entry]

    var runningCount: Int { containers.filter(\.isRunning).count }
    var stoppedCount: Int { containers.count - runningCount }

    struct Entry: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var image: String
        var state: String
        var ipv4: String?
        var project: String?
        var cpuPercent: Double?
        var memoryUsedBytes: Int64?

        var isRunning: Bool { state.lowercased() == "running" }
    }

    static let empty = WidgetSnapshot(generatedAt: .distantPast, serviceRunning: false, containers: [])
}

/// Where the snapshot lives, and how each side reaches it.
///
/// The path must be resolved from the **real** home directory. Inside the
/// widget's sandbox `NSHomeDirectory()` returns the extension's own container,
/// while the `home-relative-path` entitlement grants access to the actual one —
/// so both sides ask the password database instead.
enum WidgetSnapshotStore {
    static let fileName = "widget-snapshot.json"

    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static var directory: URL {
        realHomeDirectory.appending(path: "Library/Application Support/ContainerDesktop")
    }

    static var fileURL: URL {
        directory.appending(path: fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// App side. Writes atomically so the widget can never read a half file.
    static func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Widget side. A missing or unreadable file is an ordinary state (the app
    /// has never run), not an error worth surfacing.
    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
