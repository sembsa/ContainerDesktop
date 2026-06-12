import Foundation

/// One entry parsed from `ls -la` output (container or volume browsing).
struct FileEntry: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let permissions: String

    var symbol: String {
        if isSymlink { return "arrow.up.forward.square" }
        return isDirectory ? "folder" : "doc"
    }

    /// Parses BusyBox/coreutils `ls -la` output, skipping `.`/`..` and totals.
    static func parse(lsOutput: String) -> [FileEntry] {
        var entries: [FileEntry] = []
        for rawLine in lsOutput.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("total ") { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 9 else { continue }
            let permissions = String(tokens[0])
            let size = Int64(tokens[4])
            // Name is everything from column 9 onward (handles spaces in names).
            var name = tokens[8...].joined(separator: " ")
            let isSymlink = permissions.hasPrefix("l")
            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            if name == "." || name == ".." { continue }
            entries.append(
                FileEntry(
                    name: name,
                    isDirectory: permissions.hasPrefix("d"),
                    isSymlink: isSymlink,
                    size: size,
                    permissions: permissions
                )
            )
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
