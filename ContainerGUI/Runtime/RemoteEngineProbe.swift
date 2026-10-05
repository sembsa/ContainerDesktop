import Foundation

/// Finds out which container engines a remote machine offers, with one
/// read-only shell script run over SSH.
///
/// The script only tests for files (`-S`, `-x`) and asks the remote docker CLI
/// which endpoint its current context points at. It writes nothing. A socket in
/// a directory the login user cannot traverse fails the `-S` test and is simply
/// not reported, which is the "where readable" rule.
enum RemoteEngineProbe {

    /// Where a remote CLI is looked for, in order. A non-interactive ssh session
    /// has only `/usr/bin:/bin:/usr/sbin:/sbin` on its PATH, so Homebrew's
    /// directories are tried by absolute path first; `command -v` comes last
    /// for anything the login shell does expose. `~/` means the remote `$HOME`.
    static let appleCandidates = [
        "/opt/homebrew/bin/container",
        "/usr/local/bin/container",
        "~/.local/bin/container",
    ]
    static let dockerCandidates = [
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "~/.docker/bin/docker",
        "/usr/bin/docker",
    ]

    /// Double-quoted shell word for a candidate: `~/` becomes `"$HOME/…"`, the
    /// rest is escaped so nothing in a path can be expanded or split.
    static func shellWord(_ path: String) -> String {
        var rest = path
        var prefix = ""
        if rest.hasPrefix("~/") { prefix = "$HOME/"; rest.removeFirst(2) }
        let escaped = rest
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"" + prefix + escaped + "\""
    }

    /// Shell that sets `$<variable>` to the first executable candidate, falling
    /// back to whatever `command -v <name>` reports (absolute paths only).
    private static func locate(_ name: String, candidates: [String], into variable: String) -> String {
        """
        \(variable)=""
        for c in \(candidates.map(shellWord).joined(separator: " ")); do
          if [ -f "$c" ] && [ -x "$c" ]; then \(variable)=$c; break; fi
        done
        if [ -z "$\(variable)" ]; then
          c=$(command -v \(name) 2>/dev/null)
          case "$c" in /*) if [ -f "$c" ] && [ -x "$c" ]; then \(variable)=$c; fi ;; esac
        fi
        """
    }

    /// Fed to `/bin/sh -s` on the remote side. Output lines: `HOME`, `SOCK`,
    /// `CTX`, `CTXNAME`, `DOCKER`, `APPLE`.
    static let script: String = """
    echo "HOME $HOME"
    for p in "$HOME/.docker/run/docker.sock" "$HOME"/.colima/*/docker.sock "$HOME/.orbstack/run/docker.sock" "$HOME/.rd/docker.sock" /var/run/docker.sock /Users/*/.colima/*/docker.sock /Users/*/.docker/run/docker.sock /Users/Shared/*/.run/docker.sock /home/*/.colima/*/docker.sock /run/user/*/docker.sock; do
      if [ -S "$p" ] && [ -r "$p" ] && [ -w "$p" ]; then echo "SOCK $p"; fi
    done
    \(locate("docker", candidates: dockerCandidates, into: "DOCKER_BIN"))
    if [ -n "$DOCKER_BIN" ]; then
      echo "DOCKER $DOCKER_BIN"
      h=$("$DOCKER_BIN" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
      if [ -n "$h" ]; then echo "CTX $h"; echo "CTXNAME $("$DOCKER_BIN" context show 2>/dev/null)"; fi
    fi
    \(locate("container", candidates: appleCandidates, into: "APPLE_BIN"))
    if [ -n "$APPLE_BIN" ]; then echo "APPLE $APPLE_BIN"; fi
    exit 0
    """

    struct Result: Equatable, Sendable {
        var home: String?
        var sockets: [String] = []
        /// The remote docker CLI's current context endpoint, if it is a unix socket.
        var contextSocket: String?
        /// A non-unix endpoint (tcp://, ssh://) the context points at. Not used.
        var contextOther: String?
        /// Name of the remote CLI's current context (`colima`, `desktop-linux`).
        var contextName: String?
        /// Absolute path of the remote docker CLI, when one was found.
        var dockerBinary: String?
        /// Absolute path of Apple's `container` CLI, when one was found.
        var appleBinary: String?
    }

    static func parse(_ output: String) -> Result {
        var result = Result()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let tag = line[..<space]
            let value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch tag {
            case "HOME": result.home = value
            case "SOCK": result.sockets.append(value)
            case "CTX":
                if value.hasPrefix("unix://") {
                    result.contextSocket = String(value.dropFirst("unix://".count))
                } else {
                    result.contextOther = value
                }
            case "CTXNAME": result.contextName = value
            case "DOCKER": result.dockerBinary = value
            case "APPLE": result.appleBinary = value
            default: continue
            }
        }
        return result
    }

    /// Sockets worth connecting to, most specific first and without repeats:
    /// the CLI's own context, an extra path the user typed, then the rest.
    static func candidates(from result: Result, extra: String?) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in [result.contextSocket, extra].compactMap({ $0 }) + result.sockets
        where !path.isEmpty && seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }

    /// Names the CLI's contexts are known by.
    static func engineTitle(forContext name: String?) -> String? {
        switch name?.lowercased() {
        case let n? where n.hasPrefix("colima"): "Colima"
        case "desktop-linux", "desktop-windows", "default-desktop": "Docker Desktop"
        case "orbstack": "OrbStack"
        case "rancher-desktop": "Rancher Desktop"
        default: nil
        }
    }

    /// Human name for the engine behind a socket path.
    ///
    /// `home` is the login user's home: a Colima socket under somebody *else's*
    /// home gets that user's name appended so two "Colima" entries stay apart.
    static func engineTitle(forSocket path: String, home: String?) -> String {
        let parts = path.split(separator: "/").map(String.init)
        func owner() -> String? {
            guard parts.count > 2, parts[0] == "Users" || parts[0] == "home" else { return nil }
            let prefix = "/\(parts[0])/\(parts[1])/"
            if let home, path.hasPrefix(home + "/") { return nil }
            return path.hasPrefix(prefix) && parts[1] != "Shared" ? parts[1] : nil
        }
        func decorated(_ name: String, profile: String? = nil) -> String {
            var title = name
            if let profile, profile != "default" { title += " (\(profile))" }
            if let owner = owner() { title += " [\(owner)]" }
            return title
        }
        if let index = parts.firstIndex(of: ".colima") {
            return decorated("Colima", profile: index + 1 < parts.count - 1 ? parts[index + 1] : nil)
        }
        if path.contains("/.orbstack/") { return decorated("OrbStack") }
        if path.contains("/.rd/") { return decorated("Rancher Desktop") }
        if path.contains("/.docker/run/") { return decorated("Docker Desktop") }
        return decorated("Docker")
    }
}
