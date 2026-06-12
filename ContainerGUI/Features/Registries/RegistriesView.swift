import SwiftUI

struct RegistriesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: RegistryLogin.ID?
    @State private var showLogin = false
    @State private var pendingLogout: RegistryLogin?

    private var store: RegistryStore { model.registries }

    var body: some View {
        Group {
            if store.items.isEmpty, model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "key",
                    title: String(localized: "Brak zalogowanych rejestrów"),
                    message: String(localized: "Zaloguj się do rejestru, aby pobierać i wysyłać prywatne obrazy."),
                    actionTitle: String(localized: "Zaloguj się…"),
                    action: { showLogin = true },
                    tint: .pink
                )
            } else {
                Table(store.items, selection: $selection) {
                    TableColumn("Host") { Text($0.hostname).fontWeight(.medium) }
                    TableColumn("Użytkownik") { Text($0.username).foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: RegistryLogin.ID.self) { ids in
                    if let id = ids.first, let login = store.items.first(where: { $0.id == id }) {
                        Button("Wyloguj…", role: .destructive) { pendingLogout = login }
                    }
                }
            }
        }
        .navigationTitle("Rejestry")
        .task { await store.refresh() }
        .toolbar {
            ToolbarItemGroup {
                InfoTip(text: String(localized: "Zapisane logowania do prywatnych rejestrów. Dzięki nim pull i push prywatnych obrazów działają bez podawania hasła."), size: .regular)
                Button { showLogin = true } label: { Label("Zaloguj", systemImage: "plus") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { Task { await store.refresh() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showLogin) { RegistryLoginSheet().environment(model) }
        .confirmationDialog(
            "Wylogować z rejestru?",
            isPresented: Binding(get: { pendingLogout != nil }, set: { if !$0 { pendingLogout = nil } }),
            presenting: pendingLogout
        ) { login in
            Button("Wyloguj", role: .destructive) {
                Task {
                    do { try await store.logout(login) } catch { model.present(error) }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { login in
            Text("Sesja dla \(login.hostname) zostanie usunięta.")
        }
    }
}

struct RegistryLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.pink.gradient)
                    .font(.title3)
                Text("Logowanie do rejestru")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    TextField("Serwer (np. ghcr.io)", text: $server)
                    TextField("Użytkownik", text: $username)
                    SecureField("Hasło / token", text: $password)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Color.pink.gradient)
                        Text("Dane logowania")
                        InfoTip(text: String(localized: "Logowanie do prywatnego rejestru obrazów (np. ghcr.io, Docker Hub). Hasło trafia bezpiecznie przez stdin — nie pojawia się w historii poleceń."))
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
                    Task { await login() }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Zaloguj") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(server.isEmpty || username.isEmpty || password.isEmpty || isWorking)
            }
            .padding(12)
        }
        .frame(width: 480)
    }

    private func login() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.registries.login(server: server, username: username, password: password)
            dismiss()
        } catch {
            model.present(error)
        }
    }
}
