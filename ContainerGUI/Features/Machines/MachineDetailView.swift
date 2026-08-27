import AppKit
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
    /// nil while the machine is still being asked whether it has the VNC stack.
    @State private var didCheckDesktop = false
    @State private var installedEnvironment: MachineDesktopEnvironment?
    @State private var chosenEnvironment: MachineDesktopEnvironment = .default
    @State private var desktopPassword: String?
    @State private var desktopOutput: [LogLine] = []
    @State private var isDesktopWorking = false
    @State private var desktopError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case overview, terminal, desktop, logs, configuration
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Przegląd")
            case .terminal: String(localized: "Terminal")
            case .desktop: String(localized: "Pulpit")
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
            case .desktop: desktop
            case .logs: MachineLogsView(machineName: machine.name)
            case .configuration: MachineConfigView(machine: machine, inspect: inspect)
            }
        }
        // Keyed on the whole row, not just its id: booting or stopping the machine
        // changes its address and state, and `inspect` would otherwise stay stale.
        .task(id: machine) { await loadInspect() }
        .task(id: "\(machine.id)|\(tab.rawValue)") {
            guard tab == .desktop, !didCheckDesktop, machine.isRunning else { return }
            installedEnvironment = await model.machines.installedEnvironment(machine)
            if let installedEnvironment { chosenEnvironment = installedEnvironment }
            didCheckDesktop = true
        }
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

    // MARK: - Desktop

    /// A machine with an X server, a window manager and a VNC server can be opened
    /// in Screen Sharing. This works because a machine has its own routable
    /// address and a port listening inside it is reachable from the host with
    /// nothing published.
    @ViewBuilder
    private var desktop: some View {
        if !machine.isRunning {
            EmptyStateView(
                symbol: "display",
                title: String(localized: "Maszyna jest zatrzymana"),
                message: String(localized: "Pulpit wymaga działającej maszyny. Uruchom ją przyciskiem u góry."),
                tint: .indigo
            )
        } else if isDesktopWorking {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Doinstalowywanie pulpitu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StreamLogBox(lines: desktopOutput)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !didCheckDesktop {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Sprawdzanie…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if installedEnvironment == nil {
                        desktopInstallOffer
                    } else {
                        desktopConnect
                    }
                    if let desktopError {
                        Text(desktopError).font(.caption).foregroundStyle(.red)
                    }
                    if !desktopOutput.isEmpty {
                        StreamLogBox(lines: desktopOutput).frame(minHeight: 120)
                    }
                }
                .padding(12)
            }
        }
    }

    private var desktopInstallOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ta maszyna nie ma jeszcze pulpitu").font(.subheadline.weight(.semibold))
            Picker("Środowisko graficzne", selection: $chosenEnvironment) {
                ForEach(MachineDesktopEnvironment.allCases) { environment in
                    Text(environment.title).tag(environment)
                }
            }
            .pickerStyle(.radioGroup)
            Text(chosenEnvironment.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Zainstaluj pulpit", systemImage: "arrow.down.circle") {
                Task { await installDesktop() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private var desktopConnect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pulpit gotowy").font(.subheadline.weight(.semibold))
            if let installedEnvironment {
                Text(installedEnvironment.title).font(.caption).foregroundStyle(.secondary)
            }
            Text("Połączenie otwiera systemowe Udostępnianie ekranu pod adresem maszyny. Hasło jest generowane na czas działania aplikacji — jeśli je zgubisz, kolejne połączenie ustawi nowe.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Połącz przez VNC", systemImage: "display") {
                    Task { await connectDesktop() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(machine.ipAddress == nil)
                if machine.ipAddress == nil {
                    Text("Maszyna nie ma jeszcze adresu IP.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let desktopPassword {
                HStack(spacing: 8) {
                    Text("Hasło:").font(.caption).foregroundStyle(.secondary)
                    Text(desktopPassword)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Button("Kopiuj", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(desktopPassword, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private func installDesktop() async {
        let environment = chosenEnvironment
        isDesktopWorking = true
        desktopError = nil
        desktopOutput = []
        defer { isDesktopWorking = false }
        do {
            guard await model.machines.waitUntilReady(machine.name) else {
                desktopError = String(localized: "Maszyna nie odpowiada.")
                return
            }
            guard let manager = await model.machines.detectPackageManager(machine) else {
                desktopError = String(localized: "Nie rozpoznano menedżera paczek w maszynie — obsługiwane są apk (Alpine) i apt (Debian, Ubuntu).")
                return
            }
            let stream = model.machines.provisionStream(
                packages: environment.packages(for: manager),
                on: machine.name,
                using: manager
            )
            for try await line in stream {
                desktopOutput.append(LogLine(text: line))
            }
            installedEnvironment = environment
        } catch {
            desktopError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func connectDesktop() async {
        guard let address = machine.ipAddress,
              let url = MachineDesktop.screenSharingURL(host: address)
        else { return }
        desktopError = nil
        do {
            desktopPassword = try await model.machines.startDesktop(
                machine,
                environment: installedEnvironment ?? chosenEnvironment
            )
            NSWorkspace.shared.open(url)
        } catch {
            desktopError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
