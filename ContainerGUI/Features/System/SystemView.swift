import SwiftUI

struct SystemView: View {
    @Environment(AppModel.self) private var model

    private var store: SystemStore { model.system }
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    @State private var showAddDNS = false
    @State private var newDomain = ""
    @State private var pendingDNSDelete: String?
    @State private var logsWindow: String = "5m"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                serviceCard
                builderCard
                diskSection
                dnsSection
                propertiesSection
                logsSection
            }
            .padding(16)
        }
        .navigationTitle("System")
        .toolbar {
            Button {
                Task { await refreshAll() }
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
        }
        .task { await refreshAll() }
        .alert("Nowa domena DNS", isPresented: $showAddDNS) {
            TextField("np. test", text: $newDomain)
            Button("Utwórz") {
                let domain = newDomain
                newDomain = ""
                Task {
                    do { try await store.createDNS(domain) } catch { model.present(error) }
                }
            }
            Button("Anuluj", role: .cancel) { newDomain = "" }
        } message: {
            Text("Tworzenie domeny DNS wymaga uprawnień administratora.")
        }
        .confirmationDialog(
            "Usunąć domenę DNS?",
            isPresented: Binding(get: { pendingDNSDelete != nil }, set: { if !$0 { pendingDNSDelete = nil } }),
            presenting: pendingDNSDelete
        ) { domain in
            Button("Usuń", role: .destructive) {
                Task {
                    do { try await store.deleteDNS(domain) } catch { model.present(error) }
                }
            }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private func refreshAll() async {
        await store.refreshState()
        await store.refreshDiskUsage()
        await store.refreshBuilder()
        await store.refreshProperties()
        await store.refreshDNS()
        await store.refreshSystemLogs(last: logsWindow)
    }

    // MARK: - Cards

    private var serviceCard: some View {
        let serviceStatusText: String = {
            switch store.serviceState {
            case .running: return String(localized: "Działa")
            case .stopped: return String(localized: "Zatrzymana")
            case .starting: return String(localized: "Uruchamianie…")
            case .stopping:
                if let detail = store.transitionDetail {
                    return String(format: String(localized: "Zatrzymywanie… (%@)"), detail)
                }
                return String(localized: "Zatrzymywanie…")
            case .unknown: return String(localized: "Sprawdzanie…")
            }
        }()
        let serviceDotColor: Color = {
            switch store.serviceState {
            case .running: return .green
            case .stopped: return .red
            case .starting, .stopping: return .orange
            case .unknown: return .gray
            }
        }()
        return statusCard(
            title: String(localized: "Usługa container"),
            headerIcon: "gearshape.2.fill",
            headerTint: .blue,
            dotColor: serviceDotColor,
            statusText: serviceStatusText,
            caption: String(localized: "Usługa w tle (apiserver) zarządza kontenerami, obrazami i siecią. Bez niej żadna operacja nie działa."),
            busy: store.serviceState.isTransitioning
        ) {
            if !store.serviceState.isTransitioning {
                Button(store.serviceState.isRunning ? "Zatrzymaj" : "Uruchom") {
                    Task {
                        if store.serviceState.isRunning { await model.stopService() }
                        else { await model.startService() }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.serviceState)
    }

    private var builderCard: some View {
        statusCard(
            title: String(localized: "Builder obrazów"),
            headerIcon: "hammer.fill",
            headerTint: .purple,
            dotColor: store.builderRunning ? .green : .red,
            statusText: store.builderRunning ? String(localized: "Działa") : String(localized: "Nieaktywny"),
            caption: String(localized: "Pomocnicza maszyna wirtualna (BuildKit) używana przez \u{201E}Buduj obraz\u{201D}. Startuje automatycznie przy pierwszym budowaniu \u{2014} nie musisz jej w\u{142}\u{105}cza\u{107} r\u{119}cznie. Zatrzymaj lub usu\u{144}, by zwolni\u{107} zasoby."),
            busy: store.isBusy
        ) {
            if store.builderRunning {
                Button("Zatrzymaj") { Task { await store.stopBuilder() } }
                Button("Usuń") { Task { await store.deleteBuilder() } }
            } else {
                Button("Uruchom") { Task { await store.startBuilder() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var diskSection: some View {
        if let usage = store.diskUsage {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(Color.orange.gradient)
                Text("Zużycie dysku").font(.headline)
                InfoTip(text: String(localized: "Miejsce zajmowane przez kontenery, obrazy i wolumeny. «Do odzysku» — dane usuwalne przez czyszczenie (prune): zatrzymane kontenery i nieużywane obrazy."))
            }
            LazyVGrid(columns: columns, spacing: 12) {
                usageCard(String(localized: "Kontenery"), entry: usage.containers, tint: .blue)
                usageCard(String(localized: "Obrazy"), entry: usage.images, tint: .purple)
                usageCard(String(localized: "Wolumeny"), entry: usage.volumes, tint: .orange)
            }
        }
    }

    private var dnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(Color.teal.gradient)
                Text("Lokalne domeny DNS").font(.headline)
                InfoTip(text: String(localized: "Pozwala odwoływać się do kontenerów po nazwie hosta, np. http://web.test zamiast adresu IP. Zmiany wymagają uprawnień administratora."))
                Spacer()
                Button("Dodaj…", systemImage: "plus") { showAddDNS = true }
                    .buttonStyle(.borderless)
            }
            if store.dnsDomains.isEmpty {
                Text("Brak skonfigurowanych domen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.dnsDomains, id: \.self) { domain in
                    HStack {
                        Image(systemName: "globe")
                        Text(domain)
                        Spacer()
                        Button(role: .destructive) {
                            pendingDNSDelete = domain
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var propertiesSection: some View {
        if let properties = store.properties, case .object(let sections) = properties {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.indigo.gradient)
                    Text("Właściwości systemu").font(.headline)
                    InfoTip(text: String(localized: "Domyślne ustawienia CLI: zasoby nowych kontenerów i maszyn, rejestr, jądro. Zmienisz je poleceniem container system property set."))
                }
                ForEach(sections.keys.sorted(), id: \.self) { key in
                    if let sectionValue = sections[key],
                       case .object(let fields) = sectionValue,
                       !fields.isEmpty {
                        propertySectionCard(key: key, fields: fields)
                    }
                }
            }
        }
    }

    private func propertySectionCard(key: String, fields: [String: JSONValue]) -> some View {
        let friendlyNames: [String: String] = [
            "build": String(localized: "builder obrazów"),
            "container": String(localized: "domyślne zasoby kontenerów"),
            "machine": String(localized: "domyślne zasoby maszyn"),
            "kernel": String(localized: "jądro Linux dla VM"),
            "registry": String(localized: "domyślny rejestr"),
            "vminit": String(localized: "obraz init VM")
        ]
        let headerTitle: String = {
            if let friendly = friendlyNames[key] {
                return "\(key) (\(friendly))"
            }
            return key.prefix(1).uppercased() + key.dropFirst()
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
            ForEach(propertyRows(from: fields), id: \.key) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.key)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 120, alignment: .leading)
                    if row.isLong {
                        Text(row.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.value)
                    } else {
                        Text(row.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private struct PropertyRow {
        let key: String
        let value: String
        let isLong: Bool
    }

    private func propertyRows(from fields: [String: JSONValue]) -> [PropertyRow] {
        var rows: [PropertyRow] = []
        for key in fields.keys.sorted() {
            guard let val = fields[key] else { continue }
            switch val {
            case .object(let nested):
                for subKey in nested.keys.sorted() {
                    if let subVal = nested[subKey], let scalar = subVal.scalarDescription {
                        let displayKey = "\(key).\(subKey)"
                        rows.append(PropertyRow(key: displayKey, value: scalar, isLong: scalar.count > 60))
                    }
                }
            case .array(let items):
                let text = items.compactMap(\.scalarDescription).joined(separator: ", ")
                rows.append(PropertyRow(key: key, value: text.isEmpty ? "—" : text, isLong: text.count > 60))
            default:
                if let scalar = val.scalarDescription {
                    rows.append(PropertyRow(key: key, value: scalar, isLong: scalar.count > 60))
                }
            }
        }
        return rows
    }

    @ViewBuilder
    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Color.secondary.gradient)
                Text("Logi usługi").font(.headline)
                InfoTip(text: String(localized: "Logi wewnętrzne usługi container (apiserver) — tu szukaj przyczyn, gdy operacje zawodzą."))
                Spacer()
                Picker("Okno", selection: $logsWindow) {
                    Text("5 min").tag("5m")
                    Text("30 min").tag("30m")
                    Text("1 h").tag("1h")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: logsWindow) { _, newValue in
                    Task { await store.refreshSystemLogs(last: newValue) }
                }
                Button {
                    Task { await store.refreshSystemLogs(last: logsWindow) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Odśwież logi")
            }

            if store.isLoadingLogs && store.systemLogs == nil {
                HStack {
                    ProgressView()
                    Text("Wczytywanie logów…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(16)
            } else if let logs = store.systemLogs, !logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(logs)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 260)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Brak logów w wybranym oknie.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Building blocks

    private func statusCard<Controls: View>(
        title: String,
        headerIcon: String? = nil,
        headerTint: Color = .secondary,
        dotColor: Color,
        statusText: String,
        caption: String? = nil,
        busy: Bool,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let icon = headerIcon {
                        Image(systemName: icon)
                            .foregroundStyle(headerTint.gradient)
                    }
                    Text(title).font(.headline)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                controls()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: busy)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func usageCard(_ title: String, entry: DiskUsage.Entry?, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(Format.bytes(entry?.sizeInBytes))
                .font(.title2.monospacedDigit())
            ProgressView(value: min(1.0, Double(entry?.active ?? 0) / Double(max(entry?.total ?? 1, 1))))
                .tint(tint)
            HStack {
                Text("Aktywne: \(entry?.active ?? 0)/\(entry?.total ?? 0)")
                Spacer()
                Text("Do odzysku: \(Format.bytes(entry?.reclaimable))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
