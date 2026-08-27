import AppKit
import SwiftUI

// MARK: - Shared pieces

/// The fact cards the rest of the app uses for object summaries.
struct WorkloadFactGrid: View {
    let tint: Color
    let facts: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(facts.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    Text(facts[index].0)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(facts[index].1.isEmpty ? "—" : facts[index].1)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(facts[index].1)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}

/// A header shaped like the cluster and machine detail headers.
struct WorkloadDetailHeader<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// `kubectl describe` — the one read meant to be shown verbatim. Events live at
/// the bottom of it, which is usually why anyone opens it.
struct WorkloadDescribeView: View {
    @Environment(AppModel.self) private var model

    let kind: String
    let name: String
    let namespace: String

    @State private var text = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if let errorText {
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "Nie udało się pobrać opisu"),
                    message: errorText,
                    tint: .orange
                )
            } else if isLoading && text.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Wczytywanie opisu…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button("Kopiuj", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(8)
                }
            }
        }
        .task(id: "\(kind)/\(namespace)/\(name)") { await load() }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            text = try await model.workloads.describe(kind: kind, name: name, namespace: namespace)
        } catch {
            text = ""
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// `kubectl logs` for one pod, with a picker when the pod has more than one
/// container — naming the wrong container is an error, and not naming one at all
/// is an error too once there are several.
struct PodLogsView: View {
    @Environment(AppModel.self) private var model

    let pod: K8sPod

    @State private var container: String?
    @State private var follow = true
    @State private var lines: [LogLine] = []
    @State private var pending: [LogLine] = []
    @State private var didLoad = false
    @State private var errorText: String?

    private static let tailLines = 500

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .task(id: reloadKey) { await load() }
    }

    private var reloadKey: String { "\(pod.id)|\(container ?? "")|\(follow)" }

    private var controls: some View {
        HStack(spacing: 8) {
            if pod.containerNames.count > 1 {
                Picker("Kontener", selection: $container) {
                    ForEach(pod.containerNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            Toggle("Śledź", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Spacer()
            if !lines.isEmpty {
                Text("\(lines.count) linii").font(.caption).foregroundStyle(.secondary)
                Button("Kopiuj", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Nie udało się odczytać logów"),
                message: errorText,
                tint: .orange
            )
        } else if lines.isEmpty, didLoad {
            EmptyStateView(
                symbol: "doc.text",
                title: String(localized: "Brak logów"),
                message: String(localized: "Kontener nie wypisał nic na stdout/stderr."),
                tint: .green
            )
        } else if lines.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Wczytywanie logów…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(lines: lines, showTimestamps: false, autoscroll: follow, colorize: true)
        }
    }

    private func load() async {
        lines = []
        pending = []
        didLoad = false
        errorText = nil
        if container == nil, pod.containerNames.count > 1 {
            container = pod.containerNames.first
        }
        guard let target = model.workloads.target else {
            errorText = String(localized: "Brak wybranego klastra.")
            didLoad = true
            return
        }

        // Same clock-driven handover as the machine log viewer: under --follow the
        // stream never ends, so a count-based flush would hold the last partial
        // batch forever.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                flush()
                didLoad = true
            }
        }
        defer { ticker.cancel() }

        do {
            let stream = model.workloads.logStream(
                pod: pod.metadata.name,
                namespace: pod.metadata.namespace ?? "default",
                container: container,
                tail: Self.tailLines,
                follow: follow,
                on: target
            )
            for try await line in stream {
                pending.append(LogLine(text: line))
                if pending.count >= 40 { flush() }
            }
            flush()
        } catch is CancellationError {
            return
        } catch {
            flush()
            if lines.isEmpty {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        didLoad = true
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending = []
        didLoad = true
    }
}

// MARK: - Pod

struct PodDetailView: View {
    @Environment(AppModel.self) private var model

    let pod: K8sPod

    @State private var tab: Tab = .overview
    @State private var execContainer: String?
    @State private var confirmDelete = false

    enum Tab: String, CaseIterable, Identifiable {
        case overview, logs, describe, terminal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: String(localized: "Przegląd")
            case .logs: String(localized: "Logi")
            case .describe: String(localized: "Describe")
            case .terminal: String(localized: "Terminal")
            }
        }
    }

    private var namespace: String { pod.metadata.namespace ?? "default" }

    var body: some View {
        VStack(spacing: 0) {
            WorkloadDetailHeader(
                symbol: "cube",
                tint: .green,
                title: pod.metadata.name,
                subtitle: "\(namespace) · \(pod.status?.phase ?? "—")"
            ) {
                Button("Usuń…", systemImage: "trash") { confirmDelete = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.workloads.busyIDs.contains(pod.id))
            }
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .overview: overview
            case .logs: PodLogsView(pod: pod)
            case .describe:
                WorkloadDescribeView(kind: "pod", name: pod.metadata.name, namespace: namespace)
            case .terminal: terminal
            }
        }
        .confirmationDialog(
            "Usunąć poda?",
            isPresented: $confirmDelete
        ) {
            Button("Usuń", role: .destructive) {
                Task {
                    do {
                        try await model.workloads.delete(
                            kind: "pod", name: pod.metadata.name, namespace: namespace, id: pod.id
                        )
                    } catch { model.present(error) }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Pod zostanie usunięty. Jeśli należy do deploymentu, kontroler odtworzy go pod nową nazwą — to nie jest restart w miejscu.")
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorkloadFactGrid(tint: .green, facts: [
                    (String(localized: "Stan"), pod.status?.phase ?? "—"),
                    (String(localized: "Gotowe"), "\(pod.readyContainers)/\(pod.totalContainers)"),
                    (String(localized: "Restarty"), String(pod.restartCount)),
                    (String(localized: "IP poda"), pod.status?.podIP ?? "—"),
                    (String(localized: "Węzeł"), pod.spec?.nodeName ?? "—"),
                    (String(localized: "Namespace"), namespace),
                    (String(localized: "Uruchomiony"),
                     pod.status?.startTime?.formatted(date: .abbreviated, time: .shortened) ?? "—"),
                ])
                if !pod.containerNames.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kontenery").font(.subheadline.weight(.semibold))
                        ForEach(pod.spec?.containers ?? [], id: \.name) { container in
                            HStack(spacing: 6) {
                                Image(systemName: "cube.fill").font(.caption).foregroundStyle(.green)
                                Text(container.name).font(.system(.caption, design: .monospaced).weight(.semibold))
                                Text(container.image ?? "—")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let target = model.workloads.target {
            VStack(spacing: 0) {
                if pod.containerNames.count > 1 {
                    HStack(spacing: 8) {
                        Picker("Kontener", selection: $execContainer) {
                            ForEach(pod.containerNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                let chosen = execContainer ?? pod.containerNames.first
                TerminalSessionView(
                    target: .pod(
                        name: pod.metadata.name,
                        namespace: namespace,
                        container: pod.containerNames.count > 1 ? chosen : nil,
                        kubeconfig: target
                    )
                )
                // Switching container has to restart the session; the flag is part
                // of the command line.
                .id(chosen ?? "")
            }
        } else {
            EmptyStateView(
                symbol: "terminal",
                title: String(localized: "Brak wybranego klastra."),
                tint: .green
            )
        }
    }
}

// MARK: - Deployment

struct DeploymentDetailView: View {
    @Environment(AppModel.self) private var model

    let deployment: K8sDeployment

    @State private var tab: Tab = .overview
    @State private var replicas: Int = 0
    @State private var loadedFor: String?

    enum Tab: String, CaseIterable, Identifiable {
        case overview, describe
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: String(localized: "Przegląd")
            case .describe: String(localized: "Describe")
            }
        }
    }

    private var namespace: String { deployment.metadata.namespace ?? "default" }
    private var isBusy: Bool { model.workloads.busyIDs.contains(deployment.id) }

    var body: some View {
        VStack(spacing: 0) {
            WorkloadDetailHeader(
                symbol: "square.stack.3d.up",
                tint: .green,
                title: deployment.metadata.name,
                subtitle: "\(namespace) · \(deployment.readyReplicas)/\(deployment.desiredReplicas)"
            ) {
                Button("Restart", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        do {
                            try await model.workloads.rolloutRestart(
                                deployment: deployment.metadata.name,
                                namespace: namespace,
                                id: deployment.id
                            )
                        } catch { model.present(error) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .help(String(localized: "rollout restart — wymienia pody po kolei, bez przestoju."))
            }
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .overview: overview
            case .describe:
                WorkloadDescribeView(kind: "deployment", name: deployment.metadata.name, namespace: namespace)
            }
        }
        .task(id: deployment.id) { loadReplicas() }
        .onChange(of: deployment.desiredReplicas) { _, _ in loadReplicas(force: true) }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorkloadFactGrid(tint: .green, facts: [
                    (String(localized: "Namespace"), namespace),
                    (String(localized: "Gotowe"), "\(deployment.readyReplicas)/\(deployment.desiredReplicas)"),
                    (String(localized: "Dostępne"), String(deployment.status?.availableReplicas ?? 0)),
                    (String(localized: "Zaktualizowane"), String(deployment.status?.updatedReplicas ?? 0)),
                ])

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skalowanie").font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        Stepper(value: $replicas, in: 0...50) {
                            Text("Repliki: \(replicas)").monospacedDigit()
                        }
                        .fixedSize()
                        Button("Zastosuj") {
                            Task {
                                do {
                                    try await model.workloads.scale(
                                        deployment: deployment.metadata.name,
                                        namespace: namespace,
                                        replicas: replicas,
                                        id: deployment.id
                                    )
                                } catch { model.present(error) }
                            }
                        }
                        .disabled(isBusy || replicas == deployment.desiredReplicas)
                        if isBusy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if replicas == 0 {
                        Text("Zero replik zatrzymuje wdrożenie, ale go nie usuwa.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))

                if !deployment.images.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Obrazy").font(.subheadline.weight(.semibold))
                        ForEach(deployment.images, id: \.self) { image in
                            Text(image)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(12)
        }
    }

    private func loadReplicas(force: Bool = false) {
        guard force || loadedFor != deployment.id else { return }
        loadedFor = deployment.id
        replicas = deployment.desiredReplicas
    }
}

// MARK: - Secret

/// Values stay hidden until asked for, one key at a time. A secret list that
/// prints its contents is a secret list nobody can screen-share.
struct SecretDetailView: View {
    let secret: K8sSecret

    @State private var revealed: Set<String> = []

    private var namespace: String { secret.metadata.namespace ?? "default" }

    var body: some View {
        VStack(spacing: 0) {
            WorkloadDetailHeader(
                symbol: "key",
                tint: .pink,
                title: secret.metadata.name,
                subtitle: "\(namespace) · \(secret.type ?? "—")"
            ) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(secret.keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(key)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                Spacer()
                                Button {
                                    if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                                } label: {
                                    Label(
                                        revealed.contains(key)
                                            ? String(localized: "Ukryj")
                                            : String(localized: "Pokaż"),
                                        systemImage: revealed.contains(key) ? "eye.slash" : "eye"
                                    )
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                            if revealed.contains(key) {
                                Text(secret.value(for: key) ?? String(localized: "wartość binarna"))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(verbatim: "••••••••")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - ConfigMap

struct ConfigMapDetailView: View {
    let configMap: K8sConfigMap

    private var namespace: String { configMap.metadata.namespace ?? "default" }

    var body: some View {
        VStack(spacing: 0) {
            WorkloadDetailHeader(
                symbol: "doc.text",
                tint: .blue,
                title: configMap.metadata.name,
                subtitle: namespace
            ) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(configMap.keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key).font(.system(.caption, design: .monospaced).weight(.semibold))
                            Text(configMap.data?[key] ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Anything else

/// Facts plus `describe`, for the kinds that need no actions of their own.
struct SimpleObjectDetailView: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let kind: String
    let name: String
    /// nil for cluster-scoped kinds, which `describe` takes without `-n`.
    let namespace: String?
    let facts: [(String, String)]

    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            WorkloadDetailHeader(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
                EmptyView()
            }
            Divider()
            Picker("", selection: $tab) {
                Text("Przegląd").tag(0)
                if namespace != nil { Text("Describe").tag(1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if tab == 0 {
                ScrollView {
                    WorkloadFactGrid(tint: tint, facts: facts).padding(12)
                }
            } else if let namespace {
                WorkloadDescribeView(kind: kind, name: name, namespace: namespace)
            }
        }
    }
}
