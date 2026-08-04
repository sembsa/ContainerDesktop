import GhosttyTerminal
import SwiftUI

/// The container shell rendered by Ghostty's engine (libghostty).
///
/// Nothing is piped through the app here: with the `.exec` backend libghostty
/// spawns the process itself and owns the PTY, the window size and the exit
/// report. The process to run is handed over as a ghostty `command` config line —
/// libghostty has no per-surface command field, so each terminal gets its own
/// controller carrying its own config.
struct GhosttyTerminalView: View {
    let executable: String
    let arguments: [String]
    let onExit: (Int32?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var state: TerminalViewState

    init(executable: String, arguments: [String], onExit: @escaping (Int32?) -> Void) {
        self.executable = executable
        self.arguments = arguments
        self.onExit = onExit

        let command = TerminalCommandLine.string(executable: executable, arguments: arguments)
        _state = StateObject(wrappedValue: TerminalViewState(
            controller: TerminalController { builder in
                builder.withCustom("command", command)
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(6)
            }
        ))
    }

    var body: some View {
        TerminalSurfaceView(context: state)
            .onAppear {
                state.configuration = TerminalSurfaceOptions(backend: .exec)
                state.onClose = { [state] _ in
                    onExit(state.lastCommandExitCode.map(Int32.init))
                }
                applyColorScheme()
            }
            .onChange(of: colorScheme) { applyColorScheme() }
    }

    private func applyColorScheme() {
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
    }
}
