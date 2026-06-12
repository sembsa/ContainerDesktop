import SwiftUI
import AppKit

/// Structured inspect view showing container details in categorized sections.
struct InspectView: View {
    let container: ContainerInfo
    let fetchRaw: () async throws -> String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                OverviewCard(container: container)
                EnvironmentCard(container: container)
                PortsCard(container: container)
                MountsCard(container: container)
                LabelsCard(container: container)
                NetworksCard(container: container)
                RawJSONCard(fetchRaw: fetchRaw)
            }
            .padding(12)
        }
    }
}

// MARK: - Card container

private struct SectionCard<Content: View>: View {
    let title: String
    var infoTipText: String? = nil
    var headerIcon: String? = nil
    var headerTint: Color = .secondary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let icon = headerIcon {
                    Image(systemName: icon)
                        .foregroundStyle(headerTint.gradient)
                }
                Text(title).font(.headline)
                if let tip = infoTipText {
                    InfoTip(text: tip)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Overview

private struct OverviewCard: View {
    let container: ContainerInfo

    private var cfg: ContainerInfo.Configuration { container.configuration }

    var body: some View {
        SectionCard(title: String(localized: "Przegląd"), headerIcon: "info.circle.fill", headerTint: .blue) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                overviewRow("ID", mono: container.id)
                stateRow
                overviewRow(String(localized: "Obraz"), mono: cfg.image.reference)
                if let digest = cfg.image.descriptor?.digest {
                    let short = digestShort(digest)
                    GridRow {
                        Text("Digest")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(short)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .help(digest)
                    }
                }
                if let created = cfg.creationDate {
                    overviewRow(String(localized: "Utworzony"), value: created.formatted(date: .abbreviated, time: .standard))
                }
                if let started = container.status?.startedDate {
                    overviewRow(String(localized: "Uruchomiony"), value: started.formatted(date: .abbreviated, time: .standard))
                }
                if let platform = cfg.platform {
                    let platformStr = [platform.os, platform.architecture]
                        .compactMap { $0 }
                        .joined(separator: "/")
                    if !platformStr.isEmpty {
                        overviewRow(String(localized: "Platforma"), mono: platformStr)
                    }
                }
                if let rth = cfg.runtimeHandler, !rth.isEmpty {
                    overviewRow("Runtime", mono: rth)
                }
                if let rosetta = cfg.rosetta {
                    overviewRow("Rosetta", value: rosetta ? String(localized: "tak") : String(localized: "nie"))
                }
                if cfg.readOnly == true {
                    overviewRow(String(localized: "Tylko-do-odczytu"), value: String(localized: "tak"))
                }
                if cfg.ssh == true {
                    overviewRow("SSH", value: String(localized: "tak"))
                }
                if cfg.virtualization == true {
                    overviewRow(String(localized: "Wirtualizacja"), value: String(localized: "tak"))
                }

                Divider().gridCellUnsizedAxes(.horizontal)

                if let init_ = cfg.initProcess {
                    let cmd = ([init_.executable] + (init_.arguments ?? []))
                        .compactMap { $0 }
                        .joined(separator: " ")
                    if !cmd.isEmpty {
                        GridRow {
                            Text("Polecenie")
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(cmd)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    if let wd = init_.workingDirectory, !wd.isEmpty {
                        overviewRow(String(localized: "Katalog roboczy"), mono: wd)
                    }
                }

                if let res = cfg.resources {
                    let cpus = res.cpus.map { "\($0)" } ?? "—"
                    let mem = Format.memory(res.memoryInBytes)
                    overviewRow(String(localized: "Zasoby"), value: String(format: String(localized: "CPU: %@ · Pamięć: %@"), cpus, mem))
                }
            }
        }
    }

    private var stateRow: some View {
        GridRow {
            Text("Stan")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
                StatusDot(state: container.state)
                Text(container.state)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func overviewRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func overviewRow(_ label: String, mono: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(mono)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func digestShort(_ digest: String) -> String {
        // e.g. "sha256:abcdef123456..." → "sha256:" + first 12 hex chars
        if digest.hasPrefix("sha256:") {
            let hex = String(digest.dropFirst(7))
            let short = String(hex.prefix(12))
            return "sha256:\(short)"
        }
        return String(digest.prefix(20))
    }
}

// MARK: - Environment variables

private struct EnvironmentCard: View {
    let container: ContainerInfo

    private var env: [String] {
        container.configuration.initProcess?.environment ?? []
    }

    var body: some View {
        if env.isEmpty { EmptyView() } else {
            SectionCard(title: String(format: String(localized: "Zmienne środowiskowe (%lld)"), env.count), headerIcon: "curlybraces", headerTint: .green) {
                HStack {
                    Spacer()
                    Button {
                        copyAll()
                    } label: {
                        Label("Kopiuj wszystkie", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(env, id: \.self) { entry in
                        EnvRow(entry: entry)
                    }
                }
            }
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env.joined(separator: "\n"), forType: .string)
    }
}

private struct EnvRow: View {
    let entry: String

    private var keyValue: (String, String) {
        if let idx = entry.firstIndex(of: "=") {
            let key = String(entry[entry.startIndex..<idx])
            let value = String(entry[entry.index(after: idx)...])
            return (key, value)
        }
        return (entry, "")
    }

    var body: some View {
        let (key, value) = keyValue
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .layoutPriority(1)
            Text(value.isEmpty ? "" : "=")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Kopiuj \(entry)")
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Ports

private struct PortsCard: View {
    let container: ContainerInfo

    private var ports: [ContainerInfo.Configuration.PublishedPort] {
        container.configuration.publishedPorts ?? []
    }

    var body: some View {
        if ports.isEmpty { EmptyView() } else {
            SectionCard(title: String(format: String(localized: "Porty (%lld)"), ports.count), headerIcon: "network", headerTint: .purple) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ports) { port in
                        HStack(spacing: 4) {
                            Text(port.display)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            if container.isRunning,
                               let hostPort = port.hostPort,
                               (port.proto ?? "tcp") == "tcp" {
                                Button {
                                    if let url = URL(string: "http://localhost:\(hostPort)") {
                                        NSWorkspace.shared.open(url)
                                    }
                                } label: {
                                    Image(systemName: "arrow.up.forward")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                                .help(String(format: String(localized: "Otwórz http://localhost:%lld w przeglądarce"), hostPort))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Mounts

private struct MountsCard: View {
    let container: ContainerInfo

    private var mounts: [ContainerInfo.Configuration.Mount] {
        container.configuration.mounts ?? []
    }

    var body: some View {
        if mounts.isEmpty { EmptyView() } else {
            SectionCard(title: String(format: String(localized: "Montowania (%lld)"), mounts.count),
                        infoTipText: String(localized: "Zamontowane wolumeny i katalogi. Dane w nich przetrwają usunięcie kontenera."),
                        headerIcon: "externaldrive.fill",
                        headerTint: .orange) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mounts) { mount in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(mount.source ?? "—")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(mount.source ?? "")
                            Text("→")
                                .foregroundStyle(.tertiary)
                            Text(mount.destination ?? "—")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Labels

private struct LabelsCard: View {
    let container: ContainerInfo

    private var labels: [(String, String)] {
        (container.configuration.labels ?? [:])
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        if labels.isEmpty { EmptyView() } else {
            SectionCard(title: String(format: String(localized: "Etykiety (%lld)"), labels.count), headerIcon: "tag.fill", headerTint: .yellow) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(labels, id: \.0) { key, value in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(key)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                            Text("=")
                                .foregroundStyle(.tertiary)
                                .font(.system(.caption, design: .monospaced))
                            Text(value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Networks

private struct NetworksCard: View {
    let container: ContainerInfo

    private var networks: [ContainerInfo.Status.NetworkStatus] {
        container.status?.networks ?? []
    }

    var body: some View {
        if networks.isEmpty { EmptyView() } else {
            SectionCard(title: String(format: String(localized: "Sieci (%lld)"), networks.count),
                        infoTipText: String(localized: "Sieci, do których podłączony jest kontener, wraz z adresem IP przydzielonym przez lokalny DHCP."),
                        headerIcon: "point.3.connected.trianglepath.dotted",
                        headerTint: .teal) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(networks.enumerated()), id: \.offset) { _, net in
                        let parts = [net.network, net.hostname, net.ipv4Address].compactMap { $0 }
                        Text(parts.joined(separator: " · "))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - Raw JSON

private struct RawJSONCard: View {
    let fetchRaw: () async throws -> String

    @State private var isExpanded = false
    @State private var loadState: LoadState = .idle

    enum LoadState {
        case idle
        case loading
        case loaded(JSONValue)
        case fallback(String)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $isExpanded) {
                rawContent
                    .frame(maxHeight: 400)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(Color.secondary.gradient)
                    Text("Surowy JSON")
                }
            }
            .font(.headline)
            .onChange(of: isExpanded) { _, newValue in
                if newValue, case .idle = loadState {
                    Task { await load() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var rawContent: some View {
        switch loadState {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding()
        case .loaded(let jsonValue):
            JSONTreeView(value: jsonValue)
        case .fallback(let text):
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .padding(8)
        }
    }

    private func load() async {
        loadState = .loading
        do {
            let raw = try await fetchRaw()
            let data = Data(raw.utf8)
            let decoder = JSONDecoder()
            // inspect returns either a single object or an array (list context)
            if let jsonValue = try? decoder.decode(JSONValue.self, from: data) {
                loadState = .loaded(jsonValue)
            } else {
                loadState = .fallback(raw)
            }
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }
}
