import AppKit
import SwiftUI

/// Full virtual machines run by QEMU: the list, one machine in detail, and the
/// way into its screen.
struct VirtualMachinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: VirtualMachine.ID?
    @State private var cloneSource: VirtualMachine?
    @State private var cloneName = ""

    private var store: VirtualMachineStore { model.virtualMachines }

    private var selected: VirtualMachine? {
        store.items.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                VirtualMachinesEmptyState()
            } else {
                GeometryReader { geo in
                    VSplitView {
                        table
                            .frame(minHeight: 120,
                                   maxHeight: selected == nil ? .infinity : max(geo.size.height * 0.32, 120))
                        if let selected {
                            VirtualMachineDetailView(vm: selected, onClone: beginClone)
                                .frame(minHeight: 340, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .navigationTitle("Wirtualne maszyny")
        .task {
            store.refresh()
            if selection == nil { selection = store.items.first?.id }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.refresh() } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .itemAlert("Sklonuj maszynę", item: $cloneSource) { vm in
            TextField("Nazwa", text: $cloneName)
            Button("Sklonuj") {
                let name = cloneName.trimmingCharacters(in: .whitespaces)
                Task {
                    await perform(vm) { try await VMEngine.clone(vm, named: name.isEmpty ? vm.name : name) }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { vm in
            Text(String(format: String(localized: "Klon dostaje cienki dysk nałożony na dysk maszyny „%@” — powstaje w sekundę i zajmuje tylko to, co zmieni. Oryginał staje się jego bazą i nie da się go już uruchomić."), vm.name))
        }
    }

    private var table: some View {
        Table(store.items, selection: $selection) {
            TableColumn("Nazwa") { vm in
                HStack(spacing: 8) {
                    Image(systemName: vm.isWindows ? "pc" : "desktopcomputer")
                        .foregroundStyle(AppModel.Section.virtualMachines.tint.gradient)
                    Text(vm.name).fontWeight(.medium)
                    if vm.backingMachine != nil {
                        Text("klon")
                            .font(.caption2)
                            .fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                    if store.busy.contains(vm.id) { ProgressView().controlSize(.small) }
                }
            }
            .width(min: 200)
            TableColumn("System") { Text($0.isWindows ? "Windows" : "Linux").foregroundStyle(.secondary) }
            TableColumn("Stan") { vm in
                HStack(spacing: 5) {
                    StatusDot(state: vm.isRunning ? "running" : "stopped")
                    Text(vm.isRunning ? String(localized: "Działa") : String(localized: "Zatrzymana"))
                        .foregroundStyle(vm.isRunning ? Color.green : Color.secondary)
                }
            }
            TableColumn("CPU") { Text("\($0.cpus)").foregroundStyle(.secondary) }
            TableColumn("Pamięć") { Text($0.memoryText).foregroundStyle(.secondary) }
            TableColumn("VNC") { vm in
                Text(vm.isRunning ? "127.0.0.1:\(vm.vncPort)" as String : "—")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: VirtualMachine.ID.self) { ids in
            if let id = ids.first, let vm = store.items.first(where: { $0.id == id }) {
                if vm.isRunning {
                    Button("Podgląd") { openWindow(id: VMPreviewWindow.windowID, value: vm.id) }
                    Button("Zatrzymaj") { Task { await perform(vm) { try await VMEngine.stop(vm) } } }
                } else {
                    Button("Uruchom") { Task { await perform(vm) { try await VMEngine.start(vm) } } }
                }
                Divider()
                Button("Sklonuj…") { beginClone(vm) }
                    .disabled(vm.isRunning)
                Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([vm.directory]) }
            }
        }
    }

    private func beginClone(_ vm: VirtualMachine) {
        cloneName = String(format: String(localized: "%@ (klon)"), vm.name)
        cloneSource = vm
    }

    private func perform(_ vm: VirtualMachine, _ action: () async throws -> Void) async {
        do { try await store.run(vm, action) }
        catch { model.present(error) }
    }
}

// MARK: - Empty state

/// What the section is for, before there is anything in it.
struct VirtualMachinesEmptyState: View {
    private let tint = AppModel.Section.virtualMachines.tint
    private var qemuInstalled: Bool { FileManager.default.isExecutableFile(atPath: QEMULauncher.qemu) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "pc")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: Radius.panel))
                    .shadow(color: tint.opacity(0.35), radius: 12, y: 4)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Wirtualne maszyny").font(.title2.weight(.semibold))
                        Text("Nowość")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tint.opacity(0.2), in: Capsule())
                            .foregroundStyle(tint)
                    }
                    Text("Windows i Linux w pełnej maszynie wirtualnej, którą możesz oddać agentowi AI.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(alignment: .top, spacing: 12) {
                    feature("macwindow.and.cursorarrow", "Pełny system",
                            "Prawdziwy Windows 11 na ARM, z własnym pulpitem, siecią i dyskiem.")
                    feature("play.display", "Podgląd na żywo",
                            "Ekran maszyny w oknie aplikacji — z myszą i klawiaturą.")
                    feature("clock.arrow.circlepath", "Migawki",
                            "Zapisz stan przed eksperymentem i wróć do niego jednym kliknięciem.")
                }
                .frame(maxWidth: 640)

                VStack(spacing: 8) {
                    Button("Utwórz maszynę Windows…", systemImage: "plus") {}
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(true)
                    Text(qemuInstalled
                         ? String(localized: "Kreator instalacji pojawi się w jednej z najbliższych wersji.")
                         : String(localized: "Wymaga QEMU — zainstaluj je poleceniem brew install qemu."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint.gradient)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Padding.card)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

// MARK: - Detail

/// One machine: power, its screen, what it is made of, and its snapshots.
struct VirtualMachineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    let vm: VirtualMachine
    let onClone: (VirtualMachine) -> Void

    @State private var snapshots: [VMSnapshot] = []
    @State private var snapshotsError: String?
    @State private var isLoadingSnapshots = false
    @State private var newSnapshotName: String?
    @State private var pendingRestore: VMSnapshot?
    @State private var pendingDelete: VMSnapshot?
    @State private var confirmForceStop = false

    private var store: VirtualMachineStore { model.virtualMachines }
    private var isBusy: Bool { store.busy.contains(vm.id) }
    private let tint = AppModel.Section.virtualMachines.tint

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewCard
                    snapshotsCard
                }
                .padding(Padding.card)
            }
        }
        .task(id: "\(vm.id)|\(vm.isRunning)") { await loadSnapshots() }
        .alert("Nowa migawka", isPresented: Binding(get: { newSnapshotName != nil },
                                                   set: { if !$0 { newSnapshotName = nil } })) {
            TextField("Nazwa", text: Binding(get: { newSnapshotName ?? "" }, set: { newSnapshotName = $0 }))
            Button("Utwórz") {
                let name = newSnapshotName ?? ""
                Task { await snapshotAction { try await VMEngine.createSnapshot(name, of: vm) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text(vm.isRunning
                 ? String(localized: "Maszyna działa, więc migawka zapisze też jej pamięć — na kilka sekund zatrzyma się w miejscu.")
                 : String(localized: "Migawka zapisze stan dysku."))
        }
        .itemConfirmationDialog(Text("Przywrócić migawkę?"), item: $pendingRestore) { snapshot in
            Button("Przywróć", role: .destructive) {
                Task { await snapshotAction { try await VMEngine.restoreSnapshot(snapshot.tag, of: vm) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { snapshot in
            Text(String(format: String(localized: "Maszyna wróci do stanu z migawki „%@”. Wszystko, co zmieniło się od tamtej pory, przepadnie. Działająca maszyna zostanie na chwilę wyłączona i uruchomiona ponownie."), snapshot.tag))
        }
        .itemConfirmationDialog(Text("Usunąć migawkę?"), item: $pendingDelete) { snapshot in
            Button("Usuń", role: .destructive) {
                Task { await snapshotAction { try await VMEngine.deleteSnapshot(snapshot.tag, of: vm) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { snapshot in
            Text(String(format: String(localized: "Migawka „%@” zostanie usunięta."), snapshot.tag))
        }
        .confirmationDialog("Wymusić zatrzymanie?", isPresented: $confirmForceStop) {
            Button("Wymuś zatrzymanie", role: .destructive) {
                Task { await perform { try await VMEngine.forceStop(vm) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("To jak wyciągnięcie wtyczki: niezapisane dane w maszynie przepadną.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.isWindows ? "pc" : "desktopcomputer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: Radius.card))
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name).font(.headline)
                Text(vm.isRunning ? String(localized: "Maszyna działa") : String(localized: "Maszyna zatrzymana"))
                    .font(.caption)
                    .foregroundStyle(vm.isRunning ? Color.green : .secondary)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            if vm.isRunning {
                Button("Podgląd", systemImage: "play.display") {
                    openWindow(id: VMPreviewWindow.windowID, value: vm.id)
                }
                .buttonStyle(.glassProminent)
                Button("Zatrzymaj", systemImage: "power") {
                    Task {
                        await perform {
                            try await VMEngine.stop(vm)
                            _ = await VMEngine.waitUntilStopped(vm.directory, timeout: .seconds(180))
                        }
                    }
                }
                .buttonStyle(.glass)
                .disabled(isBusy)
                Button { confirmForceStop = true } label: { Image(systemName: "xmark.octagon") }
                    .buttonStyle(.glass)
                    .iconHelp(String(localized: "Wymuś zatrzymanie"))
            } else {
                Button("Uruchom", systemImage: "play.fill") {
                    Task { await perform { try await VMEngine.start(vm) } }
                }
                .buttonStyle(.glassProminent)
                .disabled(isBusy)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Overview

    private var overviewCard: some View {
        card(title: "Przegląd", symbol: "info.circle") {
            HStack(spacing: 4) {
                Toggle("Pozwól agentowi AI sterować tą maszyną", isOn: Binding(
                    get: { vm.agentControl },
                    set: { on in Task { await perform { try setAgentControl(on) } } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isBusy)
                InfoTip(text: String(localized: "Narzędzia vm_* serwera MCP mogą wtedy widzieć ekran tej maszyny, klikać, pisać, uruchamiać w niej polecenia, kopiować pliki i przywracać migawki. Bez tej zgody odmawiają."))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                infoRow(String(localized: "System"), vm.isWindows ? "Windows" : "Linux")
                infoRow(String(localized: "Procesory"), "\(vm.cpus)")
                infoRow(String(localized: "Pamięć"), vm.memoryText)
                infoRow(String(localized: "Dysk"), vm.disk)
                infoRow(String(localized: "VNC"), vm.isRunning ? "127.0.0.1:\(vm.vncPort)" : "—")
                if let base = vm.backingMachine {
                    infoRow(String(localized: "Klon maszyny"), base)
                }
                GridRow {
                    Text("Katalog").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(vm.directory.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        IconButton(symbol: "folder", description: String(localized: "Pokaż w Finderze")) {
                            NSWorkspace.shared.activateFileViewerSelecting([vm.directory])
                        }
                    }
                }
            }
        } accessory: {
            Button("Sklonuj…", systemImage: "plus.square.on.square") { onClone(vm) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(vm.isRunning || isBusy)
        }
    }

    /// Re-read first: the launcher rewrites vm.json on every start (VNC port), so `vm` may be stale.
    private func setAgentControl(_ on: Bool) throws {
        var current = VirtualMachineStore.load(vm.directory) ?? vm
        current.agentControl = on
        try current.save(to: vm.directory)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    // MARK: Snapshots

    private var snapshotsCard: some View {
        card(title: "Migawki", symbol: "clock.arrow.circlepath") {
            if let snapshotsError {
                Label(snapshotsError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if snapshots.isEmpty {
                Text(isLoadingSnapshots
                     ? String(localized: "Wczytywanie…")
                     : String(localized: "Brak migawek. Migawka zapisuje dysk — a gdy maszyna działa, także pamięć — i pozwala wrócić do tego stanu."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshots) { snapshot in
                        snapshotRow(snapshot)
                        if snapshot != snapshots.last { Divider() }
                    }
                }
            }
        } accessory: {
            Button("Utwórz migawkę", systemImage: "camera") {
                newSnapshotName = VMEngine.suggestedSnapshotTag()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    private func snapshotRow(_ snapshot: VMSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.hasMemory ? "memorychip" : "externaldrive")
                .foregroundStyle(tint.gradient)
                .frame(width: 18)
                .iconHelp(snapshot.hasMemory
                          ? String(localized: "Dysk i pamięć")
                          : String(localized: "Tylko dysk"))
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.tag).fontWeight(.medium)
                Text(snapshot.date?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.hasMemory {
                Text(snapshot.vmStateSize).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            IconButton(symbol: "arrow.counterclockwise", description: String(localized: "Przywróć migawkę")) {
                pendingRestore = snapshot
            }
            .disabled(isBusy)
            IconButton(symbol: "trash", description: String(localized: "Usuń migawkę"), tint: .red) {
                pendingDelete = snapshot
            }
            .disabled(isBusy)
        }
        .padding(.vertical, 6)
    }

    // MARK: Building blocks

    private func card<Content: View, Accessory: View>(
        title: LocalizedStringKey, symbol: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint.gradient)
                Text(title).font(.headline)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(Padding.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card))
    }

    // MARK: Actions

    private func loadSnapshots() async {
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }
        do {
            snapshots = try await VMEngine.snapshots(of: vm)
            snapshotsError = nil
        } catch {
            snapshotsError = error.localizedDescription
        }
    }

    private func snapshotAction(_ action: () async throws -> Void) async {
        await perform(action)
        await loadSnapshots()
    }

    private func perform(_ action: () async throws -> Void) async {
        do { try await store.run(vm, action) }
        catch { model.present(error) }
    }
}
