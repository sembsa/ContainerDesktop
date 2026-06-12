import AppKit
import SwiftUI

struct RunContainerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var config: RunConfiguration
    @State private var isRunning = false
    @State private var showAdvanced = false
    @State private var errorText: String?
    @State private var output: [LogLine] = []
    @State private var runTask: Task<Void, Never>?
    @State private var replaceExisting = true

    private let replacesContainerID: String?

    init(presetImage: String? = nil) {
        var initial = RunConfiguration()
        if let presetImage { initial.image = presetImage }
        _config = State(initialValue: initial)
        replacesContainerID = nil
    }

    init(recreating container: ContainerInfo) {
        let cfg = container.configuration
        var initial = RunConfiguration()

        // Image
        initial.image = cfg.image.reference

        // Name — prefill with container ID (same name by default)
        initial.name = container.id

        // Command — reconstruct from initProcess
        if let proc = cfg.initProcess {
            let exe = proc.executable ?? ""
            let cmdArgs = (proc.arguments ?? [])
            let all: [String]
            if exe.isEmpty {
                all = cmdArgs
            } else {
                all = [exe] + cmdArgs
            }
            initial.command = RunCommandBuilder.joinCommand(all)
        }

        // Environment — skip PATH entries
        if let envList = cfg.initProcess?.environment {
            initial.environment = envList.compactMap { entry -> RunConfiguration.KeyValue? in
                guard !entry.hasPrefix("PATH=") else { return nil }
                if let eqIdx = entry.firstIndex(of: "=") {
                    let key = String(entry[entry.startIndex..<eqIdx])
                    let value = String(entry[entry.index(after: eqIdx)...])
                    return RunConfiguration.KeyValue(key: key, value: value)
                }
                return RunConfiguration.KeyValue(key: entry, value: "")
            }
        }

        // Ports
        if let ports = cfg.publishedPorts {
            initial.ports = ports.compactMap { p -> RunConfiguration.PortMapping? in
                guard let hp = p.hostPort, let cp = p.containerPort else { return nil }
                return RunConfiguration.PortMapping(
                    host: String(hp),
                    container: String(cp),
                    proto: p.proto ?? "tcp"
                )
            }
        }

        // Volumes
        if let mounts = cfg.mounts {
            initial.volumes = mounts.compactMap { mount -> RunConfiguration.VolumeMount? in
                guard let src = mount.preferredSource, let dst = mount.destination else { return nil }
                return RunConfiguration.VolumeMount(source: src, destination: dst)
            }
        }

        // CPUs
        if let cpus = cfg.resources?.cpus {
            initial.cpus = String(cpus)
        }

        // Memory — format as M or G
        if let bytes = cfg.resources?.memoryInBytes {
            let mb = bytes / (1024 * 1024)
            if mb > 0 {
                let gb = mb / 1024
                if mb % 1024 == 0 && gb > 0 {
                    initial.memory = "\(gb)G"
                } else {
                    initial.memory = "\(mb)M"
                }
            }
        }

        // Rosetta
        initial.rosetta = cfg.rosetta ?? false

        // Working directory (skip "/" — it's the default)
        if let wd = cfg.initProcess?.workingDirectory, wd != "/" {
            initial.workdir = wd
        }

        _config = State(initialValue: initial)
        replacesContainerID = container.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 640, height: 700)
    }

    private var header: some View {
        HStack {
            Image(systemName: "shippingbox")
            Text(replacesContainerID != nil ? "Uruchom z nową konfiguracją" : "Uruchom kontener")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private var form: some View {
        Form {
            Section {
                HStack {
                    TextField("Obraz (np. alpine:latest)", text: $config.image)
                    if !model.images.items.isEmpty {
                        Menu {
                            ForEach(model.images.items) { image in
                                Button(image.reference) { config.image = image.reference }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 28)
                    }
                }
                TextField("Nazwa (opcjonalnie)", text: $config.name)
                TextField("Polecenie (opcjonalnie, np. sleep 600)", text: $config.command)

                if let replacesID = replacesContainerID {
                    HStack(spacing: 4) {
                        Toggle("Zastąp istniejący kontener (najpierw usunie obecny)", isOn: $replaceExisting)
                        InfoTip(text: String(localized: "CLI nie pozwala zmienić polecenia działającego kontenera. Aplikacja utworzy nowy kontener z tą samą konfiguracją — przy włączonym zastępowaniu stary zostanie usunięty, a nazwa zachowana. Dane w wolumenach przetrwają; dane zapisane poza wolumenami przepadną."))
                    }
                    .onChange(of: replaceExisting) { _, newValue in
                        // When user disables replace, remind them the name may conflict
                        let collisionMessage = String(localized: "Zmień nazwę albo włącz zastępowanie — kontener o tej nazwie już istnieje.")
                        if !newValue && config.name == replacesID {
                            errorText = collisionMessage
                        } else {
                            if errorText == collisionMessage { errorText = nil }
                        }
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(Color.blue.gradient)
                    Text("Podstawowe")
                }
            }

            keyValueSection(
                title: String(localized: "Porty (host → kontener)"),
                icon: "network",
                tint: .teal,
                tip: String(localized: "Przekierowanie portu: localhost:port-hosta prowadzi do portu wewnątrz kontenera. Np. 8080:80 — strona z kontenera będzie pod http://localhost:8080."),
                items: $config.ports,
                add: { config.ports.append(.init()) }
            ) { $port in
                TextField("host", text: $port.host, prompt: Text("host"))
                    .labelsHidden()
                    .frame(width: 80)
                Text(":")
                TextField("kontener", text: $port.container, prompt: Text("kontener"))
                    .labelsHidden()
                    .frame(width: 80)
                Picker("proto", selection: $port.proto) {
                    Text("tcp").tag("tcp")
                    Text("udp").tag("udp")
                }
                .labelsHidden()
                .frame(width: 80)
                Spacer()
            }

            keyValueSection(
                title: String(localized: "Zmienne środowiskowe"),
                icon: "curlybraces",
                tint: .green,
                tip: String(localized: "Zmienne przekazywane do procesu w kontenerze, np. hasła czy konfiguracja. Format KLUCZ=wartość."),
                items: $config.environment,
                add: { config.environment.append(.init()) }
            ) { $variable in
                TextField("KLUCZ", text: $variable.key, prompt: Text("KLUCZ"))
                    .labelsHidden()
                    .frame(minWidth: 120, maxWidth: 200)
                Text("=")
                TextField("wartość", text: $variable.value, prompt: Text("wartość"))
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }

            keyValueSection(
                title: String(localized: "Wolumeny (źródło → cel)"),
                icon: "externaldrive.fill",
                tint: .orange,
                tip: String(localized: "Trwały zapis danych: nazwa wolumenu (utworzonego w zakładce Wolumeny) albo ścieżka lokalna, montowana pod wskazaną ścieżką w kontenerze. Dane przetrwają usunięcie kontenera."),
                items: $config.volumes,
                add: { config.volumes.append(.init()) }
            ) { $mount in
                TextField("źródło / nazwa", text: $mount.source, prompt: Text("źródło / nazwa"))
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                Menu {
                    if !model.volumes.items.isEmpty {
                        Section(String(localized: "Wolumeny")) {
                            ForEach(model.volumes.items) { volume in
                                Button(volume.name) { $mount.wrappedValue.source = volume.name }
                            }
                        }
                    }
                    Button(String(localized: "Wybierz folder z dysku…"), systemImage: "folder") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = String(localized: "Wybierz folder do zamontowania w kontenerze")
                        if panel.runModal() == .OK, let url = panel.url {
                            $mount.wrappedValue.source = url.path
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                Text("→")
                TextField("ścieżka w kontenerze", text: $mount.destination, prompt: Text("ścieżka w kontenerze"))
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                Toggle("ro", isOn: $mount.readOnly).toggleStyle(.checkbox)
            }

            Section {
                TextField("CPU (np. 2)", text: $config.cpus)
                TextField("Pamięć (np. 512M, 2G)", text: $config.memory)
                Picker("Sieć", selection: $config.network) {
                    Text("domyślna").tag("")
                    ForEach(model.networks.items) { network in
                        Text(network.name).tag(network.name)
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "memorychip")
                        .foregroundStyle(Color.purple.gradient)
                    Text("Zasoby")
                    InfoTip(text: String(localized: "Limit zasobów maszyny wirtualnej kontenera. CPU: liczba rdzeni (np. 2). Pamięć: liczba z jednostką, np. 512M lub 2G."))
                }
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack(spacing: 4) {
                    Picker("Architektura", selection: $config.arch) {
                        Text("arm64 (natywna)").tag("")
                        Text("amd64 (Intel)").tag("amd64")
                    }
                    InfoTip(text: String(localized: "Obrazy zbudowane dla Intel (amd64) wymagają wybrania tej architektury. Włączona Rosetta znacząco przyspiesza ich działanie na Apple Silicon."))
                }
                .padding(.vertical, 4)
                .frame(minHeight: 30)
                .onChange(of: config.arch) { _, newArch in
                    if newArch == "amd64" {
                        config.rosetta = true
                    }
                }
                TextField("Katalog roboczy", text: $config.workdir)
                TextField("Użytkownik", text: $config.user)
                TextField("Entrypoint", text: $config.entrypoint)
                HStack(spacing: 4) {
                    Toggle("Włącz Rosetta", isOn: $config.rosetta)
                    InfoTip(text: String(localized: "Pozwala uruchamiać obrazy x86_64 (Intel) na Apple Silicon przez tłumaczenie Rosetta. Wolniejsze niż natywne arm64."))
                }
                HStack(spacing: 4) {
                    Toggle("Usuń po zatrzymaniu (--rm)", isOn: $config.removeOnExit)
                    InfoTip(text: String(localized: "Kontener zniknie automatycznie po zatrzymaniu — przydatne do jednorazowych zadań. Logi i dane (poza wolumenami) przepadną."))
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(Color.gray.gradient)
                    Text("Zaawansowane")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color.blue.gradient)
                    .font(.caption)
                Text("Podgląd polecenia")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.vertical) {
                Text(RunCommandBuilder.previewLines(for: config).joined(separator: " \\\n    "))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
            if isRunning && !output.isEmpty {
                StreamLogBox(lines: output)
                    .frame(height: 90)
                Text("Pobieranie obrazu może chwilę potrwać…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anuluj") {
                    if isRunning {
                        runTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    runTask = Task { await run() }
                } label: {
                    if isRunning { ProgressView().controlSize(.small) } else { Text("Uruchom") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(config.image.isEmpty || isRunning)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func keyValueSection<Item: Identifiable, Row: View>(
        title: String,
        icon: String? = nil,
        tint: Color = .secondary,
        tip: String? = nil,
        items: Binding<[Item]>,
        add: @escaping () -> Void,
        @ViewBuilder row: @escaping (Binding<Item>) -> Row
    ) -> some View {
        Section {
            // Iterate over values and rebuild ID-based bindings: SwiftUI's
            // binding-ForEach hands out index-based bindings, and a focused
            // TextField writing through one after its row is deleted crashes
            // with "Index out of range".
            ForEach(items.wrappedValue) { item in
                HStack {
                    row(Self.safeBinding(for: item, in: items))
                    Button(role: .destructive) {
                        items.wrappedValue.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Dodaj", systemImage: "plus", action: add)
                .buttonStyle(.borderless)
        } header: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(tint.gradient)
                }
                Text(title)
                if let tip {
                    InfoTip(text: tip)
                }
            }
        }
    }

    /// A binding that looks the element up by ID on every access; reads fall
    /// back to the captured snapshot and writes are dropped once the element
    /// is gone, so stale bindings of deleted rows are harmless.
    private static func safeBinding<Item: Identifiable>(
        for snapshot: Item,
        in items: Binding<[Item]>
    ) -> Binding<Item> {
        Binding(
            get: { items.wrappedValue.first { $0.id == snapshot.id } ?? snapshot },
            set: { newValue in
                guard let index = items.wrappedValue.firstIndex(where: { $0.id == snapshot.id }) else { return }
                items.wrappedValue[index] = newValue
            }
        )
    }

    private func run() async {
        // Validate name collision when not replacing
        if let replacesID = replacesContainerID, !replaceExisting {
            if config.name == replacesID {
                errorText = String(localized: "Zmień nazwę albo włącz zastępowanie — kontener o tej nazwie już istnieje.")
                return
            }
        }

        isRunning = true
        errorText = nil
        output = []
        defer { isRunning = false }

        do {
            // Remove existing container first if requested
            if let replacesID = replacesContainerID, replaceExisting {
                try await ContainerCLI.shared.run(["rm", "--force", replacesID])
            }

            let args = RunCommandBuilder.arguments(for: config, progress: "plain")
            for try await line in ContainerCLI.shared.streamChecked(args) {
                output.append(LogLine(text: line))
            }
            if Task.isCancelled { return }
            await model.containers.refresh()
            dismiss()
        } catch {
            if Task.isCancelled { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
