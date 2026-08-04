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
    let onExit: (Int32?) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        terminal.processDelegate = context.coordinator

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let environmentArray = environment.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(executable: executable, args: arguments, environment: environmentArray)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
    }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: (Int32?) -> Void

        init(onExit: @escaping (Int32?) -> Void) {
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit(exitCode)
        }
    }
}

/// Shown when the shell exits, in place of a terminal that would otherwise just
/// sit there frozen with no explanation.
struct TerminalExitBanner: View {
    let exitCode: Int32?
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Połącz ponownie"), action: restart)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var message: String {
        guard let exitCode, exitCode != 0 else {
            return String(localized: "Powłoka zakończona.")
        }
        return String(format: String(localized: "Powłoka zakończona (kod %d)."), exitCode)
    }
}

/// Convenience view that opens an interactive shell inside a running container.
///
/// The engine is switchable (Settings → Terminal) because Ghostty's embedding API
/// is not stable upstream yet; see `TerminalEngine`.
struct ContainerTerminalView: View {
    let containerID: String

    @AppStorage(TerminalEngine.storageKey) private var engineRawValue = TerminalEngine.default.rawValue
    /// Recreates the terminal after the shell exits — the views key off this.
    @State private var sessionID = UUID()
    @State private var exitCode: Int32?
    @State private var didExit = false

    private var engine: TerminalEngine {
        TerminalEngine(rawValue: engineRawValue) ?? .default
    }

    private var arguments: [String] { ["exec", "-it", containerID, "sh"] }

    var body: some View {
        if let binary = BinaryResolver.resolve() {
            VStack(spacing: 0) {
                terminal(binary: binary)
                if didExit {
                    Divider()
                    TerminalExitBanner(exitCode: exitCode, restart: restart)
                }
            }
        } else {
            EmptyStateView(symbol: "terminal", title: String(localized: "Nie znaleziono narzędzia container"))
        }
    }

    @ViewBuilder
    private func terminal(binary: String) -> some View {
        switch engine {
        case .swiftTerm:
            EmbeddedTerminalView(executable: binary, arguments: arguments, onExit: shellExited)
                .id(sessionID)
        case .ghostty:
            GhosttyTerminalView(executable: binary, arguments: arguments, onExit: shellExited)
                .id(sessionID)
        }
    }

    private func shellExited(_ code: Int32?) {
        exitCode = code
        didExit = true
    }

    private func restart() {
        didExit = false
        exitCode = nil
        sessionID = UUID()
    }
}
