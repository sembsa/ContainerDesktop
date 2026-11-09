import AppKit
import SwiftUI

/// Full virtual machines run by QEMU: a grid of cards, one machine in detail
/// in the inspector, and the way into its screen.
struct VirtualMachinesView: View {
    /// Opens the Linux installer. The section's owner wires it; until then the
    /// menu item stays disabled.
    var onCreateLinux: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: VirtualMachine.ID?
    @State private var cloneSource: VirtualMachine?
    @State private var cloneName = ""
    @State private var showInstall = false
    @State private var settingsFor: VirtualMachine?
    @State private var pendingDelete: PendingDelete?
    @State private var thumbnails: [VirtualMachine.ID: CGImage] = [:]

    /// The machine and its size, measured once when the dialog opens.
    struct PendingDelete: Identifiable {
        let vm: VirtualMachine
        let size: Int64
        var id: VirtualMachine.ID { vm.id }
    }

    private var store: VirtualMachineStore { model.virtualMachines }
    private var qemuInstalled: Bool { FileManager.default.isExecutableFile(atPath: QEMULauncher.qemu) }

    private var selected: VirtualMachine? {
        store.items.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                VirtualMachinesEmptyState { showInstall = true }
            } else {
                grid
            }
        }
        .navigationTitle("Wirtualne maszyny")
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selection = nil } })) {
            Group {
                if let selected {
                    VirtualMachineDetailView(vm: selected, onClone: beginClone, onSettings: { settingsFor = $0 })
                }
            }
            .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
        }
        .task {
            store.refreshFinishingInstalls()
            if selection == nil { selection = store.items.first?.id }
            // QEMU runs outside the app, so its state is polled: a machine that
            // finished installing or was shut down from inside shows up here.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                store.refreshFinishingInstalls()
            }
        }
        .task { await refreshThumbnails() }
        .sheet(isPresented: $showInstall) {
            WindowsInstallSheet { vm in
                store.refresh()
                selection = vm.id
            }
        }
        .sheet(item: $settingsFor) { VMSettingsSheet(vm: $0) }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Windows 11…", systemImage: "pc") { showInstall = true }
                    Button("Ubuntu Linux…", systemImage: "desktopcomputer") { onCreateLinux?() }
                        .disabled(onCreateLinux == nil)
                } label: {
                    Label("Utwórz maszynę…", systemImage: "plus")
                }
                .disabled(!qemuInstalled)
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
        .itemConfirmationDialog(Text("Usunąć maszynę?"), item: $pendingDelete) { pending in
            Button("Usuń maszynę", role: .destructive) {
                if selection == pending.vm.id { selection = nil }
                Task { await perform(pending.vm) { try VMEngine.delete(pending.vm) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { pending in
            Text(String(format: String(localized: "Maszyna „%@” zniknie na zawsze — razem z dyskiem i wszystkimi migawkami. Zwolni się %@."),
                        pending.vm.name,
                        ByteCountFormatter.string(fromByteCount: pending.size, countStyle: .file)))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 16)], spacing: 16) {
                ForEach(store.items) { vm in
                    VirtualMachineCard(
                        vm: vm,
                        thumbnail: thumbnails[vm.id],
                        isSelected: vm.id == selection,
                        isBusy: store.busy.contains(vm.id),
                        actions: actions(for: vm))
                    .onTapGesture { selection = vm.id }
                }
            }
            .padding(Padding.card)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
    }

    private func actions(for vm: VirtualMachine) -> VirtualMachineCard.Actions {
        .init(
            start: { Task { await perform(vm) { try await VMEngine.start(vm) } } },
            stop: {
                Task {
                    await perform(vm) {
                        try await VMEngine.stop(vm)
                        _ = await VMEngine.waitUntilStopped(vm.directory, timeout: .seconds(180))
                    }
                }
            },
            preview: { openWindow(id: VMPreviewWindow.windowID, value: vm.id) },
            settings: { settingsFor = vm },
            snapshots: { selection = vm.id },
            clone: { beginClone(vm) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([vm.directory]) },
            delete: { pendingDelete = PendingDelete(vm: vm, size: VMEngine.sizeOnDisk(vm.directory)) })
    }

    /// Reads every saved thumbnail, then keeps the running machines' fresh:
    /// one frame each over VNC every ten seconds, for as long as the section shows.
    private func refreshThumbnails() async {
        func load() {
            thumbnails = Dictionary(uniqueKeysWithValues: store.items.compactMap { vm in
                VMThumbnail.load(from: vm.directory).map { (vm.id, $0) }
            })
        }
        load()
        while !Task.isCancelled {
            for vm in store.items where vm.isRunning {
                try? await VMThumbnail.capture(port: vm.vncPort, password: vm.vncPassword, into: vm.directory)
            }
            load()
            try? await Task.sleep(for: .seconds(10))
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

// MARK: - Card

/// The machine's OS glyph on the section's tint.
struct VMIcon: View {
    let vm: VirtualMachine
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: vm.isWindows ? "pc" : "desktopcomputer")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AppModel.Section.virtualMachines.tint.gradient, in: RoundedRectangle(cornerRadius: Radius.chip))
            .accessibilityLabel(Text(verbatim: vm.isWindows ? "Windows" : "Linux"))
    }
}

