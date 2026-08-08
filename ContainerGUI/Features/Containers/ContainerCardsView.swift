import SwiftUI
import AppKit

/// Card presentation of the container list — the default view.
///
/// The `Table` is dense and good for scanning many columns, but it says nothing
/// about *how a container is doing*. A card gives each one an identity: a state
/// tile you can read at a glance, live CPU and memory meters, its ports as
/// buttons, and the controls that make sense for its current state.
struct ContainerCardsView: View {
    @Environment(AppModel.self) private var model

    @Binding var selection: String?
    /// Already filtered by the search field in `ContainersView`.
    let containers: [ContainerInfo]
    let onRecreate: (ContainerInfo) -> Void
    let onRemove: (ContainerInfo) -> Void
    let onRemoveProject: (String, [ContainerInfo]) -> Void

    private var store: ContainerStore { model.containers }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(groups) { group in
                    if let project = group.project {
                        ComposeProjectCard(
                            project: project,
                            containers: group.containers,
                            selection: $selection,
                            onRecreate: onRecreate,
                            onRemove: onRemove,
                            onRemoveProject: onRemoveProject
                        )
                    } else {
                        ForEach(group.containers) { container in
                            ContainerCard(
                                container: container,
                                selection: $selection,
                                onRecreate: onRecreate,
                                onRemove: onRemove
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .animation(.smooth(duration: 0.25), value: containers.map(\.id))
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Grouping

    private struct Group: Identifiable {
        let id: String
        let project: String?
        let containers: [ContainerInfo]
    }

    /// Running containers first — they are the ones you act on. Within each
    /// half, and within a project, ordering stays alphabetical so nothing
    /// jumps around as usage fluctuates.
    private static func runningFirst(_ containers: [ContainerInfo]) -> [ContainerInfo] {
        containers.sorted { lhs, rhs in
            lhs.isRunning == rhs.isRunning ? lhs.id < rhs.id : lhs.isRunning
        }
    }

    private var groups: [Group] {
        var byProject: [String: [ContainerInfo]] = [:]
        var loose: [ContainerInfo] = []
        for container in containers {
            if let project = container.composeProject {
                byProject[project, default: []].append(container)
            } else {
                loose.append(container)
            }
        }
        // Projects with something running float above idle ones.
        var result = byProject.keys
            .sorted { lhs, rhs in
                let lhsRunning = byProject[lhs]?.contains(where: \.isRunning) ?? false
                let rhsRunning = byProject[rhs]?.contains(where: \.isRunning) ?? false
                return lhsRunning == rhsRunning ? lhs < rhs : lhsRunning
            }
            .map { project in
                Group(
                    id: "project:\(project)",
                    project: project,
                    containers: Self.runningFirst(byProject[project] ?? [])
                )
            }
        if !loose.isEmpty {
            result.append(Group(id: "loose", project: nil, containers: Self.runningFirst(loose)))
        }
        return result
    }
}

// MARK: - Single container card

struct ContainerCard: View {
    @Environment(AppModel.self) private var model

    let container: ContainerInfo
    @Binding var selection: String?
    let onRecreate: (ContainerInfo) -> Void
    let onRemove: (ContainerInfo) -> Void

    @State private var isHovering = false

    private var store: ContainerStore { model.containers }
    private var isSelected: Bool { selection == container.id }
    private var isPending: Bool { store.pendingIDs.contains(container.id) }
    private var usage: ContainerStore.LiveUsage? { store.liveStats[container.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                stateTile
                identity
                Spacer(minLength: 8)
                if container.isRunning { meters }
                controls
            }
            if !chips.isEmpty {
                chipRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
        .overlay(border)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { selection = isSelected ? nil : container.id }
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.18), value: isSelected)
        .contextMenu { ContainerCardMenu(container: container, onRecreate: onRecreate, onRemove: onRemove) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(format: String(localized: "Kontener %@, stan %@"), container.id, container.state)))
    }

    // MARK: Pieces

    /// The leading tile carries the state — colour plus glyph, so it reads
    /// without relying on colour alone.
    private var stateTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(stateColor.gradient.opacity(container.isRunning ? 1 : 0.35))
                .frame(width: 30, height: 30)
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: container.isRunning ? "shippingbox.fill" : "shippingbox")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: container.isRunning ? stateColor.opacity(0.35) : .clear, radius: 5, y: 2)
        .animation(.smooth(duration: 0.25), value: container.isRunning)
        .animation(.smooth(duration: 0.2), value: isPending)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(container.composeService ?? container.id)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                statePill
            }
            Text(container.imageReference)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var statePill: some View {
        Text(container.state)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(stateColor.opacity(0.15), in: Capsule())
            .foregroundStyle(stateColor)
    }

    /// CPU and memory, drawn as compact bars. Only for running containers —
    /// meters pinned at zero would be noise.
    private var meters: some View {
        HStack(spacing: 10) {
            MeterView(
                label: "CPU",
                value: usage?.cpuPercent.map { min($0 / 100, 1) },
                caption: usage?.cpuPercent.map { String(format: "%.0f%%", $0) },
                tint: .blue
            )
            MeterView(
                label: String(localized: "RAM"),
                value: usage?.memoryFraction,
                caption: usage?.memoryUsedBytes.map { Format.bytes($0) },
                tint: .purple
            )
        }
        .frame(width: 176)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if isPending {
                Color.clear.frame(width: 84, height: 22)
            } else if container.isRunning {
                CardButton(symbol: "stop.fill", help: String(localized: "Zatrzymaj")) {
                    act { try await store.stop(container) }
                }
                CardButton(symbol: "arrow.clockwise", help: String(localized: "Uruchom ponownie")) {
                    act { try await store.restart(container) }
                }
                CardButton(symbol: "terminal", help: String(localized: "Otwórz terminal")) {
                    selection = container.id
                }
            } else {
                CardButton(symbol: "play.fill", help: String(localized: "Uruchom"), tint: .green) {
                    act { try await store.start(container) }
                }
            }
            Menu {
                ContainerCardMenu(container: container, onRecreate: onRecreate, onRemove: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .opacity(isHovering || isSelected || isPending ? 1 : 0.55)
    }

    // MARK: Chips

    private struct Chip: Identifiable {
        let id: String
        let text: String
        let symbol: String?
        let url: URL?
        let help: String?
    }

    private var chips: [Chip] {
        var result: [Chip] = []

        if let ports = container.configuration.publishedPorts {
            for port in ports {
                let reachable = container.isRunning
                    && (port.proto ?? "tcp") == "tcp"
                    && port.hostPort != nil
                result.append(Chip(
                    id: "port-\(port.id)",
                    text: port.display,
                    symbol: reachable ? "arrow.up.forward.app" : "network",
                    url: reachable ? port.hostPort.flatMap { URL(string: "http://localhost:\($0)") } : nil,
                    help: reachable ? String(format: String(localized: "Otwórz http://localhost:%lld w przeglądarce"), port.hostPort ?? 0) : nil
                ))
            }
        }
        if let ip = container.primaryIPv4Address {
            result.append(Chip(id: "ip", text: ip, symbol: "point.topleft.down.to.point.bottomright.curvepath", url: nil, help: String(localized: "Adres IP kontenera")))
        }
        if let arch = container.architecture {
            let rosetta = container.configuration.rosetta == true
            result.append(Chip(
                id: "arch",
                text: rosetta ? "\(arch) + Rosetta" : arch,
                symbol: "cpu",
                url: nil,
                help: rosetta ? String(localized: "Rosetta włączona") : arch
            ))
        }
        if let count = usage?.processCount, container.isRunning {
            result.append(Chip(id: "proc", text: String(format: String(localized: "%lld proc."), Int64(count)), symbol: "list.bullet.rectangle", url: nil, help: nil))
        }
        if container.configuration.readOnly == true {
            result.append(Chip(id: "ro", text: String(localized: "tylko do odczytu"), symbol: "lock.fill", url: nil, help: nil))
        }
        return result
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    if let url = chip.url {
                        Button { NSWorkspace.shared.open(url) } label: { chipLabel(chip) }
                            .buttonStyle(.plain)
                            .help(chip.help ?? "")
                    } else {
                        chipLabel(chip)
                            .help(chip.help ?? "")
                    }
                }
            }
            .padding(.leading, 40)
            .padding(.trailing, 2)
        }
    }

    private func chipLabel(_ chip: Chip) -> some View {
        HStack(spacing: 3) {
            if let symbol = chip.symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .medium))
            }
            Text(chip.text).font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(chip.url == nil ? 0.5 : 0.8), in: Capsule())
        .foregroundStyle(chip.url == nil ? Color.secondary : Color.accentColor)
    }

    // MARK: Chrome

    private var stateColor: Color {
        if isPending { return .orange }
        switch container.state.lowercased() {
        case "running": return .green
        case "stopped", "exited": return .secondary
        default: return .orange
        }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(isHovering ? 0.55 : 0.35)))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                lineWidth: isSelected ? 1.5 : 1
            )
    }

    private func act(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { model.present(error) }
        }
    }
}

