import Foundation

/// `container commit` used as a time machine for one container.
///
/// A snapshot is an ordinary image named `localhost/snapshots/<container>:<stamp>`.
/// `commit` takes no labels, so the name is the only place to record whose
/// snapshot it is and when it was taken; the `localhost` registry keeps these
/// apart from anything that could be pushed to or pulled from a real registry.
///
/// What a snapshot holds is the container's filesystem — not its volumes.
/// Restoring rolls back what was written inside the container, never what was
/// written to a mounted volume, and the UI has to say so.
enum ContainerSnapshots {
    static let namespace = "localhost/snapshots"

    /// Image repositories are lowercase alphanumerics with restricted
    /// separators; container names allow more. Every other run of characters
    /// becomes one `-`.
    /// shortcut: `my_db` and `my-db` share a repository and so a history list;
    /// upgrade to a stored map if that ever confuses anyone.
    static func repository(for containerID: String) -> String {
        let name = containerID.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .joined(separator: "-")
        return "\(namespace)/\(name.isEmpty ? "container" : name)"
    }

    static func reference(for containerID: String, at date: Date) -> String {
        "\(repository(for: containerID)):\(stamp.string(from: date))"
    }

    /// One container's snapshots, newest first. The `:` in the prefix keeps
    /// `web2`'s history out of `web`'s.
    static func snapshots(for containerID: String, in images: [ImageInfo]) -> [ImageInfo] {
        let prefix = repository(for: containerID) + ":"
        return images
            .filter { $0.reference.hasPrefix(prefix) }
            .sorted { $0.reference > $1.reference }  // the stamp sorts as text
    }

    // MARK: - Taking

    /// Commits `containerID`'s filesystem as a snapshot and returns its reference.
    ///
    /// `commit` exports a running container's filesystem in flight — it does
    /// not pause it — so a database captured that way is caught mid-write.
    /// `stopFirst` stops it for the commit and starts it again whatever the
    /// commit's outcome.
    @discardableResult
    static func take(_ containerID: String, isRunning: Bool, stopFirst: Bool) async throws -> String {
        let cli = ContainerCLI.shared
        let reference = reference(for: containerID, at: .now)
        let restart = stopFirst && isRunning
        if restart { try await cli.run(["stop", containerID]) }
        do {
            try await cli.run(["commit", containerID, reference], timeout: .seconds(600))
        } catch {
            if restart { _ = try? await cli.run(["start", containerID]) }
            throw error
        }
        if restart { try await cli.run(["start", containerID]) }
        return reference
    }

    /// Snapshots a container that is about to be replaced — what makes a
    /// restore undoable. Stopped first, since it is going away anyway; a failed
    /// commit throws, and the caller must not remove the container then.
    @discardableResult
    static func preserveBeforeReplacing(_ containerID: String) async throws -> String {
        _ = try? await ContainerCLI.shared.run(["stop", containerID])
        return try await take(containerID, isRunning: false, stopFirst: false)
    }

    static func date(of reference: String) -> Date? {
        guard let colon = reference.lastIndex(of: ":") else { return nil }
        return stamp.date(from: String(reference[reference.index(after: colon)...]))
    }

    /// UTC, so a snapshot taken across a DST change still sorts by when it was taken.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
