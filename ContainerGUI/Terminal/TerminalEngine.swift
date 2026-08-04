import Foundation

/// Which engine draws the embedded container shell.
///
/// SwiftTerm draws through CoreText and is the default. Ghostty (libghostty)
/// renders with Metal — sharper glyphs, ligatures, better emoji — but its
/// embedding API is explicitly not stabilized upstream ("used primarily by the
/// macOS app, may change significantly between releases"), and the full library
/// only reaches us through a third-party build. So it stays opt-in until that
/// settles; switching back is a setting, not a rebuild.
///
/// Deliberately free of SwiftUI so the logic tests can compile this file on its
/// own, the way the rest of the headless test bundle works.
enum TerminalEngine: String, CaseIterable, Identifiable {
    case swiftTerm
    case ghostty

    /// UserDefaults key shared by the Settings picker and the terminal view.
    static let storageKey = "terminalEngine"
    static let `default` = TerminalEngine.swiftTerm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swiftTerm: String(localized: "Wbudowany (SwiftTerm)")
        case .ghostty: String(localized: "Ghostty — Metal (eksperymentalny)")
        }
    }
}

/// Builds the single command line that Ghostty's `command` config key takes.
///
/// Kept separate from the view so the quoting is testable: the path to the
/// `container` CLI is user-configurable in Settings and may contain spaces.
enum TerminalCommandLine {
    /// Ghostty runs the command as `login -flp <user> /bin/bash --noprofile --norc
    /// -c exec -l <command>`, so the host greets us with "Last login: … on
    /// ttysNNN" above the container's own prompt. Wrapping in `sh -c` lets `clear`
    /// wipe that line first; it has to stay a plain executable + arguments,
    /// because a bare `clear; …` would be torn apart by the wrapper above.
    static func string(executable: String, arguments: [String]) -> String {
        let inner = rawCommand(executable: executable, arguments: arguments)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/sh -c \"clear; exec \(inner)\""
    }

    static func rawCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quoted).joined(separator: " ")
    }

    private static func quoted(_ part: String) -> String {
        guard part.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return part }
        return "\"" + part.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