// MARK: - Compose project card

struct ComposeProjectCard: View {
    @Environment(AppModel.self) private var model

    let project: String
    let containers: [ContainerInfo]
    @Binding var selection: String?
    let onRecreate: (ContainerInfo) -> Void
    let onRemove: (ContainerInfo) -> Void
    let onRemoveProject: (String, [ContainerInfo]) -> Void

    private var store: ContainerStore { model.containers }
    private var runningCount: Int { containers.filter(\.isRunning).count }
    private var isExpanded: Bool { !store.collapsedProjects.contains(project) }

    var body: some View {
        VStack(spacing: 8) {
            header
            if isExpanded {
                ForEach(containers) { container in
                    ContainerCard(
                        container: container,
                        selection: $selection,
                        onRecreate: onRecreate,
                        onRemove: onRemove
                    )
                    .padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.cyan.opacity(0.18), lineWidth: 1))
        .animation(.smooth(duration: 0.22), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if isExpanded {
                    store.collapsedProjects.insert(project)
                } else {
                    store.collapsedProjects.remove(project)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.cyan.gradient, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text(project)
                    .font(.system(size: 13, weight: .semibold))
                Text(String(format: String(localized: "%lld z %lld działa"), Int64(runningCount), Int64(containers.count)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // A thin progress track reads faster than the "3/5" text alone.
            ProgressView(value: Double(runningCount), total: Double(max(containers.count, 1)))
                .progressViewStyle(.linear)
                .tint(runningCount == containers.count ? .green : .orange)
                .frame(width: 70)

            if runningCount < containers.count {
                CardButton(symbol: "play.fill", help: String(localized: "Uruchom wszystkie"), tint: .green) {
                    Task {
                        for container in containers where !container.isRunning {
                            try? await store.start(container)
                        }
                    }
                }
            }
            if runningCount > 0 {
                CardButton(symbol: "stop.fill", help: String(localized: "Zatrzymaj wszystkie")) {
                    Task {
                        for container in containers where container.isRunning {
                            try? await store.stop(container)
                        }
                    }
                }
            }
            Menu {
                Button("Usuń projekt…", systemImage: "trash", role: .destructive) {
                    onRemoveProject(project, containers)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Small shared pieces

/// A labelled bar. Shows a muted placeholder until the first CPU delta exists,
/// so a card never flashes "0%" before it has measured anything.
struct MeterView: View {
    let label: String
    let value: Double?
    let caption: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 3)
                // A fixed, right-aligned slot. Letting the caption size itself
                // made the whole meter shuffle as soon as the number grew from
                // "0%" to "100%" or from "18 MB" to "1,2 GB".
                Text(caption ?? "—")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(value == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 46, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.7))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(2, geo.size.width * min(max(value ?? 0, 0), 1)))
                }
            }
            .frame(height: 4)
        }
        .frame(width: 83)
        .animation(.smooth(duration: 0.35), value: value)
    }
}

/// Borderless icon button sized for a card's control cluster.
struct CardButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(isHovering ? 0.9 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
    }
}

/// Menu shared by the card's ⋯ button and its context menu.
struct ContainerCardMenu: View {
    @Environment(AppModel.self) private var model

    let container: ContainerInfo
    let onRecreate: (ContainerInfo) -> Void
    let onRemove: (ContainerInfo) -> Void

    private var store: ContainerStore { model.containers }

    var body: some View {
        if container.isRunning {
            Button("Zatrzymaj", systemImage: "stop.fill") { act { try await store.stop(container) } }
            Button("Uruchom ponownie", systemImage: "arrow.clockwise") { act { try await store.restart(container) } }
            Button("Zabij", systemImage: "bolt.fill") { act { try await store.kill(container) } }
        } else {
            Button("Uruchom", systemImage: "play.fill") { act { try await store.start(container) } }
        }
        Divider()
        Button("Zmień polecenie / konfigurację…", systemImage: "slider.horizontal.3") { onRecreate(container) }
        Button("Kopiuj identyfikator", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }
        Divider()
        Button("Usuń…", systemImage: "trash", role: .destructive) { onRemove(container) }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { model.present(error) }
        }
    }
}
