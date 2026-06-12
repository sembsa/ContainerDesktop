import SwiftUI
import SwiftTerm
import AppKit

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView`. Spawns a local
/// process (with a PTY) such as `container exec -it <id> sh`.
///
/// Named `EmbeddedTerminalView` to avoid colliding with SwiftTerm's own
/// `TerminalView` class, which the delegate protocol references.
struct EmbeddedTerminalView: NSViewRepresentable {
    let executable: String
    let arguments: [String]

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        terminal.processDelegate = context.coordinator

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let environmentArray = environment.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(executable: executable, args: arguments, environment: environmentArray)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// Convenience view that opens an interactive shell inside a running container.
struct ContainerTerminalView: View {
    let containerID: String

    var body: some View {
        if let binary = BinaryResolver.resolve() {
            EmbeddedTerminalView(
                executable: binary,
                arguments: ["exec", "-it", containerID, "sh"]
            )
        } else {
            EmptyStateView(symbol: "terminal", title: String(localized: "Nie znaleziono narzędzia container"))
        }
    }
}
