import SwiftUI

/// "Utwórz maszynę Ubuntu…": the official cloud image plus cloud-init — no
/// installer, no questions, about a minute without a desktop.
struct LinuxInstallSheet: View {
    var onCreated: (VirtualMachine) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var name = "Ubuntu 24.04"
    @State private var username = LinuxInstallSheet.defaultUsername()
    @State private var password = WindowsInstallSheet.newPassword()
    @State private var desktop = true
    @State private var language = LinuxCloudInit.Language.preferred
    @State private var keyboard = LinuxCloudInit.Language.preferred == .polish ? "pl" : "us"
    @State private var cpus = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @State private var memoryGiB = 4
    @State private var diskGiB = 32

    @State private var phase: LinuxInstaller.Phase?
    @State private var created: VirtualMachine?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if let created {
                started(created)
            } else if let phase {
                progress(phase)
            } else {
                form
            }
        }
        .frame(width: SheetWidth.standard)
        .alert("Nie udało się", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    // MARK: - Form

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nazwa", text: $name)
                    Toggle("Pulpit (GNOME)", isOn: $desktop)
                } footer: {
                    Text("Ubuntu 24.04 LTS z oficjalnego obrazu chmurowego (600 MB, pobierany raz). Bez pulpitu maszyna jest gotowa po pół minuty, z pulpitem — po ok. 3 minutach.")
                }

                Section("Konto w systemie Linux") {
                    TextField("Użytkownik", text: $username)
                    LabeledContent("Hasło") {
                        HStack {
                            TextField("Hasło", text: $password).labelsHidden().monospaced()
                            Button { password = WindowsInstallSheet.newPassword() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .iconHelp(String(localized: "Wylosuj nowe hasło"))
                        }
                    }
                    Picker("Język systemu", selection: $language) {
                        Text(verbatim: "Polski").tag(LinuxCloudInit.Language.polish)
                        Text(verbatim: "English").tag(LinuxCloudInit.Language.english)
                        Text(verbatim: "中文（简体）").tag(LinuxCloudInit.Language.chinese)
                    }
                    Picker("Klawiatura", selection: $keyboard) {
                        ForEach(LinuxCloudInit.keyboards, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Zasoby") {
                    Stepper("Procesory: \(cpus)", value: $cpus, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    Picker("Pamięć", selection: $memoryGiB) {
                        ForEach([2, 4, 8, 16], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    Picker("Dysk", selection: $diskGiB) {
                        ForEach([16, 32, 64, 128], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Utwórz", action: create)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(Padding.card)
        }
    }

    /// Why the form cannot be submitted yet, or nil when it can.
    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Podaj nazwę.") }
        if !LinuxCloudInit.isValidUsername(username) {
            return String(localized: "Nazwa użytkownika: małe litery, cyfry, - i _, do 32 znaków.")
        }
        if password.isEmpty { return String(localized: "Podaj hasło.") }
        return nil
    }

    // MARK: - Progress

    private func progress(_ phase: LinuxInstaller.Phase) -> some View {
        VStack(spacing: 14) {
            switch phase {
            case .downloadingImage(let fraction):
                ProgressView(value: fraction) { Text("Pobieranie obrazu Ubuntu (600 MB, jednorazowo)…") }
            case .preparingDisk:
                ProgressView { Text("Przygotowanie dysku…") }
            case .booting, .configuring:
                ProgressView { Text("Uruchamianie maszyny…") }
            }
        }
        .padding(30)
    }

    private func started(_ vm: VirtualMachine) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Konfiguracja Ubuntu trwa").font(.title3.weight(.semibold))
            Text(desktop
                 ? LocalizedStringKey("Instalacja pulpitu potrwa ok. 3 minut. Na koniec maszyna sama się wyłączy — uruchom ją wtedy przyciskiem Uruchom. Możesz zamknąć to okno, a nawet aplikację.")
                 : LocalizedStringKey("Potrwa ok. pół minuty. Na koniec maszyna sama się wyłączy — uruchom ją wtedy przyciskiem Uruchom. Możesz zamknąć to okno, a nawet aplikację."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Podgląd", systemImage: "play.display") {
                    openWindow(id: VMPreviewWindow.windowID, value: vm.id)
                }
                .buttonStyle(.glass)
                Button("Gotowe") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
    }

    // MARK: - Actions

    private func create() {
        let request = LinuxInstaller.Request(
            name: name.trimmingCharacters(in: .whitespaces), username: username, password: password,
            cpus: cpus, memoryMiB: memoryGiB * 1024, diskGiB: diskGiB,
            desktop: desktop, language: language, keyboard: keyboard)
        phase = .preparingDisk
        Task {
            do {
                let vm = try await LinuxInstaller.create(request) { phase in
                    await MainActor.run { self.phase = phase }
                }
                created = vm
                onCreated(vm)
            } catch {
                phase = nil
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The Mac's short name if Linux would take it, else "user".
    static func defaultUsername() -> String {
        let name = String(NSUserName().lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
        return LinuxCloudInit.isValidUsername(name) ? name : "user"
    }
}
