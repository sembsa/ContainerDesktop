import SwiftUI

/// Installs or upgrades a chart, with a values editor that has two views of the
/// same data: a generated form and the raw overrides YAML.
///
/// The form is built from the chart's own `values.yaml`, so it adapts to
/// whatever chart is selected instead of hard-coding fields. Only edited keys
/// end up in the overrides document — see `ChartValues`.
struct InstallChartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let chart: HelmChart
    /// Non-nil when upgrading an existing release rather than installing a new one.
    let upgrading: HelmRelease?

    private enum Editor: String, CaseIterable, Identifiable {
        case form, yaml
        var id: String { rawValue }
        var title: String {
            switch self {
            case .form: String(localized: "Formularz")
            case .yaml: String(localized: "YAML")
            }
        }
    }

    @State private var releaseName = ""
    @State private var namespace = "default"
    @State private var createNamespace = true
    @State private var waitForReady = true
    @State private var version = ""
    @State private var availableVersions: [HelmChart] = []

    @State private var fields: [ValuesField] = []
    @State private var edits: [String: String] = [:]
    @State private var overridesYAML = ""
    @State private var editor: Editor = .form
    @State private var filter = ""
    @State private var expandedGroups: Set<String> = []

    @State private var isLoadingValues = true
    @State private var isRunning = false
    @State private var finished = false
    @State private var validationError: String?
    @State private var dryRunResult: String?
    @State private var output: [LogLine] = []

    private var store: HelmStore { model.helm }
    private var isUpgrade: Bool { upgrading != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                settingsPane
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                valuesPane
                    .frame(minWidth: 360)
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 640)
        .task { await loadChart() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isUpgrade ? "arrow.up.circle.fill" : "shippingbox.fill")
                .foregroundStyle(Color.cyan.gradient)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(isUpgrade ? String(localized: "Aktualizuj wdrożenie") : String(localized: "Zainstaluj chart"))
                    .font(.headline)
                Text(chart.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let cluster = store.targetCluster {
                Label(cluster, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Settings

    private var settingsPane: some View {
        Form {
            Section {
                TextField("Nazwa wdrożenia", text: $releaseName)
                    .disabled(isUpgrade)
                TextField("Przestrzeń nazw", text: $namespace)
                    .disabled(isUpgrade)
                if !isUpgrade {
                    Toggle("Utwórz przestrzeń nazw", isOn: $createNamespace)
                }
                Picker("Wersja chartu", selection: $version) {
                    Text("najnowsza").tag("")
                    ForEach(availableVersions) { candidate in
                        Text(candidate.version).tag(candidate.version)
                    }
                }
                .onChange(of: version) { _, _ in Task { await reloadDefaults() } }
                HStack(spacing: 4) {
                    Toggle("Czekaj na gotowość", isOn: $waitForReady)
                    InfoTip(text: String(localized: "Polecenie zakończy się dopiero, gdy wszystkie zasoby wdrożenia będą gotowe (--wait). Bez tego helm kończy się od razu po wysłaniu manifestów."))
                }
            } header: {
                Text("Wdrożenie")
            }

            if let dryRunResult {
                Section {
                    Text(dryRunResult)
                        .font(.caption)
                        .foregroundStyle(dryRunResult.hasPrefix("OK") ? .green : .red)
                        .textSelection(.enabled)
                } header: {
                    Text("Weryfikacja")
                }
            }

            if !output.isEmpty {
                Section {
                    StreamLogBox(lines: output)
                        .frame(minHeight: 120)
                } header: {
                    Text("Przebieg")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isRunning)
    }

    // MARK: - Values editor

    private var valuesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $editor) {
                    ForEach(Editor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: editor) { _, newValue in syncEditor(to: newValue) }

                if editor == .form {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Filtruj klucze…", text: $filter)
                            .textFieldStyle(.plain)
                            .font(.caption)
                    }
                }
                Spacer()
                if !edits.isEmpty {
                    Text(String(format: String(localized: "zmienione: %d"), edits.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Wyczyść") {
                        edits = [:]
                        overridesYAML = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(10)
            Divider()

            if isLoadingValues {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editor == .form {
                formEditor
            } else {
                yamlEditor
            }

            if let validationError {
                Divider()
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var formEditor: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groupedFields, id: \.name) { group in
                    DisclosureGroup(
                        isExpanded: expansionBinding(for: group.name)
                    ) {
                        ForEach(group.fields) { field in
                            fieldRow(field)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.name.isEmpty ? String(localized: "Ogólne") : group.name)
                                .font(.subheadline.weight(.medium))
                            Text("\(group.fields.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if group.fields.contains(where: { edits[$0.path] != nil }) {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: ValuesField) -> some View {
        let isEdited = edits[field.path] != nil
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(field.label)
                    .font(.callout)
                    .foregroundStyle(isEdited ? Color.accentColor : .primary)
                if let comment = field.comment {
                    InfoTip(text: comment)
                }
                Spacer(minLength: 8)
                if field.kind.isInline {
                    control(for: field)
                        .frame(width: 200, alignment: .trailing)
                }
                // The reset button holds its slot whether or not it is visible.
                // Letting it appear only once edited shifted every control
                // leftwards the moment a switch was flipped.
                Button("Przywróć", systemImage: "arrow.uturn.backward") {
                    edits[field.path] = nil
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Przywróć wartość domyślną chartu")
                .opacity(isEdited ? 1 : 0)
                .disabled(!isEdited)
                .accessibilityHidden(!isEdited)
                .frame(width: 20)
            }
            if !field.kind.isInline {
                control(for: field)
                    .padding(.trailing, 26)
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func control(for field: ValuesField) -> some View {
        switch field.kind {
        case .boolean:
            Toggle("", isOn: booleanBinding(field))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        case .number, .string:
            TextField(field.defaultValue, text: textBinding(field), prompt: Text(field.defaultValue))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
        case .stringList:
            ValuesListEditor(items: listBinding(field))
        case .yaml:
            ValuesYAMLEditor(text: textBinding(field), placeholder: field.defaultValue)
        }
    }

    private var yamlEditor: some View {
        TextEditor(text: $overridesYAML)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .overlay(alignment: .topLeading) {
                if overridesYAML.isEmpty {
                    Text("# Tylko nadpisania — puste oznacza wartości domyślne chartu\n# np.\n# replicaCount: 2")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Sprawdź (dry-run)") {
                Task { await runDryRun() }
            }
            .disabled(!canSubmit || isRunning)
            .help("Renderuje wdrożenie na klastrze bez wprowadzania zmian — wykrywa błędy szablonów i niezgodność ze schematem values.")
            Spacer()
            Button(finished ? "Gotowe" : "Anuluj") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await submit() }
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isUpgrade ? String(localized: "Aktualizuj") : String(localized: "Zainstaluj"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
            .disabled(!canSubmit || isRunning)
        }
        .padding(12)
    }

    private var canSubmit: Bool {
        !releaseName.isEmpty && !namespace.isEmpty && store.target != nil
    }

    // MARK: - Data

    private struct FieldGroup {
        let name: String
        let fields: [ValuesField]
    }

    private var groupedFields: [FieldGroup] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? fields
            : fields.filter { $0.path.lowercased().contains(needle) }

        var order: [String] = []
        var byGroup: [String: [ValuesField]] = [:]
        for field in matching {
            if byGroup[field.group] == nil { order.append(field.group) }
            byGroup[field.group, default: []].append(field)
        }
        return order.map { FieldGroup(name: $0, fields: byGroup[$0] ?? []) }
    }

    private func expansionBinding(for group: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(group) || !filter.isEmpty },
            set: { isExpanded in
                if isExpanded { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
            }
        )
    }

    private func textBinding(_ field: ValuesField) -> Binding<String> {
        Binding(
            get: { edits[field.path] ?? field.defaultValue },
            set: { newValue in
                if newValue == field.defaultValue {
                    edits[field.path] = nil
                } else {
                    edits[field.path] = newValue
                }
            }
        )
    }

    /// Rows for a `.stringList` field. The edit itself stays a single flow-style
    /// string (`["a", "b"]`) so the YAML tab and the form remain one source of
    /// truth; this only presents it as rows.
    private func listBinding(_ field: ValuesField) -> Binding<[String]> {
        Binding(
            get: { ChartValues.listItems(edits[field.path] ?? field.defaultValue) },
            set: { items in
                let encoded = ChartValues.flowList(items)
                if encoded == field.defaultValue {
                    edits[field.path] = nil
                } else {
                    edits[field.path] = encoded
                }
            }
        )
    }

    private func booleanBinding(_ field: ValuesField) -> Binding<Bool> {
        Binding(
            get: { (edits[field.path] ?? field.defaultValue).lowercased() == "true" },
            set: { newValue in
                let text = newValue ? "true" : "false"
                if text == field.defaultValue.lowercased() {
                    edits[field.path] = nil
                } else {
                    edits[field.path] = text
                }
            }
        )
    }

    /// Keeps the two editors showing the same overrides.
    private func syncEditor(to newValue: Editor) {
        validationError = nil
        switch newValue {
        case .yaml:
            overridesYAML = (try? ChartValues.overridesYAML(edits: edits, fields: fields)) ?? overridesYAML
        case .form:
            if let problem = ChartValues.validate(overridesYAML) {
                validationError = problem
                editor = .yaml
                return
            }
            edits = ChartValues.edits(fromOverrides: overridesYAML, fields: fields)
        }
    }

    private func loadChart() async {
        releaseName = upgrading?.name ?? chart.chartName
        namespace = upgrading?.namespace ?? "default"
        version = chart.version
        availableVersions = await store.versions(of: chart.name)
        await reloadDefaults()

        // On upgrade, start from the values the release already runs with.
        if let upgrading, let existing = try? await store.userValues(of: upgrading), !existing.isEmpty {
            overridesYAML = existing
            edits = ChartValues.edits(fromOverrides: existing, fields: fields)
        }
    }

    private func reloadDefaults() async {
        isLoadingValues = true
        defer { isLoadingValues = false }
        do {
            let yaml = try await store.defaultValues(of: chart.name, version: version)
            fields = try ChartValues.fields(from: yaml)
            // Open the first few groups so the pane isn't a wall of arrows.
            expandedGroups = Set(groupedFields.prefix(3).map(\.name))
        } catch {
            fields = []
            validationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Writes the overrides to a temp file and returns its path, or nil when
    /// there is nothing to override.
    private func writeValuesFile() throws -> String? {
        let yaml: String
        if editor == .yaml {
            yaml = overridesYAML
        } else {
            yaml = try ChartValues.overridesYAML(edits: edits, fields: fields)
        }
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let problem = ChartValues.validate(yaml) {
            throw CLIError.command(exitCode: -1, stderr: problem)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "containerdesktop-values-\(UUID().uuidString).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func runDryRun() async {
        isRunning = true
        defer { isRunning = false }
        dryRunResult = nil
        validationError = nil
        do {
            let file = try writeValuesFile()
            defer { if let file { try? FileManager.default.removeItem(atPath: file) } }
            _ = try await store.dryRun(
                release: releaseName,
                chart: chart.name,
                version: version,
                namespace: namespace,
                valuesFile: file
            )
            dryRunResult = String(localized: "OK — wdrożenie renderuje się poprawnie.")
        } catch {
            dryRunResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit() async {
        guard let target = store.target else { return }
        isRunning = true
        finished = false
        output = []
        validationError = nil
        defer { isRunning = false }

        let file: String?
        do {
            file = try writeValuesFile()
        } catch {
            validationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        defer { if let file { try? FileManager.default.removeItem(atPath: file) } }

        let stream = store.installStream(
            release: releaseName,
            chart: chart.name,
            version: version,
            namespace: namespace,
            valuesFile: file,
            createNamespace: createNamespace && !isUpgrade,
            wait: waitForReady,
            upgrade: isUpgrade,
            on: target
        )
        do {
            for try await line in stream {
                output.append(LogLine(text: line))
            }
            finished = true
        } catch {
            output.append(LogLine(text: String(format: String(localized: "[błąd: %@]"), error.localizedDescription)))
        }
        await store.refreshReleases()
    }
}
