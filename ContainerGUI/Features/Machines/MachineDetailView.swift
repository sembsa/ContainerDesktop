import SwiftUI

/// What a machine actually is, once you select it: what it was built from, a
/// shell inside it, its logs, and the knobs `machine set` exposes.
///
/// Machines were the one section with no detail pane at all — the table said
/// "running" and stopped there, even though a machine is the longest-lived thing
/// the app manages.
struct MachineDetailView: View {
    @Environment(AppModel.self) private var model

    let machine: MachineInfo

    @State private var tab: Tab = .overview
    @State private var inspect: MachineInspect?
    @State private var isLoadingInspect = false
    @State private var inspectError: String?
    @State private var shellAsRoot = false

    enum Tab: String, CaseIterable, Identifiable {
        case overview, terminal, logs, configuration
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Przegląd")
            case .terminal: String(localized: "Terminal")
            case .logs: String(localized: "Logi")
            case .configuration: String(localized: "Konfiguracja")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .overview: overview
            case .terminal: terminal
            case .logs: MachineLogsView(machineName: machine.name)
            case .configuration: MachineConfigView(machine: machine, inspect: inspect)
            }
        }
        .task(id: machine.id) { await loadInspect() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(machine.name).font(.headline)
                    if machine.isDefault == true {
                        Text("domyślna")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                Text(machine.isRunning
                     ? String(localized: "Maszyna działa")
                     : String(localized: "Maszyna zatrzymana"))
                    .font(.caption)
                    .foregroundStyle(machine.isRunning ? Color.green : .secondary)
            }
            Spacer()
            lifecycleButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var lifecycleButton: some View {
        let isBusy = model.machines.busyNames.contains(machine.name)
        if machine.isRunning {
            Button("Zatrzymaj", systemImage: "stop.fill") {
                Task { await perform { try await model.machines.stop(machine) } }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        } else {
            Button("Uruchom", systemImage: "play.fill") {
                Task { await perform { try await model.machines.boot(machine) } }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                factGrid
                if let inspect { sourceSection(inspect) }
                if let inspectError {
                    Text(inspectError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
        }
    }

    private var factGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            fact(String(localized: "Stan"), machine.status ?? "—", "circle.fill")
            fact(String(localized: "Rdzenie"), machine.cpus.map(String.init) ?? "—", "cpu")
            fact(String(localized: "Pamięć"), Format.bytes(machine.memoryBytes), "memorychip")
            fact(String(localized: "Dysk"), Format.bytes(machine.diskSizeBytes), "internaldrive")
            // The address is handed out afresh on every boot, so it is worth
            // reading here rather than remembering.
            fact(String(localized: "Adres IP"), machine.ipAddress ?? "—", "network")
            fact(String(localized: "Platforma"), inspect?.platform?.label ?? "—", "cpu.fill")
            fact(String(localized: "Katalog domowy"), homeMountLabel, "house")
            fact(String(localized: "Użytkownik"), inspect?.userSetup?.username ?? "—", "person")
            fact(
                String(localized: "Uruchomiona"),
                inspect?.startedDate?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                "clock"
            )
            fact(
                String(localized: "Utworzona"),
                machine.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                "calendar"
            )
        }
    }

    private var homeMountLabel: String {
        guard let raw = inspect?.homeMount else { return isLoadingInspect ? "…" : "—" }
        return MachineCommands.HomeMount(rawValue: raw)?.title ?? raw
    }

    private func fact(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func sourceSection(_ inspect: MachineInspect) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.purple.gradient)
                Text("Obraz źródłowy").font(.subheadline.weight(.semibold))
                Spacer()
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                sourceRow(String(localized: "Referencja"), inspect.image?.reference)
                sourceRow(String(localized: "Digest"), inspect.image?.descriptor?.digest)
                sourceRow(String(localized: "Kontener maszyny"), inspect.containerId)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private func sourceRow(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value ?? "—")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value ?? "")
                .textSelection(.enabled)
        }
    }

    // MARK: - Terminal

    private var terminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("Jako root", isOn: $shellAsRoot)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(String(localized: "Bez tego shell działa jako Twój użytkownik z hosta."))
                Spacer()
                if !machine.isRunning {
                    Label("Otwarcie shella uruchomi maszynę", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            TerminalSessionView(target: .machine(name: machine.name, asRoot: shellAsRoot))
                // Changing the user has to restart the session — the flag is part
                // of the command line, not something the running shell can adopt.
                .id(shellAsRoot)
        }
    }

    // MARK: - Loading

    private func loadInspect() async {
        isLoadingInspect = true
        inspectError = nil
        defer { isLoadingInspect = false }
        do {
            inspect = try await model.machines.inspect(machine.name)
        } catch {
            inspect = nil
            inspectError = error.localizedDescription
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}
