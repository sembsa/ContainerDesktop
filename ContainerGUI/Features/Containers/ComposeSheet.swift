import SwiftUI

/// Arkusz uruchamiania docker-compose — wg wzorca RunContainerSheet.
struct ComposeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var projectName: String = "compose"
    @State private var replaceExisting: Bool = true
    @State private var yamlText: String = ""
    @State private var parsedProject: ComposeProject?
    @State private var parseError: String?
    @State private var runTask: Task<Void, Never>?
    @State private var parseDebounceTask: Task<Void, Never>?

    private var store: ComposeStore { model.compose }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 720, height: 740)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.down.right.fill")
                .foregroundStyle(Color.cyan.gradient)
            Text("Uruchom Docker Compose")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            // --- Projekt ---
            Section {
                TextField("compose", text: $projectName)
                HStack(spacing: 4) {
                    Toggle("Zastąp istniejące kontenery o tych samych nazwach", isOn: $replaceExisting)
                    InfoTip(text: String(localized: "Nazwa grupuje kontenery na liście i tworzy wspólną sieć — kontenery widzą się po swoich nazwach (hostname = nazwa kontenera)."))
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.cyan.gradient)
                    Text("Projekt")
                }
            }

            // --- docker-compose.yml ---
            Section {
                TextEditor(text: $yamlText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 240, maxHeight: 240)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .onChange(of: yamlText) {
                        scheduleParseDebounce()
                    }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Color.cyan.gradient)
                    Text("docker-compose.yml")
                    InfoTip(text: String(localized: "Rozszerzenie x-init: true oznacza zadanie jednorazowe (np. utworzenie bazy danych) — uruchamiane tym samym lub innym obrazem przed startem pozostałych usług; usługi wystartują dopiero po jego pomyślnym zakończeniu."))
                }
            }

            // --- Wykryte usługi / błąd ---
            servicesSection

            // --- Postęp ---
            if store.isRunning || !store.logLines.isEmpty {
                progressSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var servicesSection: some View {
        if let error = parseError {
            Section {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Color.cyan.gradient)
                    Text(String(format: String(localized: "Wykryte usługi (%lld)"), 0))
                }
            }
        } else if let project = parsedProject {
            Section {
                ForEach(project.services) { service in
                    serviceRow(service, project: project)
                }
                if !project.warnings.isEmpty {
                    ForEach(project.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(warning)
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Color.cyan.gradient)
                    Text(String(format: String(localized: "Wykryte usługi (%lld)"), Int64(project.services.count)))
                }
            }
        }
    }

    @ViewBuilder
    private func serviceRow(_ service: ComposeService, project: ComposeProject) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 7, height: 7)
                if service.isInit {
                    Text("init")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help(String(localized: "zadanie jednorazowe — wykona się przed startem usług"))
                }
                Text(service.name)
                    .fontWeight(.semibold)
                Text(service.image)
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                if !service.ports.isEmpty {
                    Text(String(format: String(localized: "%lld %@"),
                                Int64(service.ports.count),
                                service.ports.count == 1 ? String(localized: "port") : String(localized: "porty")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !service.dependsOn.isEmpty {
                Text(String(format: String(localized: "zależy od: %@"), service.dependsOn.joined(separator: ", ")))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 13)
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        Section {
            ForEach(store.statuses) { status in
                HStack(spacing: 6) {
                    statusIndicator(for: status.phase)
                    Text(status.id)
                        .fontWeight(.medium)
                    if case .failed(let msg) = status.phase {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            if !store.logLines.isEmpty {
                StreamLogBox(lines: store.logLines.map { LogLine(text: $0) })
                    .frame(height: 140)
            }
        } header: {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(Color.cyan.gradient)
                Text("Postęp")
            }
        }
    }

    @ViewBuilder
    private func statusIndicator(for phase: ComposeStore.ServicePhase) -> some View {
        switch phase {
        case .pending:
            Circle()
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
        case .creating:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11))
        case .failed:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Anuluj") {
                if store.isRunning {
                    runTask?.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            let serviceCount = parsedProject?.services.count ?? 0
            Button {
                runTask = Task { await runCompose() }
            } label: {
                Text(String(format: String(localized: "Uruchom (%lld usług)"), Int64(serviceCount)))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
            .disabled(parsedProject == nil || parseError != nil || store.isRunning || serviceCount == 0)
        }
        .padding(12)
    }

    // MARK: - Logic

    private func scheduleParseDebounce() {
        parseDebounceTask?.cancel()
        parseDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let yaml = yamlText
            let name = projectName.isEmpty ? "compose" : projectName
            do {
                let project = try ComposeParser.parse(yaml, projectName: name)
                parsedProject = project
                parseError = nil
                // Reflect an effective project name from the YAML back into the
                // text field, so the user sees what will actually be used. Only
                // when the YAML declares `name:` and it differs from the field.
                if project.nameFromYAML, project.name != projectName {
                    projectName = project.name
                }
            } catch {
                parsedProject = nil
                parseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func runCompose() async {
        // Always use the parsed project. Its `name` is already the effective
        // project name: a top-level `name:` from the YAML, otherwise the
        // (normalized) text-field fallback supplied at parse time. We must not
        // re-substitute the raw text field here — doing so previously discarded
        // the YAML name (e.g. `name: demoapp` reverted to "compose").
        guard let project = parsedProject else { return }

        let success = await store.up(project, replaceExisting: replaceExisting)
        if success {
            await model.containers.refresh()
            dismiss()
        }
        // On partial failure: stay open so user sees statuses.
    }
}
