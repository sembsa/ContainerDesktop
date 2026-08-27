import Foundation

/// The graphical side of a machine: a session inside it, reached from the host
/// with Screen Sharing.
///
/// This works because a machine gets its own routable address and a port
/// listening inside it is reachable from the host with nothing published —
/// verified on 1.3.0, where a VNC server on display `:1` answered the host with
/// `RFB 003.008`.
enum MachineDesktop {

    static let port = 5900
    static let display = ":1"

    /// Unambiguous characters only: no l/1, no O/0, no I. The password is read off
    /// the screen and typed into Screen Sharing by hand.
    private static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Exactly eight characters, because classic VNC authentication is DES with an
    /// eight-byte key and x11vnc silently truncates anything longer — a longer
    /// password would read as stronger without being it.
    static func generatePassword() -> String {
        String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// `vnc://…` is what macOS hands to Screen Sharing.
    static func screenSharingURL(host: String) -> URL? {
        guard !host.isEmpty else { return nil }
        return URL(string: "vnc://\(host):\(port)")
    }
}

/// Which graphical environment a machine's desktop runs.
///
/// Both were tried on a live machine before being offered here, because this
/// environment is unforgiving: fluxbox segfaults outright (exit 139, leaving a
/// connected session staring at a black screen), and a session with no window
/// manager accepts no keyboard input at all — windows appear and nothing can
/// focus them.
enum MachineDesktopEnvironment: String, CaseIterable, Identifiable, Sendable {
    /// A window manager with a taskbar. Small.
    case iceWM = "icewm"
    /// A full desktop: panel, desktop icons, its own terminal, dbus.
    case xfce = "xfce"

    static let `default` = MachineDesktopEnvironment.iceWM

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iceWM: String(localized: "IceWM — lekki pulpit z paskiem zadań")
        case .xfce: String(localized: "XFCE — pełny pulpit")
        }
    }

    var summary: String {
        switch self {
        case .iceWM:
            String(localized: "Pasek zadań z menu i okno terminala. Około 300 MB paczek.")
        case .xfce:
            String(localized: "Panel, ikony na pulpicie, menedżer plików i własny terminal. Około 650 MB paczek.")
        }
    }

    /// Package names differ between distributions: `dbus-launch` lives in
    /// `dbus-x11` on Debian and Ubuntu, while Alpine simply calls it `dbus`.
    /// Verified on both — `startxfce4` brought the session up either way.
    func packages(for manager: MachinePackageManager) -> [String] {
        switch self {
        case .iceWM:
            return ["xvfb", "x11vnc", "icewm", "xterm"]
        case .xfce:
            // dbus is not optional for XFCE: the session manager talks to it.
            let dbus = manager == .apt ? "dbus-x11" : "dbus"
            return ["xvfb", "x11vnc", "xfce4", "xfce4-terminal", dbus]
        }
    }

    /// Run detached with `DISPLAY` set.
    var startExecutable: String {
        switch self {
        case .iceWM: "icewm"
        case .xfce: "startxfce4"
        }
    }

    /// What has to appear in the process list for the session to be up.
    ///
    /// For XFCE this is `xfwm4` rather than `startxfce4`: the starter is a script
    /// that exits, and the window manager is what actually holds the session.
    var probeProcess: String {
        switch self {
        case .iceWM: "icewm"
        case .xfce: "xfwm4"
        }
    }

    /// Whether the environment opens a terminal of its own. IceWM does not, and a
    /// taskbar over an empty root window is not what anyone connects for.
    var providesTerminal: Bool {
        switch self {
        case .iceWM: false
        case .xfce: true
        }
    }

    /// The binary whose presence means this environment is installed.
    var marker: String { startExecutable }
}
