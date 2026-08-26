import Foundation

/// What the embedded terminal attaches to.
///
/// A container shell and a machine shell differ by nothing but these arguments,
/// so they live here rather than being spelled out in two near-identical views.
/// Kept free of SwiftUI so the logic tests can compile it on its own.
enum TerminalTarget {
    case container(id: String)
    /// `asRoot` maps to `--root`, which runs as root instead of matching the host user.
    case machine(name: String, asRoot: Bool)

    var arguments: [String] {
        switch self {
        case .container(let id):
            // A container image has no login shell to fall back on, so `sh` is named.
            return ["exec", "-it", id, "sh"]

        case .machine(let name, let asRoot):
            // No executable: `machine run` then opens the machine's login shell.
            // Nothing may follow the flags — a command would need a `--` separator.
            var args = ["machine", "run", "-n", name, "-i", "-t"]
            if asRoot { args.append("--root") }
            return args
        }
    }
}
