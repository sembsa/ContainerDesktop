import SwiftUI
import AppKit

struct NetworksView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: NetworkEntry.ID?
    @State private var showCreate = false
    @State private var confirmation: NetworkConfirmation?
    @AppStorage("networksViewMode") private var viewMode: NetworksViewMode = .list
    @AppStorage("networkGrouping") private var grouping: ListGrouping = .machine
    @AppStorage("collapsedListGroups") private var collapsedGroups = ""

    enum NetworkConfirmation: Identifiable {
        case remove(NetworkEntry)
        case prune
        var id: String {
            switch self {
            case .remove(let network): "remove-\(network.id)"
            case .prune: "prune"
            }
        }
    }

    private var store: NetworkStore { model.networks }

    /// Machines the peers' addresses are matched against: the WireGuard
    /// addresses seen on this Mac and each external machine, and the IP an
    /// external machine is reached at.
    private var knownHosts: [WireGuardKnownHost] {
        let interfaces = store.items.compactMap { entry -> (machine: String, interface: WireGuardInterface)? in
            guard entry.kind == .wireguard, let interface = entry.wireGuard else { return nil }
            return (entry.location == .external ? (entry.machineLabel ?? "") : String(localized: "Ten Mac"), interface)
        }
        let endpoints = store.machineProvider().map { (label: $0.label, host: $0.host) }
        return WireGuardPeerPresenter.knownHosts(interfaces: interfaces, endpoints: endpoints)
    }

    /// Apple's service must be up to create or prune there; a local Docker
    /// engine can create without it.
    private var canCreate: Bool {
        model.system.serviceState.isRunning || model.containers.installedRuntimes.contains(.docker)
    }

    var body: some View {
        Group {
            if viewMode == .topology {
                NetworkTopologyView(
                    entries: store.items,
                    knownMachines: store.machineProvider().map { (label: $0.label, host: $0.host) },
                    containers: model.containers.items,
                    volumes: model.volumes.items,
                    onOpenContainer: { model.openInContainerList($0) }
                )
            } else if store.items.isEmpty, !store.isLoading {
                EmptyStateView(
                    symbol: "network",
                    title: String(localized: "Brak sieci"),
                    message: String(localized: "Utwórz sieć, aby połączyć kontenery."),
                    actionTitle: String(localized: "Utwórz sieć…"),
                    action: { showCreate = true },
                    tint: .teal
                )
            } else {
                List(selection: $selection) {
                    if grouping.restricted(to: ListGrouping.simple) == .none {
                        ForEach(store.filteredItems) { network in
                            NetworkRow(network: network, knownHosts: knownHosts).tag(network.id)
                        }
                    } else {
                        ForEach(ListGrouper.group(store.filteredItems, by: grouping)) { section in
                            let collapseID = "networks|" + section.id
                            let collapsed = CollapsedGroups.isCollapsed(collapseID, in: collapsedGroups)
                            Section {
                                if !collapsed {
                                    ForEach(section.items) { network in
                                        NetworkRow(network: network, knownHosts: knownHosts).tag(network.id)
                                    }
                                }
                            } header: {
                                GroupHeader(title: section.title, count: section.count, isCollapsed: collapsed) {
                                    collapsedGroups = CollapsedGroups.toggled(collapseID, in: collapsedGroups)
                                }
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
                    if let id = ids.first, let network = store.items.first(where: { $0.id == id }),
                       network.actions.contains(.remove) {
                        Button("Usuń…", role: .destructive) { confirmation = .remove(network) }
                            .disabled(!network.canRemove)
                    }
                }
            }
        }
        .navigationTitle("Sieci")
        .safeAreaInset(edge: .bottom) { failureBanner }
        .task { await store.refresh(appleAvailable: model.system.serviceState.isRunning) }
        // The topology's drill-down shows volumes too, which the tick does not refresh on this page.
        .task(id: viewMode) {
            if viewMode == .topology { await model.volumes.refresh(appleAvailable: model.system.serviceState.isRunning) }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Widok", selection: $viewMode) {
                    ForEach(NetworksViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Przełącz między listą a topologią sieci")
                if viewMode == .list {
                    sourcePicker
                    GroupingPicker(selection: $grouping, options: ListGrouping.simple)
                }
                InfoTip(text: String(localized: "Kontenery w tej samej sieci widzą się nawzajem po nazwie. Domyślna sieć łączy wszystkie kontenery bez przypisanej sieci."), size: .regular)
                Button { showCreate = true } label: { Label("Utwórz", systemImage: "plus") }
                    .disabled(!canCreate)
                Button { confirmation = .prune } label: { Label("Wyczyść", systemImage: "trash") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { Task { await store.refresh(appleAvailable: model.system.serviceState.isRunning, force: true) } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showCreate) { NetworkCreateSheet().environment(model) }
        .itemConfirmationDialog(
            Text(confirmationTitle),
            item: $confirmation
        ) { item in
            switch item {
            case .remove(let network):
                Button("Usuń", role: .destructive) {
                    Task { await perform { try await store.remove(network) } }
                }
                Button("Anuluj", role: .cancel) {}
            case .prune:
                Button("Usuń nieużywane", role: .destructive) {
                    Task { await perform { try await store.prune() } }
                }
                Button("Anuluj", role: .cancel) {}
            }
        } message: { item in
            switch item {
            case .remove(let network): Text("Sieć \(network.name) zostanie usunięta.")
            case .prune: Text("Usunięte zostaną wszystkie nieużywane sieci.")
            }
        }
    }

    /// Each picker is only offered when it has something to choose between,
    /// like the container list's.
    @ViewBuilder
    private var sourcePicker: some View {
        @Bindable var store = store
        if store.machineOptions.count > 1 {
            Picker("Maszyna", selection: $store.machineFilter) {
                Text("Wszystkie maszyny").tag(MachineFilter?.none)
                ForEach(store.machineOptions, id: \.self) { option in
                    Text(option.title).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .help("Pokaż sieci z jednej maszyny")
        }
        if store.runtimeOptions.count > 1 {
            Picker("Silnik", selection: $store.runtimeFilter) {
                Text("Wszystkie silniki").tag(NetworkRuntimeFilter?.none)
                ForEach(store.runtimeOptions) { option in
                    Text(option.title).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .help("Pokaż sieci z jednego silnika")
        }
    }

    /// Sources that did not answer. They never block the rest of the list.
    @ViewBuilder
    private var failureBanner: some View {
        if !store.failures.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.failures) { failure in
                    Label {
                        Text(verbatim: "\(failure.source): \(failure.message)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .remove: String(localized: "Usunąć sieć?")
        case .prune: String(localized: "Usunąć nieużywane sieci?")
        case nil: ""
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

/// One network: name, the three source tags, the addressing line and — for a
/// WireGuard interface — a summary that expands into its peers.
struct NetworkRow: View {
    let network: NetworkEntry
    var knownHosts: [WireGuardKnownHost] = []
    @State private var expanded = false

    private var isWireGuard: Bool { network.kind == .wireguard }
    private var labelStore = WireGuardPeerLabelStore.shared

    /// "Peery (3) · Mac Studio, Rick's phone": the count, then the first few
    /// names (labels first). Every name is in the tooltip.
    private func peerSummary(_ interface: WireGuardInterface) -> some View {
        let rows = WireGuardPeerPresenter.rows(for: interface, aliases: labelStore.names, knownHosts: knownHosts)
        let names = WireGuardPeerPresenter.peerNames(rows)
        let summary = WireGuardPeerPresenter.summary(of: rows)
        let count = String(format: String(localized: "Peery (%lld)"), Int64(interface.peers.count))
        return Text(verbatim: summary.map { "\(count) · \($0)" } ?? count)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(names.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isWireGuard {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                Image(systemName: isWireGuard ? "lock.shield" : "network")
                    .foregroundStyle((isWireGuard ? Color.green : Color.teal).gradient)
                Text(network.name).fontWeight(.medium)
                if network.isInternal {
                    SourceChip(text: String(localized: "wewnętrzna"), tint: .gray)
                }
                NetworkBadge(network: network)
                Spacer()
                if let interface = network.wireGuard, interface.source == .dump {
                    peerSummary(interface)
                }
                if network.kind == .docker, !network.attached.isEmpty {
                    Text("Kontenery: \(network.attached.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isWireGuard { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } }
            }
            if let line = addressingLine {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let wireGuard = network.wireGuard {
                WireGuardDetails(interface: wireGuard, expanded: expanded, knownHosts: knownHosts)
            } else if !network.attached.isEmpty {
                Text(network.attached.map { attachment in
                    attachment.ipv4Address.map { "\(attachment.name) (\($0))" } ?? attachment.name
                }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    /// `bridge · local · 172.17.0.0/16 → 172.17.0.1`
    private var addressingLine: String? {
        var parts: [String] = []
        if network.kind != .wireguard {
            if let driver = network.driver { parts.append(driver) }
            if let scope = network.scope { parts.append(scope) }
        }
        if let subnet = network.ipv4Subnet {
            parts.append(network.ipv4Gateway.map { "\(subnet) → \($0)" } ?? subnet)
        }
        if let v6 = network.ipv6Subnet { parts.append(v6) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Port, address, public key and notes of a WireGuard interface, and — when the
/// row is expanded — its peers. No private or preshared key is ever available
/// here: the model has no field for one.
struct WireGuardDetails: View {
    let interface: WireGuardInterface
    var expanded = false
    var knownHosts: [WireGuardKnownHost] = []
    private var labelStore = WireGuardPeerLabelStore.shared
    @State private var editing: WireGuardPeerLabelTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                if let port = interface.listenPort {
                    Text("Port nasłuchu: \(port)")
                }
                if !interface.addresses.isEmpty {
                    Text(String(format: String(localized: "Adres: %@"), interface.addresses.joined(separator: ", ")))
                }
                if let key = interface.publicKey {
                    Text(String(format: String(localized: "Klucz publiczny: %@"), WireGuardFormat.shortKey(key)))
                        .help(key)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            if interface.wgMissing {
                note(String(localized: "Brak polecenia wg na tej maszynie — pokazano tylko adres interfejsu."))
            } else if interface.peerDetailsNeedRoot {
                note(String(localized: "Szczegóły peerów wymagają roota"))
            } else if interface.inferred {
                note(String(localized: "Interfejs rozpoznany po adresie i MTU."))
            }

            if interface.source == .dump, expanded {
                let rows = WireGuardPeerPresenter.rows(
                    for: interface, aliases: labelStore.names, notes: labelStore.notes,
                    deviceTypes: labelStore.deviceTypes, knownHosts: knownHosts
                )
                if rows.isEmpty {
                    Text("Brak peerów").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            PeerRow(row: row) {
                                editing = WireGuardPeerLabelTarget(peer: row.peer, autoName: row.autoName)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 18)
                }
            }
        }
        .sheet(item: $editing) { target in WireGuardPeerLabelSheet(target: target) }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

struct PeerRow: View {
    let row: WireGuardPeerRow
    let onEdit: () -> Void

    private var peer: WireGuardPeer { row.peer }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.isStale ? Color.secondary : Color.green)
                    .frame(width: 7, height: 7)
                if let type = row.deviceType {
                    Image(systemName: type.symbol)
                        .font(.caption)
                        .foregroundStyle(row.deviceTypeIsUserChosen ? Color.accentColor : Color.secondary)
                        .help(row.deviceTypeIsUserChosen ? type.title : String(format: String(localized: "Auto: %@"), type.title))
                        .accessibilityLabel(Text(type.title))
                }
                if let name = row.name {
                    Text(name).font(.callout.weight(.semibold))
                        .help(nameTooltip)
                    if row.nameSource == .alias {
                        Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(WireGuardFormat.shortKey(peer.publicKey))
                    .font(.caption.monospaced())
                    .help(peer.publicKey)
                IconButton(symbol: "doc.on.doc", description: String(localized: "Kopiuj klucz publiczny")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(peer.publicKey, forType: .string)
                }
                PeerLabelEditButton(action: onEdit)
            }
            if let note = row.note {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Group {
                Text(String(format: String(localized: "Dozwolone IP: %@"), peer.allowedIPs.isEmpty ? "—" : peer.allowedIPs.joined(separator: ", ")))
                Text("Endpoint: \(peer.endpoint ?? "—")")
                Text(String(format: String(localized: "Ostatni handshake: %@"), WireGuardFormat.handshake(peer.latestHandshake)))
                Text(String(format: String(localized: "Transfer: ↓ %@ ↑ %@"), WireGuardFormat.bytes(peer.rxBytes), WireGuardFormat.bytes(peer.txBytes)))
                if let keepalive = peer.keepalive {
                    Text(String(format: String(localized: "Keepalive: co %lld s"), Int64(keepalive)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .opacity(row.isStale ? 0.55 : 1)
        .help(row.isStale ? String(localized: "Brak świeżego handshake (ponad 3 min)") : "")
    }

    /// The label, what the peer would be called without it, the note and the key.
    private var nameTooltip: String {
        var lines: [String] = []
        if let name = row.name { lines.append(name) }
        if row.nameSource == .alias, let auto = row.autoName {
            lines.append(String(format: String(localized: "Bez etykiety: %@"), auto))
        }
        if let note = row.note { lines.append(note) }
        lines.append(peer.publicKey)
        return lines.joined(separator: "\n")
    }
}

struct NetworkCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subnet = ""
    @State private var internalOnly = false
    @State private var isWorking = false
    @State private var engine: RuntimeKind = .apple

    /// Engines on this Mac that can create a network.
    private var engines: [RuntimeKind] {
        var list: [RuntimeKind] = []
        if model.system.serviceState.isRunning { list.append(.apple) }
        if model.containers.installedRuntimes.contains(.docker) { list.append(.docker) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(Color.teal.gradient)
                    .font(.title3)
                Text("Nowa sieć")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    if engines.count > 1 {
                        Picker("Silnik", selection: $engine) {
                            ForEach(engines) { Text($0.badge).tag($0) }
                        }
                    }
                    TextField("Nazwa", text: $name)
                    TextField("Podsieć (np. 10.0.0.0/24 — opcjonalnie)", text: $subnet)
                    Toggle("Tylko sieć hosta (internal)", isOn: $internalOnly)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .foregroundStyle(Color.teal.gradient)
                        Text("Sieć")
                        InfoTip(text: String(localized: "Osobna sieć izoluje grupę kontenerów. Kontenery w tej samej sieci widzą się nawzajem po nazwie (lokalny DNS)."))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            // Footer
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Utwórz") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(name.isEmpty || isWorking || engines.isEmpty)
            }
            .padding(12)
        }
        .frame(width: SheetWidth.narrow)
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let target = engines.contains(engine) ? engine : (engines.first ?? .apple)
            try await model.networks.create(name: name, subnet: subnet, internalOnly: internalOnly, on: target)
            dismiss()
        } catch {
            model.present(error)
        }
    }
}
