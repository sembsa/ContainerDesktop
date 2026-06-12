import SwiftUI
import AppKit

// MARK: - Row model for hierarchical table

private struct ContainerRow: Identifiable {
    let id: String
    let container: ContainerInfo?    // nil = project header row
    let projectName: String?         // non-nil for header rows
    var children: [ContainerRow]?    // containers belonging to this project
}

struct ContainersView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ContainerRow.ID?
    @State private var showRunSheet = false
    @State private var showComposeSheet = false
    @State private var recreateTarget: ContainerInfo?
    @State private var confirmation: ContainerConfirmation?

    enum ContainerConfirmation: Identifiable {
        case remove(ContainerInfo)
        case prune
        case removeProject(String, [ContainerInfo])
        var id: String {
            switch self {
            case .remove(let container): "remove-\(container.id)"
            case .prune: "prune"
            case .removeProject(let name, _): "project-\(name)"
            }
        }
    }

    private var store: ContainerStore { model.containers }

    private var selectedContainer: ContainerInfo? {
        guard let sel = selection else { return nil }
        // Flat search across all items
        return store.items.first { $0.id == sel }
    }

    // MARK: - Row computation

    private var rows: [ContainerRow] {
        var result: [ContainerRow] = []

        // Group by composeProject
        var projectMap: [String: [ContainerInfo]] = [:]
        var ungrouped: [ContainerInfo] = []

        for container in store.items {
            if let proj = container.composeProject {
                projectMap[proj, default: []].append(container)
            } else {
                ungrouped.append(container)
            }
        }

        // Project rows first (alphabetical)
        for projName in projectMap.keys.sorted() {
            let children = projectMap[projName]!
                .sorted { $0.id < $1.id }
                .map { ContainerRow(id: $0.id, container: $0, projectName: nil, children: nil) }
            result.append(ContainerRow(
                id: "project:\(projName)",
                container: nil,
                projectName: projName,
                children: children
            ))
        }

        // Ungrouped containers after projects
        for container in ungrouped {
            result.append(ContainerRow(id: container.id, container: container, projectName: nil, children: nil))
        }

        return result
    }

    var body: some View {
        GeometryReader { geo in
            VSplitView {
                listSection
                    .frame(
                        minHeight: 130,
                        maxHeight: selectedContainer == nil ? .infinity : max(geo.size.height * 0.4, 130)
                    )
                if let selected = selectedContainer {
                    ContainerDetailView(container: selected)
                        .frame(minHeight: 320, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Kontenery")
        .task { await store.refresh() }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showRunSheet) {
            RunContainerSheet()
                .environment(model)
        }
        .sheet(isPresented: $showComposeSheet) {
            ComposeSheet()
                .environment(model)
        }
        .sheet(item: $recreateTarget) { container in
            RunContainerSheet(recreating: container)
                .environment(model)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            switch item {
            case .remove(let container):
                Button("Usuń", role: .destructive) {
                    Task { await perform { try await store.remove(container, force: true) } }
                }
                Button("Anuluj", role: .cancel) {}
            case .prune:
                Button("Usuń zatrzymane", role: .destructive) {
                    Task { await perform { try await store.prune() } }
                }
                Button("Anuluj", role: .cancel) {}
            case .removeProject(_, let containers):
                Button("Usuń projekt", role: .destructive) {
                    Task {
                        for container in containers {
                            await perform { try await store.remove(container, force: true) }
                        }
                    }
                }
                Button("Anuluj", role: .cancel) {}
            }
        } message: { item in
            switch item {
            case .remove(let container): Text("Kontener \(container.id) zostanie nieodwracalnie usunięty.")
            case .prune: Text("Usunięte zostaną wszystkie zatrzymane kontenery.")
            case .removeProject(let name, _): Text("Wszystkie kontenery projektu \(name) zostaną usunięte.")
            }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .remove: String(localized: "Usunąć kontener?")
        case .prune: String(localized: "Usunąć zatrzymane kontenery?")
        case .removeProject: String(localized: "Usunąć projekt?")
        case nil: ""
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var listSection: some View {
        if store.items.isEmpty {
            if model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: String(localized: "Brak kontenerów"),
                    message: String(localized: "Uruchom kontener z obrazu, aby zobaczyć go tutaj."),
                    actionTitle: String(localized: "Uruchom kontener…"),
                    action: { showRunSheet = true },
                    tint: .blue
                )
            } else {
                Color.clear
            }
        } else {
            Table(of: ContainerRow.self, selection: $selection) {
                // Status indicator column
                TableColumn("") { row in
                    if row.projectName != nil {
                        // Empty for project header
                        Color.clear.frame(width: 9, height: 9)
                    } else if let container = row.container {
                        Group {
                            if store.pendingIDs.contains(container.id) {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                StatusDot(state: container.state)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: store.pendingIDs.contains(container.id))
                    }
                }
                .width(20)

                TableColumn("Nazwa") { row in
                    if let projName = row.projectName {
                        // Project header
                        let children = row.children ?? []
                        let running = children.filter { $0.container?.isRunning == true }.count
                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.down.right.fill")
                                .foregroundStyle(.cyan)
                            Text(projName)
                                .fontWeight(.semibold)
                            Text(String(format: String(localized: "%lld/%lld działa"), Int64(running), Int64(children.count)))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    } else if let container = row.container {
                        Text(container.id).fontWeight(.medium)
                    }
                }

                TableColumn("Obraz") { row in
                    if let container = row.container {
                        Text(container.imageReference)
                            .foregroundStyle(.secondary)
                    }
                }

                TableColumn("Stan") { row in
                    if let container = row.container {
                        Text(container.state)
                            .foregroundStyle(container.isRunning ? Color.green : Color.secondary)
                    }
                }

                TableColumn("Arch") { row in
                    if let container = row.container {
                        let arch = container.architecture ?? "—"
                        let rosetta = container.configuration.rosetta == true
                        HStack(spacing: 2) {
                            Text(rosetta ? "\(arch) +R" : arch)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .help(rosetta ? String(localized: "Rosetta włączona") : arch)
                    }
                }
                .width(80)

                TableColumn("Adres IP") { row in
                    if let container = row.container {
                        Text(container.primaryIPv4 ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }

                TableColumn("Porty") { row in
                    if let container = row.container {
                        portsCell(for: container)
                    }
                }

                TableColumn("Akcje") { row in
                    if let projName = row.projectName {
                        projectActionButtons(projectName: projName, children: row.children ?? [])
                    } else if let container = row.container {
                        containerActionButtons(container: container)
                    }
                }
                .width(110)
            } rows: {
                ForEach(rows) { row in
                    if let children = row.children {
                        DisclosureTableRow(row) {
                            ForEach(children) { child in
                                TableRow(child)
                            }
                        }
                    } else {
                        TableRow(row)
                    }
                }
            }
            .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
                if let id = ids.first {
                    if let row = rows.first(where: { $0.id == id }), let projName = row.projectName {
                        // Project context menu
                        let children = row.children ?? []
                        Button("Uruchom wszystkie") {
                            Task {
                                for child in children {
                                    if let c = child.container, !c.isRunning {
                                        await perform { try await store.start(c) }
                                    }
                                }
                            }
                        }
                        Button("Zatrzymaj wszystkie") {
                            Task {
                                for child in children {
                                    if let c = child.container, c.isRunning {
                                        await perform { try await store.stop(c) }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Usuń projekt…", role: .destructive) {
                            confirmation = .removeProject(projName, children.compactMap(\.container))
                        }
                    } else if let container = store.items.first(where: { $0.id == id }) {
                        rowActions(for: container)
                    }
                }
            }
        }
    }

    // MARK: - Action buttons (inline in table column)

    @ViewBuilder
    private func containerActionButtons(container: ContainerInfo) -> some View {
        let isPending = store.pendingIDs.contains(container.id)
        HStack(spacing: 4) {
            if container.isRunning {
                Button {
                    Task { await perform { try await store.stop(container) } }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isPending)
                .help("Zatrzymaj")

                Button {
                    Task { await perform { try await store.restart(container) } }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isPending)
                .help("Uruchom ponownie")
            } else {
                Button {
                    Task { await perform { try await store.start(container) } }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isPending)
                .help("Uruchom")
            }
        }
    }

    @ViewBuilder
    private func projectActionButtons(projectName: String, children: [ContainerRow]) -> some View {
        let containers = children.compactMap(\.container)
        let anyRunning = containers.contains { $0.isRunning }
        let anyStopped = containers.contains { !$0.isRunning }
        HStack(spacing: 4) {
            if anyStopped {
                Button {
                    Task {
                        for c in containers where !c.isRunning {
                            await perform { try await store.start(c) }
                        }
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Uruchom wszystkie")
            }
            if anyRunning {
                Button {
                    Task {
                        for c in containers where c.isRunning {
                            await perform { try await store.stop(c) }
                        }
                    }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Zatrzymaj wszystkie")
            }
        }
    }

    // MARK: - Context menu actions

    @ViewBuilder
    private func rowActions(for container: ContainerInfo) -> some View {
        let isPending = store.pendingIDs.contains(container.id)
        if isPending {
            Text("Akcja w toku…")
        } else if container.isRunning {
            Button("Zatrzymaj") { Task { await perform { try await store.stop(container) } } }
            Button("Uruchom ponownie") { Task { await perform { try await store.restart(container) } } }
            Button("Zabij") { Task { await perform { try await store.kill(container) } } }
        } else {
            Button("Uruchom") { Task { await perform { try await store.start(container) } } }
        }
        Divider()
        Button("Zmień polecenie / konfigurację…", systemImage: "slider.horizontal.3") {
            recreateTarget = container
        }
        .disabled(isPending)
        Divider()
        Button("Eksportuj do tar…") { exportContainer(container) }
            .disabled(isPending)
        Button("Usuń…", role: .destructive) { confirmation = .remove(container) }
            .disabled(isPending)
    }

    /// Ports with a tiny open-in-browser arrow for reachable (running, tcp,
    /// host-published) mappings.
    @ViewBuilder
    private func portsCell(for container: ContainerInfo) -> some View {
        if let ports = container.configuration.publishedPorts, !ports.isEmpty {
            HStack(spacing: 8) {
                ForEach(ports) { port in
                    HStack(spacing: 2) {
                        Text(port.display)
                            .foregroundStyle(.secondary)
                        if container.isRunning,
                           let hostPort = port.hostPort,
                           (port.proto ?? "tcp") == "tcp" {
                            Button {
                                if let url = URL(string: "http://localhost:\(hostPort)") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .help(String(format: String(localized: "Otwórz http://localhost:%lld w przeglądarce"), hostPort))
                        }
                    }
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func exportContainer(_ container: ContainerInfo) {
        guard !container.isRunning else {
            model.present(CLIError.command(
                exitCode: -1,
                stderr: String(localized: "Eksport wymaga zatrzymanego kontenera. Zatrzymaj kontener i spróbuj ponownie.")
            ))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(container.id).tar"
        panel.message = String(localized: "Zapisz system plików kontenera jako archiwum tar")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { try await store.export(container, to: url) } }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showComposeSheet = true
            } label: {
                Label("Compose…", systemImage: "square.stack.3d.down.right")
            }
            .disabled(!model.system.serviceState.isRunning)

            Button {
                showRunSheet = true
            } label: {
                Label("Uruchom kontener", systemImage: "plus")
            }
            .disabled(!model.system.serviceState.isRunning)

            Button {
                confirmation = .prune
            } label: {
                Label("Wyczyść zatrzymane", systemImage: "trash")
            }
            .disabled(!model.system.serviceState.isRunning)

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

/// Colored status indicator for a container state.
struct StatusDot: View {
    let state: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .help(state)
    }

    private var color: Color {
        switch state.lowercased() {
        case "running": .green
        case "stopped", "exited": .secondary
        default: .orange
        }
    }
}
