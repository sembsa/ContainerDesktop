import SwiftUI

/// The `machine set` knobs, as a form.
///
/// Only edited fields are sent. Sending every value would be worse than verbose:
/// `machine set` writes what it is given, so re-submitting an unchanged CPU count
/// pins it against whatever the CLI's own default would have become.
///
/// The honest part of this screen is the warning. `machine set` changes nothing
/// about the machine that is already running, and yet `machine ls` and
/// `machine inspect` start reporting the new numbers immediately — verified: after
/// `cpus=2` on a machine booted with 9, the table said 2 while the VM still had 9.
/// Without saying so, the UI would be quietly lying.
struct MachineConfigView: View {
    @Environment(AppModel.self) private var model

    let machine: MachineInfo
    let inspect: MachineInspect?

    @State private var cpus = ""
    @State private var memory = ""
    @State private var homeMount: MachineCommands.HomeMount = .readWrite
    @State private var nestedVirtualization = false
    @State private var kernelPath = ""
    @State private var isApplying = false
    @State private var reply: String?
    @State private var loadedFor: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Rdzenie", text: $cpus)
                        .help(String(localized: "Liczba wirtualnych procesorów."))
                    TextField("Pamięć", text: $memory)
                        .help(String(localized: "Np. 2G, 8G."))
                    Picker("Katalog domowy", selection: $homeMount) {
                        ForEach(MachineCommands.HomeMount.allCases) { mount in
                            Text(mount.title).tag(mount)
                        }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.indigo.gradient)
                        Text("Zasoby")
                    }
                }

                Section {
                    Toggle("Wirtualizacja zagnieżdżona", isOn: $nestedVirtualization)
                    Text("Wymaga Apple Silicon M3 lub nowszego, macOS 15+ oraz jądra z CONFIG_KVM=y.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Własne jądro", text: $kernelPath, prompt: Text(verbatim: "/ścieżka/do/vmlinux"))
                    Text("Puste pole przywraca jądro systemowe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .foregroundStyle(Color.orange.gradient)
                        Text("Zaawansowane")
                    }
                }

                if let reply, !reply.isEmpty {
                    Section {
                        Text(reply)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Color.green.gradient)
                            Text("Odpowiedź CLI")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isApplying)

            Divider()
            footer
        }
        .task(id: machine.id) { loadCurrentValues() }
        .onChange(of: inspect) { _, _ in loadCurrentValues() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if machine.isRunning {
                Label("Zmiany zadziałają po zatrzymaniu i ponownym uruchomieniu maszyny", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Przywróć") { loadCurrentValues(force: true) }
                .disabled(isApplying || !hasChanges)
            Button {
                Task { await apply() }
            } label: {
                if isApplying { ProgressView().controlSize(.small) } else { Text("Zapisz") }
            }
            .buttonStyle(.glassProminent)
            .disabled(isApplying || !hasChanges)
        }
        .padding(12)
    }

    // MARK: - Change tracking

    private var currentCpus: String { machine.cpus.map(String.init) ?? "" }

    /// The CLI takes `2G`; the JSON reports bytes. Rendering it back as a size
    /// keeps the field round-trippable instead of showing `2147483648`.
    private var currentMemory: String { MachineCommands.memoryArgument(forBytes: machine.memoryBytes) }

    private var currentHomeMount: MachineCommands.HomeMount {
        inspect?.homeMount.flatMap(MachineCommands.HomeMount.init(rawValue:)) ?? .readWrite
    }

    private var hasChanges: Bool { !changedSettings.isEmpty }

    private var changedSettings: [MachineCommands.Setting] {
        var settings: [MachineCommands.Setting] = []
        if cpus != currentCpus, !cpus.isEmpty { settings.append(.cpus(cpus)) }
        if memory != currentMemory, !memory.isEmpty { settings.append(.memory(memory)) }
        if homeMount != currentHomeMount { settings.append(.homeMount(homeMount)) }
        if nestedVirtualization { settings.append(.virtualization(true)) }
        // An empty kernel path is only sent when the user cleared a set one —
        // otherwise every save would reset a kernel nobody touched.
        if !kernelPath.isEmpty { settings.append(.kernel(kernelPath)) }
        return settings
    }

    private func loadCurrentValues(force: Bool = false) {
        guard force || loadedFor != machine.id else { return }
        loadedFor = machine.id
        cpus = currentCpus
        memory = currentMemory
        homeMount = currentHomeMount
        nestedVirtualization = false
        kernelPath = ""
        reply = nil
    }

    private func apply() async {
        let settings = changedSettings
        guard !settings.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            reply = try await model.machines.apply(settings, to: machine)
            loadedFor = nil
        } catch {
            model.present(error)
        }
    }
}
