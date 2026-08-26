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
            controls
            Divider()
            content
        }
        .task(id: reloadKey) { await load() }
    }

    /// Every knob here changes the argv, so the stream has to be restarted rather
    /// than filtered.
    private var reloadKey: String { "\(machineName)|\(kind.rawValue)|\(follow)" }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle("Śledź", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Spacer()

            if !lines.isEmpty {
                Text("\(lines.count) linii")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Kopiuj", systemImage: "doc.on.doc") { copyAll() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
        errorText = nil
        streamEnded = false
        didLoad = false

        let arguments = MachineCommands.logs(
            name: machineName,
            boot: kind == .boot,
            follow: follow,
            lines: Self.tailLines
        )
        var pending: [LogLine] = []
        do {
            for try await line in ContainerCLI.shared.stream(arguments) {
                pending.append(LogLine(text: line))
                // Publishing per line re-renders the view for every one of them.
                if pending.count >= 40 {
                    lines.append(contentsOf: pending)
                    pending = []
                    didLoad = true
                }
            }
            lines.append(contentsOf: pending)
            streamEnded = true
        } catch is CancellationError {
            return
        } catch {
            lines.append(contentsOf: pending)
            if lines.isEmpty { errorText = error.localizedDescription }
        }
        didLoad = true
    }

    private func copyAll() {
        let text = lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