/// One machine at a glance: its screen, what it is, and the few things done to it most.
struct VirtualMachineCard: View {
    struct Actions {
        var start, stop, preview, settings, snapshots, clone, reveal, delete: () -> Void
    }

    let vm: VirtualMachine
    let thumbnail: CGImage?
    let isSelected: Bool
    let isBusy: Bool
    let actions: Actions

    private let tint = AppModel.Section.virtualMachines.tint

    private var stateText: String {
        if vm.installing { return String(localized: "Instalacja trwa…") }
        return vm.isRunning ? String(localized: "Działa") : String(localized: "Zatrzymana")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            screen
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    VMIcon(vm: vm)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(vm.name).font(.headline).lineLimit(1)
                            if vm.backingMachine != nil {
                                Text("klon")
                                    .font(.caption2)
                                    .fixedSize()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                        HStack(spacing: 5) {
                            StatusDot(state: vm.isRunning ? "running" : "stopped")
                            Text(stateText)
                                .font(.caption)
                                .foregroundStyle(vm.isRunning ? Color.green : Color.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if isBusy { ProgressView().controlSize(.small) }
                }
                Text(specs)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                buttons
            }
            .padding(Padding.card)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel)
                .strokeBorder(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.separator),
                              lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.panel))
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var specs: String {
        let cpu = String(format: String(localized: "%lld CPU"), vm.cpus)
        let screen = vm.display == .virtioGPU ? VirtualMachine.resolutionTitle(vm.resolution) : "ramfb"
        return [cpu, vm.memoryText, screen].joined(separator: " · ")
    }

    private var screen: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(vm.isRunning ? 1 : 0.4)
                    .opacity(vm.isRunning ? 1 : 0.75)
            } else {
                LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: vm.isWindows ? "pc" : "desktopcomputer")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(tint.gradient)
            }
            if vm.installing {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Instalacja trwa…").font(.callout.weight(.medium))
                }
                .padding(Padding.card)
                .glassEffect(in: RoundedRectangle(cornerRadius: Radius.card))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 10, contentMode: .fit)
        .background(.black.opacity(0.85))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.panel, topTrailingRadius: Radius.panel))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if vm.isRunning {
                Button("Zatrzymaj", systemImage: "power", action: actions.stop)
                    .buttonStyle(.glass)
                    .disabled(isBusy)
            } else {
                Button("Uruchom", systemImage: "play.fill", action: actions.start)
                    .buttonStyle(.glassProminent)
                    .disabled(isBusy || vm.installing)
            }
            Button("Podgląd", systemImage: "play.display", action: actions.preview)
                .buttonStyle(.glass)
                .disabled(!vm.isRunning)
            Spacer(minLength: 0)
            Menu { menuItems } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .iconHelp(String(localized: "Więcej"))
        }
        .controlSize(.small)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Ustawienia…", systemImage: "gearshape", action: actions.settings)
            .disabled(vm.installing)
        Button("Migawki…", systemImage: "clock.arrow.circlepath", action: actions.snapshots)
        Button("Sklonuj…", systemImage: "plus.square.on.square", action: actions.clone)
            .disabled(vm.isRunning || isBusy || vm.installing)
        Button("Pokaż w Finderze", systemImage: "folder", action: actions.reveal)
        Divider()
        Button("Usuń…", systemImage: "trash", role: .destructive, action: actions.delete)
            .disabled(vm.isRunning || isBusy)
    }
}


// MARK: - Empty state

/// What the section is for, before there is anything in it.
struct VirtualMachinesEmptyState: View {
    let onCreate: () -> Void
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
                    Button("Utwórz maszynę Windows…", systemImage: "plus", action: onCreate)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!qemuInstalled)
                    if !qemuInstalled {
                        Text("Wymaga QEMU — zainstaluj je poleceniem brew install qemu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
    let onSettings: (VirtualMachine) -> Void

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
            VMIcon(vm: vm, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name).font(.headline).lineLimit(1)
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
                infoRow(String(localized: "Rozdzielczość"),
                        vm.display == .virtioGPU ? VirtualMachine.resolutionTitle(vm.resolution) : "ramfb")
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
            HStack(spacing: 6) {
                Button("Ustawienia…", systemImage: "gearshape") { onSettings(vm) }
                    .disabled(vm.installing)
                Button("Sklonuj…", systemImage: "plus.square.on.square") { onClone(vm) }
                    .disabled(vm.isRunning || isBusy)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private func setAgentControl(_ on: Bool) throws {
        try VirtualMachineStore.update(vm.directory) { $0.agentControl = on }
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
