import SwiftUI
import UniformTypeIdentifiers

/// "Utwórz maszynę Windows…": pick an ISO, name the machine, and Setup runs on
/// its own — about 20 minutes with no questions asked.
struct WindowsInstallSheet: View {
    var onCreated: (VirtualMachine) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var name = "Windows 11"
    @State private var iso: URL? = WindowsInstallSheet.likelyISO()
    @State private var username = WindowsInstallSheet.defaultUsername()
    @State private var password = WindowsInstallSheet.newPassword()
    @State private var cpus = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @State private var memoryGiB = 8
    @State private var diskGiB = 64

    @State private var phase: WindowsInstaller.Phase?
    @State private var created: VirtualMachine?
    @State private var failure: String?

    static let microsoftDownload = URL(string: "https://www.microsoft.com/software-download/windows11arm64")!

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
                    LabeledContent("Obraz ISO") {
                        HStack {
                            Text(iso?.lastPathComponent ?? String(localized: "Nie wybrano"))
                                .foregroundStyle(iso == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Wybierz…", action: chooseISO)
                        }
                    }
                    Link(destination: Self.microsoftDownload) {
                        Label("Pobierz Windows 11 ARM64 ze strony Microsoftu", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("Wybierz „Windows 11 (multi-edition ISO for Arm64)”. Instalowana jest edycja Pro, w języku obrazu.")
                }

                Section("Konto w systemie Windows") {
                    TextField("Użytkownik", text: $username)
                    LabeledContent("Hasło") {
                        HStack {
                            TextField("Hasło", text: $password).labelsHidden().monospaced()
                            Button { password = Self.newPassword() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .iconHelp(String(localized: "Wylosuj nowe hasło"))
                        }
                    }
                }

                Section {
                    Stepper("Procesory: \(cpus)", value: $cpus, in: 2...ProcessInfo.processInfo.activeProcessorCount)
                    Picker("Pamięć", selection: $memoryGiB) {
                        ForEach([4, 8, 16, 32], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    Picker("Dysk", selection: $diskGiB) {
                        ForEach([64, 128, 256], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                } header: {
                    Text("Zasoby")
                } footer: {
                    Text("Dysk rośnie w miarę zapisu — świeży Windows zajmuje ok. 20 GB.")
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Utwórz i zainstaluj", action: create)
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
        guard let iso, FileManager.default.fileExists(atPath: iso.path) else { return String(localized: "Wybierz obraz ISO.") }
        if !Self.isValidUsername(username) { return String(localized: "Nazwa użytkownika: do 20 znaków, bez \" / \\ [ ] : ; | = , + * ? < >.") }
        if password.isEmpty { return String(localized: "Podaj hasło.") }
        return nil
    }

    // MARK: - Progress

    private func progress(_ phase: WindowsInstaller.Phase) -> some View {
        VStack(spacing: 14) {
            switch phase {
            case .downloadingDrivers(let fraction):
                ProgressView(value: fraction) { Text("Pobieranie sterowników virtio-win (877 MB, jednorazowo)…") }
            case .preparingMedia:
                ProgressView { Text("Przygotowanie nośnika instalacyjnego…") }
            case .booting, .installing:
                ProgressView { Text("Uruchamianie instalatora Windows…") }
            }
        }
        .padding(30)
    }

    private func started(_ vm: VirtualMachine) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Instalacja Windows trwa").font(.title3.weight(.semibold))
            Text("Potrwa ok. 20 minut i nie wymaga żadnych kliknięć. Na koniec maszyna sama się wyłączy — uruchom ją wtedy przyciskiem Uruchom. Możesz zamknąć to okno, a nawet aplikację.")
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

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.directoryURL = iso?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK { iso = panel.url }
    }

    private func create() {
        guard let iso else { return }
        let request = WindowsInstaller.Request(
            name: name.trimmingCharacters(in: .whitespaces), windowsISO: iso,
            username: username, password: password,
            cpus: cpus, memoryMiB: memoryGiB * 1024, diskGiB: diskGiB
        )
        phase = .preparingMedia
        Task {
            do {
                let vm = try await WindowsInstaller.create(request) { phase in
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

    // MARK: - Defaults

    /// The newest ARM64 ISO in Downloads — usually the one just fetched for this.
    static func likelyISO() -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return files
            .filter { $0.pathExtension.lowercased() == "iso" && $0.lastPathComponent.lowercased().contains("arm64") }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    static func defaultUsername() -> String {
        let name = String(NSUserName().filter { $0.isLetter || $0.isNumber }.prefix(20))
        return name.isEmpty ? "agent" : name
    }

    /// Windows' own rule for local account names.
    static func isValidUsername(_ name: String) -> Bool {
        let forbidden = Set(#""/\[]:;|=,+*?<>"#)
        return !name.isEmpty && name.count <= 20 && !name.contains(where: forbidden.contains)
            && !name.allSatisfy { $0 == "." || $0 == " " }
    }

    /// Readable off the screen: no l/1, O/0, I.
    static func newPassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }
}
