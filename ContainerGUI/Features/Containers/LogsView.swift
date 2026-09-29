import AppKit
import SwiftUI

struct LogsView: View {
    let containerID: String

    @AppStorage(LogTailLimit.storageKey) private var tailRawValue = LogTailLimit.default.rawValue
    @State private var lines: [LogLine] = []
    @State private var autoscroll = true
    @State private var showTimestamps = false
    @State private var streamEnded = false
    /// Backlog held back until `backlogWindow` elapses, so a long history is drawn
    /// once instead of batch after batch.
    @State private var backlog: [LogLine] = []
    /// Set when the backlog has been handed over — also what dismisses the spinner,
    /// because with `--follow` a quiet container never ends the stream.
    @State private var backlogDrawn = false
    @State private var exportError: String?
    @State private var isExporting = false

    private var tail: LogTailLimit {
        LogTailLimit(rawValue: tailRawValue) ?? .default
    }

    var body: some View {
        Group {
            if lines.isEmpty && (streamEnded || backlogDrawn) {
                EmptyStateView(
                    symbol: "doc.text",
                    title: String(localized: "Brak logów"),
                    message: String(localized: "Kontener nie wypisał nic na stdout/stderr. Kontenery typu `sleep` nie generują logów."),
                    tint: .blue
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
                VStack(spacing: 0) {
                    LogTextView(
                        lines: lines,
                        showTimestamps: showTimestamps,
                        autoscroll: autoscroll,
                        colorize: true
                    )
                    LogToolbar(
                        lineCount: lines.count,
                        timestamps: $showTimestamps,
                        autoscroll: $autoscroll,
                        copy: copyAll,
                        exportScopes: [.visible, .everything],
                        export: { scope in Task { await export(scope) } }
                    ) {
                        Picker(selection: $tailRawValue) {
                            ForEach(LogTailLimit.allCases) { limit in
                                Text(limit.title).tag(limit.rawValue)
                            }
                        } label: {
                            Text("Ile historii")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .help(String(localized: "Ile historii pobrać. Cały log może być bardzo duży — wczytanie i wyrysowanie zajmie wtedy chwilę."))
                    }
                }
            }
        }
        // Restarts the stream when the container *or* the amount of history changes.
        .task(id: "\(containerID)#\(tailRawValue)") {
            await streamLogs()
        }
        .alert(
            "Nie udało się zapisać logu",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Receipt-time timestamp: `container logs` does not emit timestamps, so
    /// lines from the initial backlog all carry the moment they were read.
    private func display(_ line: LogLine) -> String {
        let text = line.text.isEmpty ? " " : line.text
        guard showTimestamps else { return text }
        return "[\(Self.timeFormatter.string(from: line.date))] \(text)"
    }

    /// Writes the log out.
    ///
    /// `.visible` is what the pane holds, formatted the way it is shown — the
    /// timestamp toggle included, because a file that disagrees with the screen
    /// it came from is its own small betrayal. `.everything` ignores the history
    /// limit and asks the CLI again, writing stdout **straight to the file**:
    /// a long-lived container's whole log does not belong in a `String`, and a
    /// tar-shaped lesson elsewhere in this app says bytes that are not valid
    /// UTF-8 do not survive the trip.
    @MainActor
    private func export(_ scope: LogExportScope) async {
        guard !isExporting else { return }
        let name = LogExport.suggestedName(for: containerID, at: .now)
        guard let url = LogExport.chooseDestination(suggesting: name) else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            switch scope {
            case .visible:
                try LogExport.write(lines.map(display), to: url)
            case .everything:
                let result = try await ContainerCLI.shared.runRedirecting(
                    ["logs", containerID], outputPath: url.path
                )
                if result.exitCode != 0 {
                    throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
                }
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func copyAll() {
        let content = lines.map(display).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func streamLogs() async {
        let tail = tail
        lines = []
        backlog = []
        backlogDrawn = false
        streamEnded = false
        let stream = ContainerCLI.shared.stream(["logs"] + tail.arguments + ["--follow", containerID])
        // Two phases. While the backlog pours in, lines are only collected — a
        // container with thousands of lines of history would otherwise be drawn a
        // batch at a time, all of it, and only the last screenful matters. After
        // `backlogWindow` whatever survived trimming is drawn once, and from then
        // on lines are appended as they arrive (still batched, because publishing
        // per line re-renders the view).
        //
        // The handover is driven by a timer, not by the next line arriving: a
        // stopped container delivers its whole history in milliseconds and then
        // `--follow` waits forever for output that will never come, so waiting for
        // one more line to trigger the draw left the spinner up indefinitely.
        let handover = Task { @MainActor in
            try? await Task.sleep(for: Self.backlogWindow)
            drawBacklog(tail: tail)
        }
        defer { handover.cancel() }

        var pending: [LogLine] = []
        var lastFlush = ContinuousClock.now
        do {
            for try await line in stream {
                let entry = LogLine(text: line)
                if !backlogDrawn {
                    backlog.append(entry)
                    trimToRetained(&backlog, tail: tail)
                    continue
                }
                pending.append(entry)
                let now = ContinuousClock.now
                guard pending.count >= 250 || now - lastFlush > .milliseconds(120) else { continue }
                append(pending, tail: tail)
                pending.removeAll(keepingCapacity: true)
                lastFlush = now
            }
        } catch {
            let failure = LogLine(text: String(format: String(localized: "[błąd strumienia logów: %@]"), error.localizedDescription))
            if backlogDrawn { pending.append(failure) } else { backlog.append(failure) }
        }
        handover.cancel()
        drawBacklog(tail: tail)          // in case the stream ended inside the window
        append(pending, tail: tail)
        streamEnded = true
    }

    /// How long the initial backlog is collected before anything is drawn.
    private static let backlogWindow = Duration.milliseconds(400)

    /// Hands the collected backlog over to the view — once.
    private func drawBacklog(tail: LogTailLimit) {
        guard !backlogDrawn else { return }
        backlogDrawn = true
        // `arguments` asks for one line more than wanted because the CLI truncates
        // the first one (apple/container#2022). More lines than asked for means
        // history was actually cut, so that first line is the fragment — drop it.
        if tail != .all, backlog.count > tail.rawValue {
            backlog.removeFirst()
        }
        append(backlog, tail: tail)
        backlog = []
    }

    private func append(_ newLines: [LogLine], tail: LogTailLimit) {
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        guard lines.count > tail.retainedLines else { return }
        // Trimmed in chunks, not down to the limit on every line: dropping the
        // first line changes the array's head, which makes LogTextView rebuild
        // its whole storage. Once per chunk is affordable; once per line is not.
        lines.removeFirst(lines.count - tail.retainedLines * 3 / 4)
    }

    /// Caps the not-yet-drawn backlog, keeping the newest lines.
    private func trimToRetained(_ buffer: inout [LogLine], tail: LogTailLimit) {
        guard buffer.count > tail.retainedLines else { return }
        buffer.removeFirst(buffer.count - tail.retainedLines)
    }
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let date = Date()
    let text: String
}
