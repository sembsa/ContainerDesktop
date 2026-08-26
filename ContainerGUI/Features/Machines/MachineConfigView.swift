import SwiftUI

/// The `machine set` knobs, as a form.
///
/// Only edited fields are sent. Sending every value would be worse than verbose:
/// `machine set` writes what it is given, so re-submitting an unchanged CPU count
/// pins it against whatever the CLI's own default would have become.
///
/// Two subtleties decide how "edited" is worked out, and neither is cosmetic:
///
/// - Fields the CLI *reports* (cpus, memory, home-mount) are compared against
///   what it reported. The baseline therefore has to be reloaded when `inspect`
///   arrives — it lands a moment after the view appears. Loading a `rw` baseline
///   for an `ro` machine and then comparing against it would show a change nobody
///   made, and saving it would quietly remount the home directory read-write.
/// - Fields the CLI does *not* report (virtualization, kernel) have no baseline to
///   compare against, so they are tracked by whether the user touched them at all:
///   `nil` means untouched and unsent. That is what lets the form send
///   `virtualization=false` and the empty `kernel=` that resets to the system
///   kernel — a value comparison could express neither.
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
    /// nil until the user touches it — see the note above.
    @State private var virtualization: Bool?
    @State private var kernelPath: String?
    @State private var isApplying = false
    @State private var reply: String?

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
                    Toggle("Wirtualizacja zagnieżdżona", isOn: virtualizationBinding)
                    Text("Wymaga Apple Silicon M3 lub nowszego, macOS 15+ oraz jądra z CONFIG_KVM=y.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Własne jądro", text: kernelBinding, prompt: Text(verbatim: "/ścieżka/do/vmlinux"))
                    Text("Wirtualizacja i jądro nie są raportowane przez CLI, więc trafiają do zapisu tylko wtedy, gdy je tu zmienisz. Wyczyszczenie pola jądra przywraca jądro systemowe.")
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
        // Keyed on everything the baseline is drawn from, so the form reloads when
        // `inspect` lands and again after a save refreshes the row.
        .task(id: baselineKey) { loadCurrentValues() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if machine.isRunning {
                Label("Zmiany zadziałają po zatrzymaniu i ponownym uruchomieniu maszyny", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Przywróć") { loadCurrentValues() }
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

    // MARK: - Bindings for the untouched-until-edited fields

    private var virtualizationBinding: Binding<Bool> {
        Binding(get: { virtualization ?? false }, set: { virtualization = $0 })
    }

    private var kernelBinding: Binding<String> {
        Binding(get: { kernelPath ?? "" }, set: { kernelPath = $0 })
    }

    // MARK: - Change tracking

    private var baselineKey: String {
        "\(machine.id)|\(currentCpus)|\(currentMemory)|\(inspect?.homeMount ?? "?")"
    }

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
        // Only trust the home-mount comparison once the CLI has told us what it is.
        if inspect != nil, homeMount != currentHomeMount { settings.append(.homeMount(homeMount)) }
        if let virtualization { settings.append(.virtualization(virtualization)) }
        if let kernelPath { settings.append(.kernel(kernelPath)) }
        return settings
    }

    private func loadCurrentValues() {
        cpus = currentCpus
        memory = currentMemory
        homeMount = currentHomeMount
        virtualization = nil
        kernelPath = nil
        reply = nil
    }

    private func apply() async {
        let settings = changedSettings
        guard !settings.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            let output = try await model.machines.apply(settings, to: machine)
            // Cleared after the reload the refreshed row triggers, so it survives
            // long enough to read.
            loadCurrentValues()
            reply = output
        } catch {
            model.present(error)
        }
    }
}
