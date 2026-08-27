import Foundation

/// The graphical side of a machine: a VNC server inside it, reached from the host
/// with Screen Sharing.
///
/// This works because a machine gets its own routable address and a port
/// listening inside it is reachable from the host with nothing published —
/// verified on 1.3.0, where `x11vnc` on display `:1` answered the host with
/// `RFB 003.008`.
enum MachineDesktop {

    static let port = 5900

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
