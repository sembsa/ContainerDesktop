import SwiftUI

/// "Ustawienia maszyny": what the machine is called and what it is given.
/// Hardware changes reach QEMU only when it starts, so they wait for the next boot.
struct VMSettingsSheet: View {
    let vm: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var cpus: Int
    @State private var memoryMiB: Int
    @State private var resolution: String
    @State private var agentControl: Bool

    init(vm: VirtualMachine) {
        self.vm = vm
        _name = State(initialValue: vm.name)
        _cpus = State(initialValue: vm.cpus)
        _memoryMiB = State(initialValue: vm.memoryMiB)
        _resolution = State(initialValue: vm.resolution)
        _agentControl = State(initialValue: vm.agentControl)
    }

    private var store: VirtualMachineStore { model.virtualMachines }
    private var maxCPUs: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// The usual sizes, plus whatever the machine has now so the picker never shows blank.
    private var memoryOptions: [Int] {
        Array(Set([4096, 8192, 16384, 32768, vm.memoryMiB])).sorted()
    }

    private var hardwareChanged: Bool {
        cpus != vm.cpus || memoryMiB != vm.memoryMiB || resolution != vm.resolution
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VMIcon(vm: vm, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ustawienia maszyny").font(.headline)
                    Text(vm.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], Padding.card)
            Form {
                Section {
                    TextField("Nazwa", text: $name)
                }
                Section {
                    Stepper("Procesory: \(cpus)", value: $cpus, in: 1...max(maxCPUs, vm.cpus))
                    Picker("Pamięć", selection: $memoryMiB) {
                        ForEach(memoryOptions, id: \.self) { mib in
                            Text(ByteCountFormatter.string(fromByteCount: Int64(mib) * 1_048_576, countStyle: .memory))
                                .tag(mib)
                        }
                    }
                    Picker("Rozdzielczość", selection: $resolution) {
                        ForEach(VirtualMachine.resolutions, id: \.self) { value in
                            Text(VirtualMachine.resolutionTitle(value)).tag(value)
                        }
                    }
                    .disabled(vm.display != .virtioGPU)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.isRunning
                             ? String(localized: "Maszyna działa — procesory, pamięć i rozdzielczość zmienią się po jej ponownym uruchomieniu.")
                             : String(localized: "Procesory, pamięć i rozdzielczość zmienią się przy następnym uruchomieniu."))
                        if vm.display != .virtioGPU {
                            Text("Rozdzielczość można zmienić po zakończeniu instalacji systemu.")
                        }
                    }
                }
                Section {
                    Toggle("Pozwól agentowi AI sterować tą maszyną", isOn: $agentControl)
                } footer: {
                    Text("Narzędzia vm_* serwera MCP mogą wtedy widzieć ekran tej maszyny, klikać, pisać, uruchamiać w niej polecenia, kopiować pliki i przywracać migawki. Bez tej zgody odmawiają.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Group {
                    if vm.isRunning && hardwareChanged {
                        Button("Zapisz") { save(restart: false) }
                            .buttonStyle(.glass)
                        Button("Zapisz i uruchom ponownie") { save(restart: true) }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.glassProminent)
                    } else {
                        Button("Zapisz") { save(restart: false) }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.glassProminent)
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Padding.card)
        }
        .frame(width: SheetWidth.narrow)
    }

    private func save(restart: Bool) {
        let (name, cpus, memoryMiB, resolution, agentControl) =
            (name.trimmingCharacters(in: .whitespaces), cpus, memoryMiB, resolution, agentControl)
        dismiss()
        Task {
            do {
                try await store.run(vm) {
                    try VirtualMachineStore.update(vm.directory) {
                        $0.name = name
                        $0.cpus = cpus
                        $0.memoryMiB = memoryMiB
                        $0.resolution = resolution
                        $0.agentControl = agentControl
                    }
                    guard restart else { return }
                    try await VMEngine.stop(vm)
                    guard await VMEngine.waitUntilStopped(vm.directory, timeout: .seconds(180)) else {
                        throw VMEngine.Failure.mustBeStopped
                    }
                    // `vm` still has the old hardware; start from what was just saved.
                    try await VMEngine.start(VirtualMachineStore.load(vm.directory) ?? vm)
                }
            } catch {
                model.present(error)
            }
        }
    }
}
