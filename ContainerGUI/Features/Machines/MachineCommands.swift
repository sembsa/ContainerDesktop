import Foundation

/// The `container machine` argv the app builds, kept out of the store so the
/// flags can be tested without launching anything.
///
/// Several of these rules are the CLI's own and are not guessable from the
/// subcommand names — they were read off `--help` and confirmed against a live
/// 1.3.0 machine:
///
/// - `--` is mandatory in front of a command that carries its own flags:
///   `machine run -n X uname -a` fails outright, `machine run -n X -- uname -a`
///   works.
/// - There is no `machine start`. `machine run` "boots the container machine if
///   necessary", so booting without opening a shell means running a detached
///   no-op.
/// - `virtualization` is a bare `--virtualization` flag on create but needs an
///   explicit `virtualization=true|false` on set.
/// - An empty `kernel=` on set is meaningful: it resets to the system default.
enum MachineCommands {

    /// How the user's home directory is mounted into the machine.
    enum HomeMount: String, CaseIterable, Identifiable {
        case readWrite = "rw"
        case readOnly = "ro"
        case notMounted = "none"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .readWrite: String(localized: "do zapisu (rw)")
            case .readOnly: String(localized: "tylko do odczytu (ro)")
            case .notMounted: String(localized: "nie montuj (none)")
            }
        }
    }

    struct CreateOptions {
        var image: String
        var name = ""
        var cpus = ""
        var memory = ""
        var homeMount: HomeMount = .readWrite
        var nestedVirtualization = false
        var kernelPath = ""
        var platform = ""
        var noBoot = false
        var setDefault = false
    }

    /// One `key=value` pair for `machine set`.
    enum Setting {
        case cpus(String)
        case memory(String)
        case homeMount(HomeMount)
        case virtualization(Bool)
        case kernel(String)

        var argument: String {
            switch self {
            case .cpus(let value): "cpus=\(value)"
            case .memory(let value): "memory=\(value)"
            case .homeMount(let mount): "home-mount=\(mount.rawValue)"
            case .virtualization(let enabled): "virtualization=\(enabled)"
            // Deliberately kept when empty — that is how the CLI resets the kernel.
            case .kernel(let path): "kernel=\(path)"
            }
        }
    }

    // MARK: - Create

    static func create(_ options: CreateOptions) -> [String] {
        var args = ["machine", "create", options.image]

        appendIfPresent(&args, "--name", options.name)
        appendIfPresent(&args, "--cpus", options.cpus)
        appendIfPresent(&args, "--memory", options.memory)
        appendIfPresent(&args, "--kernel", options.kernelPath)
        appendIfPresent(&args, "--platform", options.platform)

        // rw is the CLI's own default; passing it would only add noise.
        if options.homeMount != .readWrite {
            args.append(contentsOf: ["--home-mount", options.homeMount.rawValue])
        }
        if options.nestedVirtualization { args.append("--virtualization") }
        if options.noBoot { args.append("--no-boot") }
        if options.setDefault { args.append("--set-default") }

        return args
    }

    // MARK: - Set

    static func set(name: String, settings: [Setting]) -> [String] {
        guard !settings.isEmpty else { return [] }
        return ["machine", "set", "-n", name] + settings.map(\.argument)
    }

    // MARK: - Logs

    static func logs(name: String, boot: Bool, follow: Bool, lines: Int?) -> [String] {
        var args = ["machine", "logs"]
        if boot { args.append("--boot") }
        if follow { args.append("-f") }
        if let lines { args.append(contentsOf: ["-n", String(lines)]) }
        // The machine is a trailing positional, so it goes after every flag.
        args.append(name)
        return args
    }

    // MARK: - Boot

    /// Boots a stopped machine without attaching a shell to it.
    static func boot(name: String) -> [String] {
        ["machine", "run", "-n", name, "-d", "--", "/bin/true"]
    }

    // MARK: - Provisioning and desktop

    /// Inside the machine, deliberately not under the home directory: the host
    /// home is mounted rw by default, so `~/.vnc/passwd` would land on the user's
    /// real disk.
    static let vncPasswordPath = "/etc/x11vnc.pass"

    /// Builds a base image for a template whose distribution has no init of its
    /// own. `--progress plain` keeps the output usable in a log box.
    static func buildBaseImage(tag: String, contextDirectory: String) -> [String] {
        ["build", "--progress", "plain", "--tag", tag, contextDirectory]
    }

    /// The cheapest thing that can be asked of a machine, used to find out
    /// whether it will run anything yet.
    static func readinessProbe(name: String) -> [String] {
        ["machine", "run", "-n", name, "--", "/bin/true"]
    }

    /// All three desktop services run as root, and that is not tidiness: with the
    /// display owned by the host user and x11vnc as root, x11vnc attaches and then
    /// dies on "X11 MIT Shared Memory Attach failed" while every command still
    /// reports success — the port simply refuses connections afterwards.
    /// Asks whether a process is running inside the machine.
    ///
    /// A direct command, never `sh -c`: exit codes do not survive the shell form
    /// — `machine run -- /bin/sh -c 'exit 3'` reports 0, while a direct
    /// `/bin/false` reports 1 — so a probe whose whole answer is its exit code
    /// would always say yes.
    static func processProbe(name: String, process: String) -> [String] {
        ["machine", "run", "-n", name, "--", "pgrep", process]
    }

    static func desktopDisplayServer(name: String) -> [String] {
        ["machine", "run", "-n", name, "-d", "--root", "--",
         "Xvfb", MachineDesktop.display, "-screen", "0", "1440x900x24"]
    }

    /// Starts the chosen graphical environment. The display comes through `-e`
    /// rather than a shell assignment: `sh -c` swallows stdout and loses exit
    /// codes.
    static func desktopSession(name: String, environment: MachineDesktopEnvironment) -> [String] {
        ["machine", "run", "-n", name, "-d", "--root",
         "-e", "DISPLAY=\(MachineDesktop.display)", "--", environment.startExecutable]
    }

    /// Asks whether a binary exists inside the machine. Direct, for the same
    /// exit-code reason as `processProbe`.
    static func whichProbe(name: String, binary: String) -> [String] {
        ["machine", "run", "-n", name, "--", "which", binary]
    }

    /// A window manager on its own is a taskbar over an empty root window, so the
    /// desktop opens a terminal too — the first thing anyone connecting wants.
    static func desktopTerminal(name: String) -> [String] {
        ["machine", "run", "-n", name, "-d", "--root", "-e", "DISPLAY=\(MachineDesktop.display)", "--", "xterm"]
    }

    static func desktopVNCServer(name: String) -> [String] {
        ["machine", "run", "-n", name, "-d", "--root", "--",
         "x11vnc", "-display", MachineDesktop.display, "-forever",
         "-rfbauth", vncPasswordPath,
         "-rfbport", String(MachineDesktop.port), "-quiet"]
    }

    static func desktopStorePassword(name: String, password: String) -> [String] {
        ["machine", "run", "-n", name, "--root", "--",
         "x11vnc", "-storepasswd", password, vncPasswordPath]
    }

    // MARK: - Memory

    /// Renders a byte count back into the size `--memory` and `memory=` accept.
    ///
    /// The JSON reports bytes (`2147483648`); the CLI takes sizes (`2G`). Showing
    /// the raw number in an editable field would make it un-round-trippable — the
    /// user would have to convert it by hand to change anything else.
    static func memoryArgument(forBytes bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        let gibibyte: Int64 = 1 << 30
        let mebibyte: Int64 = 1 << 20
        if bytes % gibibyte == 0 { return "\(bytes / gibibyte)G" }
        if bytes % mebibyte == 0 { return "\(bytes / mebibyte)M" }
        return String(bytes)
    }

    // MARK: - Helpers

    private static func appendIfPresent(_ args: inout [String], _ flag: String, _ value: String) {
        // A blank value is an error from the CLI, not a default.
        guard !value.isEmpty else { return }
        args.append(contentsOf: [flag, value])
    }
}
