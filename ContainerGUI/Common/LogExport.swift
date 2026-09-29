import AppKit
import Foundation

/// How much of a log to write out.
enum LogExportScope: Hashable, Identifiable {
    /// What the pane is holding — instant, and exactly what you can see,
    /// timestamps and all.
    case visible
    /// Everything the container ever wrote, fetched fresh. The pane's history
    /// limit does not apply, and the bytes go straight to the file.
    case everything

    var id: Self { self }
}

enum LogExport {
    /// `keyforge3d-logi-2026-09-29-2015.log`.
    ///
    /// Subject first so a folder of these sorts by container rather than by the
    /// hour they were taken, and a sortable stamp for the same reason. Anything
    /// that would open a second path component is replaced — container names are
    /// tame, but Kubernetes pod and namespace names arrive from a cluster.
    static func suggestedName(
        for subject: String,
        at date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        let safe = subject.map { character -> Character in
            character == "/" || character == ":" || character == "\\" ? "-" : character
        }
        let trimmed = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "log" : trimmed
        return "\(name)-logi-\(formatter.string(from: date)).log"
    }

    /// The save panel, returning nil when it is dismissed.
    @MainActor
    static func chooseDestination(suggesting name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = String(localized: "Zapisz log")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes lines already in memory, one per line, newline-terminated so the
    /// file ends the way every other tool expects.
    static func write(_ lines: [String], to url: URL) throws {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
