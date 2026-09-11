import SwiftUI
import AppKit
import Sparkle

/// The menu bar popover: a glanceable dashboard rather than a list of buttons.
///
/// Everything it shows comes from data the app already collects — `ContainerStore`
/// runs one `container stats --no-stream` per three-second tick for every
/// container, whatever section is on screen, and now keeps a short history of
/// it. So the graphs cost no extra process.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    let updater: SPUUpdater

    /// Most containers a popover shows before it gets taller than it is useful.
    private static let visibleContainers = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.system.serviceState.isRunning {
                activityCard
                if !running.isEmpty { containerList }
            }

            Divider()
            navigation
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .task { await keepFresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor.gradient)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Container Desktop").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.system.serviceState.isTransitioning {
                ProgressView().controlSize(.small)
            } else {
                Button(model.system.serviceState.isRunning ? "Zatrzymaj" : "Uruchom") {
                    Task {
                        if model.system.serviceState.isRunning {
                            await model.stopService()
                        } else {
                            await model.startService()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Aggregate activity

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Sparkline(values: model.containers.usageHistory.total.normalised(), tint: .accentColor)
                .frame(height: 34)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                reading("cpu", String(localized: "CPU"), Format.cpu(model.containers.usageHistory.total.latest))
                reading("memorychip", String(localized: "RAM"), Format.memory(totalMemoryBytes))
                Spacer(minLength: 4)
            }
            // Its own line: beside the readings it wrapped onto two at this width.
            Text(countsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private func reading(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
    }

    // MARK: - Containers

    private var containerList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(running.prefix(Self.visibleContainers)) { container in
                MenuBarContainerRow(
                    container: container,
                    cpuPercent: model.containers.liveStats[container.id]?.cpuPercent,
                    memoryUsedBytes: model.containers.liveStats[container.id]?.memoryUsedBytes,
                    history: model.containers.usageHistory[container: container.id],
                    onStop: { Task { try? await model.containers.stop(container) } }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if running.count > Self.visibleContainers {
                Button {
                    model.selection = .containers
                    openMainWindow()
                } label: {
                    Text("…i \(running.count - Self.visibleContainers) więcej")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            MenuBarActionRow("Zatrzymaj wszystkie", systemImage: "stop.circle") {
                Task { try? await model.containers.stopAll() }
            }
            .padding(.top, 2)
        }
        .animation(.easeInOut(duration: 0.25), value: running.map(\.id))
    }

    // MARK: - Actions

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuBarActionRow("Otwórz okno główne", systemImage: "macwindow") { openMainWindow() }

            Menu {
                ForEach(AppModel.Section.allCases) { section in
                    Button {
                        model.selection = section
                        openMainWindow()
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
            } label: {
                // Same padding and label style as `MenuBarActionRow`: the
                // borderless menu style adds an inset of its own, which left the
                // icon column a few points out of line with its neighbours.
                Label("Przejdź do", systemImage: "square.grid.2x2")
                    .labelStyle(MenuBarLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            MenuBarActionRow("Odśwież", systemImage: "arrow.clockwise") {
                Task { await model.refreshCurrent() }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            CheckForUpdatesView(updater: updater, systemImage: "arrow.down.circle")
                .buttonStyle(.plain)
                .labelStyle(MenuBarLabelStyle())
                .padding(.horizontal, 7)
                .padding(.vertical, 5)

            SettingsLink {
                Label("Ustawienia…", systemImage: "gearshape")
                    .labelStyle(MenuBarLabelStyle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)

            MenuBarActionRow("Zakończ", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Data

    private var running: [ContainerInfo] { model.containers.items.filter(\.isRunning) }

    private var totalMemoryBytes: Int64? {
        let used = running.compactMap { model.containers.liveStats[$0.id]?.memoryUsedBytes }
        return used.isEmpty ? nil : used.reduce(0, +)
    }

    private var countsText: String {
        let stopped = model.containers.items.count - running.count
        return String(
            format: String(localized: "%1$d działa · %2$d zatrzymanych"),
            running.count, stopped
        )
    }

    /// Keeps the graphs moving while the popover is open.
    ///
    /// The app's own polling stops when it goes to the background, and a CPU
    /// percentage only exists from the *second* sample onwards — without this the
    /// popover would open showing dashes and never fill in.
    private func keepFresh() async {
        while !Task.isCancelled {
            await model.containers.refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private var statusColor: Color {
        switch model.system.serviceState {
        case .running: .green
        case .stopped: .red
        case .starting, .stopping: .orange
        case .unknown: .gray
        }
    }

    private var statusText: String {
        switch model.system.serviceState {
        case .running: String(localized: "Usługa działa")
        case .stopped: String(localized: "Usługa zatrzymana")
        case .starting: String(localized: "Uruchamianie…")
        case .stopping: String(localized: "Zatrzymywanie…")
        case .unknown: String(localized: "Sprawdzanie…")
        }
    }
}
