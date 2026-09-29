import AppKit
import SwiftUI

/// `container machine logs` — deliberately its own view rather than a reuse of
/// the container log viewer.
///
/// A machine has two separate logs: the stdio of whatever init the image runs,
/// and the boot log from `vminitd`. The container viewer has no such axis, and it
/// also carries a workaround for a container-specific CLI bug (it asks for one
/// extra line and drops the first, because `container logs -n` returns a
/// truncated first line) that has no business being applied here.
struct MachineLogsView: View {
    let machineName: String

    @State private var kind: Kind = .stdio
    @State private var follow = true
    @State private var lines: [LogLine] = []
    /// Collected but not yet drawn. Publishing per line re-renders the view for
    /// every one of them, so lines are handed over in batches.
    @State private var pending: [LogLine] = []
    @State private var streamEnded = false
    @State private var didLoad = false
    @State private var errorText: String?

    /// Machine logs are printed in full when `-n` is omitted, and a boot log runs
    /// to thousands of lines. A tail is the sane default.
    private static let tailLines = 500

    enum Kind: String, CaseIterable, Identifiable {
        case stdio, boot
        var id: String { rawValue }

        var title: String {
            switch self {
            case .stdio: String(localized: "Standardowe wyjście")
            case .boot: String(localized: "Log rozruchu")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            controls
        }
        .task(id: reloadKey) { await load() }
    }

    /// Every knob here changes the argv, so the stream has to be restarted rather
    /// than filtered.
    private var reloadKey: String { "\(machineName)|\(kind.rawValue)|\(follow)" }

    @MainActor
    private func export(_ scope: LogExportScope) async {
        let subject = kind == .boot ? "\(machineName)-boot" : machineName
        guard let url = LogExport.chooseDestination(
            suggesting: LogExport.suggestedName(for: subject, at: .now)
        ) else { return }
        do {
            switch scope {
            case .visible:
                try LogExport.write(lines.map(\.text), to: url)
            case .everything:
                // `lines: nil` is what omits -n, so the CLI prints the lot; it
                // goes straight to the file rather than through a String.
                let result = try await ContainerCLI.shared.runRedirecting(
                    MachineCommands.logs(
                        name: machineName, boot: kind == .boot, follow: false, lines: nil
                    ),
                    outputPath: url.path
                )
                if result.exitCode != 0 {
                    throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var controls: some View {
        LogToolbar(
            lineCount: lines.count, autoscroll: $follow, copy: copyAll,
            exportScopes: [.visible, .everything],
            export: { scope in Task { await export(scope) } }
        ) {
            Picker("Strumień", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Nie udało się odczytać logów"),
                message: errorText,
                tint: .orange
            )
        } else if lines.isEmpty, didLoad || streamEnded {
            EmptyStateView(
                symbol: "doc.text",
                title: String(localized: "Brak logów"),
                message: kind == .boot
                    ? String(localized: "Maszyna nie zapisała logu rozruchu — najczęściej znaczy to, że nigdy nie była uruchomiona.")
                    : String(localized: "Maszyna nie wypisała nic na stdout/stderr. Obraz bez systemu init często nie generuje żadnych logów."),
                tint: .indigo
            )
        } else if lines.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Wczytywanie logów…")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(lines: lines, showTimestamps: false, autoscroll: follow, colorize: true)
        }
    }

    // MARK: - Streaming

    private func load() async {
        lines = []
        pending = []
        errorText = nil
        streamEnded = false
        didLoad = false

        let arguments = MachineCommands.logs(
            name: machineName,
            boot: kind == .boot,
            follow: follow,
            lines: Self.tailLines
        )
        // The handover is driven by a clock, not by the next line arriving. With
        // `--follow` the stream never ends, so batching purely on a line count
        // holds the last partial batch forever: a machine whose init writes three
        // lines would sit behind a spinner indefinitely, and one that writes none
        // would never reach the empty state either.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                flush()
                didLoad = true
            }
        }
        defer { ticker.cancel() }

        do {
            for try await line in ContainerCLI.shared.stream(arguments) {
                pending.append(LogLine(text: line))
                if pending.count >= 40 { flush() }
            }
            flush()
            streamEnded = true
        } catch is CancellationError {
            return
        } catch {
            flush()
            if lines.isEmpty { errorText = error.localizedDescription }
        }
        didLoad = true
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending = []
        didLoad = true
    }

    private func copyAll() {
        let text = lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
