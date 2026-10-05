import SwiftUI
import AppKit

/// List ↔ Topology switch of the Networks section.
enum NetworksViewMode: String, CaseIterable, Identifiable {
    case list
    case topology

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: String(localized: "Lista")
        case .topology: String(localized: "Topologia")
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .topology: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// An interactive diagram of the machines, their engines and the WireGuard
/// tunnels between them — and, one click on a machine deeper, of everything that
/// runs on it.
///
/// Built from the Networks list by `TopologyBuilder` (a pure function, tested).
/// Nodes can be dragged, the canvas panned and zoomed; a node or a tunnel opens
/// a detail panel. Tunnels are green and thick, flow while their handshake is
/// fresh, dim and dash when it is stale, and are thin and dashed when only the
/// overlay membership is known ("unverified").
///
/// Clicking a machine (or its chevron) expands it in place: its containers
/// (status-coloured, with address and ports), the networks they are attached to
/// and, on request, volumes and bind mounts. The layout is recomputed and the
/// change animated by `TopologyTransition`; the machines you dragged stay where
/// you put them.
struct NetworkTopologyView: View {
    let entries: [NetworkEntry]
    let knownMachines: [(label: String, host: String)]
    var containers: [ContainerInfo] = []
    var volumes: [VolumeEntry] = []
    /// "Open in list" on a container: switch to Containers and select it.
    var onOpenContainer: (ContainerInfo) -> Void = { _ in }

    private var labelStore = WireGuardPeerLabelStore.shared
    @State private var editing: WireGuardPeerLabelTarget?

    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    /// Where the user dragged a machine to (absolute); its cluster follows.
    @State private var pinned: [String: CGPoint] = [:]
    @State private var pinStart: [String: CGPoint] = [:]
    /// Where the user dragged any other node to, relative to its laid-out place.
    @State private var offsets: [String: CGSize] = [:]
    @State private var dragStart: [String: CGSize] = [:]
    @State private var selection: Selection?
    @State private var hoveredEdge: String?
    @State private var hoverPoint: CGPoint = .zero
    @State private var viewSize: CGSize = .zero

    // Drill-down.
    @State private var expanded: Set<String> = []
    @State private var expandedMore: Set<String> = []
    @AppStorage("topologyShowVolumes") private var showVolumes = false
    @State private var transition: TopologyTransition?
    @State private var progress: Double = 1
    @State private var localAddresses: [String] = HostAddresses.localIPv4()

    enum Selection: Hashable {
        case node(String)
        case edge(String)
    }

    private var machines: [TopologyMachine] {
        TopologyBuilder.machines(
            from: entries, knownMachines: knownMachines,
            containers: containers, volumes: volumes,
            lanAddresses: localAddresses.isEmpty ? [:] : [.local: localAddresses]
        )
    }

    private var topology: NetworkTopology {
        TopologyBuilder.build(
            machines: machines,
            aliases: labelStore.names,
            notes: labelStore.notes,
            deviceTypes: labelStore.deviceTypes,
            expanded: expanded, expandedMore: expandedMore, showVolumes: showVolumes
        )
    }

    private var effectiveZoom: CGFloat { min(max(zoom * pinch, 0.3), 3) }

    /// The laid-out places of `topology` plus whatever the user dragged.
    private func virtualPositions(_ topology: NetworkTopology) -> [String: CGPoint] {
        var result = TopologyLayout.positions(for: topology, pinned: pinned)
        for (id, point) in result {
            let offset = offsets[id] ?? .zero
            result[id] = CGPoint(x: point.x + offset.width, y: point.y + offset.height)
        }
        return result
    }

    var body: some View {
        let topology = topology
        let virtual = virtualPositions(topology)
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                background(topology: topology, virtual: virtual, center: center)
                TopologyScene(
                    progress: progress, topology: topology, positions: virtual, transition: transition,
                    center: center, pan: pan, zoom: effectiveZoom,
                    selection: selection, hoveredEdge: hoveredEdge, expanded: expanded,
                    tap: { tap($0) },
                    toggle: { toggleExpansion($0.id) },
                    drag: { AnyGesture(nodeDrag($0, topology: topology, positions: virtual)) }
                )
                if let hoveredEdge, let edge = topology.edges.first(where: { $0.id == hoveredEdge }) {
                    edgeTooltip(edge, topology: topology)
                        .position(x: hoverPoint.x + 14, y: hoverPoint.y + 26)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) { controls(topology: topology) }
            .overlay(alignment: .topTrailing) {
                if let selection {
                    TopologyDetailPanel(
                        topology: topology, selection: selection,
                        edit: { editing = $0 },
                        close: { self.selection = nil },
                        openContainer: onOpenContainer
                    )
                    .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) { legend(topology: topology) }
            .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        }
        .background(.background.secondary.opacity(0.3))
        .sheet(item: $editing) { target in WireGuardPeerLabelSheet(target: target) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Topologia sieci"))
    }

    // MARK: Drill-down

    private func tap(_ node: TopologyNode) {
        switch node.kind {
        case .machine:
            selection = .node(node.id)
            if node.machine?.hasDetail == true { toggleExpansion(node.id) }
        case .more:
            change { if !expandedMore.insert(node.id).inserted { expandedMore.remove(node.id) } }
        default:
            selection = selection == .node(node.id) ? nil : .node(node.id)
        }
    }

    private func toggleExpansion(_ machineID: String) {
        let opening = !expanded.contains(machineID)
        change(focus: opening ? machineID : nil) {
            if opening { expanded.insert(machineID) } else { expanded.remove(machineID) }
        }
    }

    private func setShowVolumes(_ on: Bool) {
        change(focus: expanded.count == 1 ? expanded.first : nil) { showVolumes = on }
    }

    private func setAllExpanded(_ open: Bool) {
        let candidates = Set(machines.filter(\.hasDetail).map(\.id))
        change { expanded = open ? candidates : [] }
        if open { fitAll() }
    }

    /// Applies `mutation` to the drill-down state and animates from the diagram
    /// as it was to the one it makes.
    private func change(focus: String? = nil, _ mutation: () -> Void) {
        let before = topology
        let beforePositions = virtualPositions(before)
        mutation()
        let after = topology
        let afterPositions = virtualPositions(after)
        if case .node(let id)? = selection, after.node(id) == nil { selection = nil }
        if let hovered = hoveredEdge, !after.edges.contains(where: { $0.id == hovered }) { hoveredEdge = nil }
        transition = TopologyTransition(from: before, fromPositions: beforePositions, to: after, toPositions: afterPositions)
        progress = 0
        if let focus { focusOn(machine: focus, topology: after, positions: afterPositions) }
        Task { @MainActor in
            // One frame at the old picture first, so there is something to animate from.
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(.easeInOut(duration: 0.55)) { progress = 1 } completion: { transition = nil }
        }
    }

    /// Brings an expanded machine and everything around it into view.
    private func focusOn(machine id: String, topology: NetworkTopology, positions: [String: CGPoint]) {
        let nodes = topology.nodes.filter { $0.id == id || $0.machineID == id }
        fit(nodes, positions: positions, topology: topology)
    }

    private func fitAll() {
        let after = topology
        fit(after.nodes, positions: virtualPositions(after), topology: after)
    }

    private func fit(_ nodes: [TopologyNode], positions: [String: CGPoint], topology: NetworkTopology) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        var box: CGRect?
        for node in nodes {
            guard let point = positions[node.id] else { continue }
            let size = TopologyLayout.nodeSize(node)
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            box = box.map { $0.union(rect) } ?? rect
        }
        guard let box, box.width > 0, box.height > 0 else { return }
        let target = min(max(min((viewSize.width - 80) / box.width, (viewSize.height - 80) / box.height), 0.3), 1.2)
        withAnimation(.easeInOut(duration: 0.55)) {
            zoom = target
            pinch = 1
            pan = CGSize(width: -box.midX * target, height: -box.midY * target)
        }
    }

    // MARK: Coordinates

    private func toVirtual(_ point: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x - pan.width) / effectiveZoom, y: (point.y - center.y - pan.height) / effectiveZoom)
    }

    // MARK: Gestures

    /// Pan, pinch-zoom, edge hover and edge/empty-space click.
    private func background(topology: NetworkTopology, virtual: [String: CGPoint], center: CGPoint) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if panStart == nil { panStart = pan }
                        let start = panStart ?? .zero
                        pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    }
                    .onEnded { _ in panStart = nil }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        zoom = min(max(zoom * value.magnification, 0.3), 3)
                        pinch = 1
                    }
            )
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                let point = toVirtual(location, center: center)
                if let edge = TopologyLayout.nearestEdge(to: point, in: topology, positions: virtual, threshold: 10 / effectiveZoom) {
                    selection = .edge(edge.id)
                } else {
                    selection = nil
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let point = toVirtual(location, center: center)
                    hoverPoint = location
                    hoveredEdge = TopologyLayout.nearestEdge(to: point, in: topology, positions: virtual, threshold: 8 / effectiveZoom)?.id
                case .ended:
                    hoveredEdge = nil
                }
            }
    }

    /// A machine is pinned where it is dropped and takes its cluster along; any
    /// other node is nudged away from its laid-out place.
    private func nodeDrag(_ node: TopologyNode, topology: NetworkTopology, positions: [String: CGPoint]) -> some Gesture<DragGesture.Value> {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let dx = value.translation.width / effectiveZoom, dy = value.translation.height / effectiveZoom
                if node.kind == .machine {
                    if pinStart[node.id] == nil { pinStart[node.id] = positions[node.id] ?? .zero }
                    let start = pinStart[node.id] ?? .zero
                    pinned[node.id] = CGPoint(x: start.x + dx, y: start.y + dy)
                } else {
                    if dragStart[node.id] == nil { dragStart[node.id] = offsets[node.id] ?? .zero }
                    let start = dragStart[node.id] ?? .zero
                    offsets[node.id] = CGSize(width: start.width + dx, height: start.height + dy)
                }
            }
            .onEnded { _ in
                dragStart = [:]
                pinStart = [:]
            }
    }

    // MARK: Chrome

    private func edgeTooltip(_ edge: TopologyEdge, topology: NetworkTopology) -> some View {
        let a = topology.node(edge.a)?.title ?? edge.a, b = topology.node(edge.b)?.title ?? edge.b
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(a) ↔ \(b)").font(.caption.weight(.semibold))
            ForEach(Array(edge.links.enumerated()), id: \.offset) { _, link in
                if let label = link.label {
                    Label("\(label) (\(WireGuardFormat.shortKey(link.peer.publicKey)))", systemImage: "tag")
                        .font(.caption2)
                    if let note = link.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if edge.verification == .unverified {
                Text("niezweryfikowane").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(String(format: String(localized: "Ostatni handshake: %@"), WireGuardFormat.handshake(edge.latestHandshake)))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: String(localized: "Transfer: ↓ %@ ↑ %@"), WireGuardFormat.bytes(edge.rxBytes), WireGuardFormat.bytes(edge.txBytes)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.chip))
        .fixedSize()
    }

    private func controls(topology: NetworkTopology) -> some View {
        let expandable = topology.machines.contains { $0.machine?.hasDetail == true }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                IconButton(symbol: "minus.magnifyingglass", description: String(localized: "Oddal")) { zoom = max(zoom / 1.25, 0.3) }
                IconButton(symbol: "plus.magnifyingglass", description: String(localized: "Przybliż")) { zoom = min(zoom * 1.25, 3) }
                IconButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", description: String(localized: "Resetuj widok")) {
                    zoom = 1; pinch = 1; pan = .zero; offsets = [:]; pinned = [:]
                }
                if expandable {
                    Divider().frame(height: 14)
                    IconButton(symbol: "arrow.up.left.and.arrow.down.right", description: String(localized: "Rozwiń wszystkie maszyny")) { setAllExpanded(true) }
                    IconButton(symbol: "arrow.down.right.and.arrow.up.left", description: String(localized: "Zwiń wszystkie maszyny")) { setAllExpanded(false) }
                        .disabled(expanded.isEmpty)
                }
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
            if expandable {
                Toggle(String(localized: "Pokaż wolumeny"), isOn: Binding(get: { showVolumes }, set: { setShowVolumes($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .help(String(localized: "Pokaż wolumeny i montowania katalogów używane przez kontenery rozwiniętych maszyn"))
            }
        }
        .padding(10)
    }

    private func legend(topology: NetworkTopology) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            legendRow(String(localized: "Tunel WireGuard (świeży handshake)"), dash: [10, 7], opacity: 1, width: 3)
            legendRow(String(localized: "Tunel bez świeżego handshake"), dash: [6, 7], opacity: 0.4, width: 2.5)
            legendRow(String(localized: "Niezweryfikowane (brak uprawnień do peerów)"), dash: [2, 6], opacity: 0.6, width: 1.6)
            if !expanded.isEmpty {
                Divider().padding(.vertical, 2)
                HStack(spacing: 10) {
                    legendDot(.green, String(localized: "działa"))
                    legendDot(.gray, String(localized: "zatrzymany"))
                    legendDot(.teal, String(localized: "sieć"))
                    if showVolumes { legendDot(.orange, String(localized: "wolumen")) }
                }
                Text("Linia: kontener ↔ sieć, do której jest podłączony").foregroundStyle(.tertiary)
            } else if topology.machines.contains(where: { $0.machine?.hasDetail == true }) {
                Divider().padding(.vertical, 2)
                Label(String(localized: "Kliknij maszynę, aby zobaczyć jej kontenery i sieci"), systemImage: "cursorarrow.click")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.chip))
        .padding(10)
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    private func legendRow(_ text: String, dash: [CGFloat], opacity: Double, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 28, y: 4))
            }
            .stroke(Color.green.opacity(opacity), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            .frame(width: 28, height: 8)
            Text(text)
        }
    }
}

// MARK: - Scene

/// Edges and nodes at one instant of the expand/collapse animation. `progress`
/// is the animatable value: SwiftUI feeds it frame by frame while the transition
/// runs and the scene asks `TopologyTransition` where everything is by then.
private struct TopologyScene: View, @preconcurrency Animatable {
    var progress: Double
    let topology: NetworkTopology
    /// Virtual positions of the settled `topology`.
    let positions: [String: CGPoint]
    let transition: TopologyTransition?
    let center: CGPoint
    let pan: CGSize
    let zoom: CGFloat
    let selection: NetworkTopologyView.Selection?
    let hoveredEdge: String?
    let expanded: Set<String>
    let tap: (TopologyNode) -> Void
    let toggle: (TopologyNode) -> Void
    let drag: (TopologyNode) -> AnyGesture<DragGesture.Value>

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private struct Placed {
        let node: TopologyNode
        let point: CGPoint
        let opacity: Double
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: center.x + pan.width + point.x * zoom, y: center.y + pan.height + point.y * zoom)
    }

    var body: some View {
        let frame = transition?.frame(at: progress)
        let placed: [Placed] = frame.map { frame in
            frame.nodes.map { Placed(node: $0.node, point: screen($0.point), opacity: $0.opacity) }
        } ?? topology.nodes.compactMap { node in positions[node.id].map { Placed(node: node, point: screen($0), opacity: 1) } }
        let edges: [(edge: TopologyEdge, opacity: Double)] = frame.map { frame in
            frame.edges.map { ($0.edge, $0.opacity) }
        } ?? topology.edges.map { ($0, 1) }
        let points = Dictionary(placed.map { ($0.node.id, $0.point) }, uniquingKeysWith: { first, _ in first })
        // Nodes that are neither the selection nor linked to it fade back.
        let focus = focusedIDs()
        ZStack {
            edgesLayer(edges: edges, points: points, focus: focus)
                .allowsHitTesting(false)
            ForEach(placed, id: \.node.id) { item in
                TopologyNodeView(
                    node: item.node, isHub: item.node.id == topology.hubID,
                    isSelected: selection == .node(item.node.id),
                    isExpanded: expanded.contains(item.node.id),
                    toggle: { toggle(item.node) }
                )
                .opacity(item.opacity * ((focus?.contains(item.node.id) ?? true) ? 1 : 0.35))
                .scaleEffect(0.5 + 0.5 * item.opacity)
                .position(item.point)
                .onTapGesture { tap(item.node) }
                .gesture(drag(item.node))
                .allowsHitTesting(item.opacity > 0.6)
            }
        }
    }

    /// With a container, network or volume selected: it, the nodes linked to it
    /// and their engines. `nil` means no focus (everything at full strength).
    private func focusedIDs() -> Set<String>? {
        guard case .node(let id)? = selection, let node = topology.node(id),
              [.container, .network, .volume].contains(node.kind) else { return nil }
        var ids: Set<String> = [id]
        for edge in topology.edges where edge.kind == .attached || edge.kind == .mount {
            if edge.a == id { ids.insert(edge.b) }
            if edge.b == id { ids.insert(edge.a) }
        }
        if let parent = node.parentID { ids.insert(parent) }
        if let machine = node.machineID { ids.insert(machine) }
        for linked in ids { if let parent = topology.node(linked)?.parentID { ids.insert(parent) } }
        return ids
    }

    // MARK: Edges

    private func edgesLayer(edges: [(edge: TopologyEdge, opacity: Double)], points: [String: CGPoint], focus: Set<String>?) -> some View {
        let animated = topology.edges.contains { $0.kind == .wireGuard && $0.verification == .verified && !$0.isStale() }
        let selectedNode: String? = { if case .node(let id)? = selection { return id } else { return nil } }()
        return TimelineView(.animation(minimumInterval: animated ? 1.0 / 24 : 60)) { timeline in
            Canvas { context, _ in
                let now = timeline.date
                let phase = CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)) * 18
                // Structure underneath, connections above, tunnels on top.
                func layer(_ kind: TopologyEdge.Kind) -> Int {
                    switch kind {
                    case .hosts, .contains: 0
                    case .attached, .mount: 1
                    case .wireGuard: 2
                    }
                }
                for item in edges.sorted(by: { layer($0.edge.kind) < layer($1.edge.kind) }) {
                    let edge = item.edge
                    guard let a = points[edge.a], let b = points[edge.b] else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    let emphasised = selection == .edge(edge.id) || hoveredEdge == edge.id
                    let touchesSelection = selectedNode.map { edge.a == $0 || edge.b == $0 } ?? false
                    var inner = context
                    inner.opacity = item.opacity * ((focus == nil || touchesSelection || edge.kind == .hosts || edge.kind == .wireGuard
                                                     || (focus?.contains(edge.a) == true && focus?.contains(edge.b) == true)) ? 1 : 0.25)
                    draw(edge: edge, path: path, from: a, to: b, phase: phase, emphasised: emphasised || touchesSelection, now: now, in: &inner)
                }
            }
        }
    }

    private func draw(
        edge: TopologyEdge, path: Path, from a: CGPoint, to b: CGPoint,
        phase: CGFloat, emphasised: Bool, now: Date, in context: inout GraphicsContext
    ) {
        switch edge.kind {
        case .hosts:
            context.stroke(path, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1.2))
        case .contains:
            context.stroke(path, with: .color(.secondary.opacity(0.28)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        case .attached:
            context.stroke(path, with: .color(.teal.opacity(emphasised ? 0.95 : 0.5)),
                           style: StrokeStyle(lineWidth: emphasised ? 2.4 : 1.4, lineCap: .round))
            if emphasised, let detail = edge.detail {
                label(detail, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: .teal, in: &context)
            }
        case .mount:
            context.stroke(path, with: .color(.orange.opacity(emphasised ? 0.95 : 0.5)),
                           style: StrokeStyle(lineWidth: emphasised ? 2.2 : 1.2, lineCap: .round, dash: [3, 4]))
        case .wireGuard:
            let width = 3.5 * min(max(zoom, 0.8), 1.6)
            if edge.verification == .unverified {
                context.stroke(path, with: .color(.green.opacity(emphasised ? 0.9 : 0.55)),
                               style: StrokeStyle(lineWidth: emphasised ? 2.5 : 1.6, lineCap: .round, dash: [2, 6]))
            } else if edge.isStale(now: now) {
                context.stroke(path, with: .color(.green.opacity(emphasised ? 0.7 : 0.32)),
                               style: StrokeStyle(lineWidth: width * 0.8, lineCap: .round, dash: [6, 7]))
            } else {
                // Soft glow, then a dash pattern that flows towards the peer.
                context.stroke(path, with: .color(.green.opacity(0.18)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
                context.stroke(path, with: .color(.green),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [10, 7], dashPhase: -phase))
            }
            if emphasised {
                context.stroke(path, with: .color(.accentColor.opacity(0.35)), style: StrokeStyle(lineWidth: width + 8, lineCap: .round))
            }
            let text = edge.verification == .unverified ? String(localized: "niezweryfikowane") : WireGuardFormat.handshake(edge.latestHandshake, now: now)
            let tint: Color = edge.isStale(now: now) || edge.verification == .unverified ? .secondary : .primary
            label(text, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: tint, in: &context)
        }
    }

    private func label(_ text: String, at mid: CGPoint, color: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.caption2).foregroundColor(color))
        let size = resolved.measure(in: CGSize(width: 220, height: 40))
        let box = CGRect(x: mid.x - size.width / 2 - 5, y: mid.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        context.draw(resolved, at: mid)
    }
}

// MARK: - Node

private struct TopologyNodeView: View {
    let node: TopologyNode
    let isHub: Bool
    let isSelected: Bool
    var isExpanded: Bool = false
    var toggle: () -> Void = {}

    var body: some View {
        Group {
            switch node.kind {
            case .machine: machine
            case .runtime: runtime
            case .unknownPeer: unknown
            case .container: container
            case .network: network
            case .volume: volume
            case .more: more
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.panel + 2)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
            }
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(tooltip))
    }

    private var machine: some View {
        let isLocal = node.machine?.key == .local
        return HStack(spacing: 8) {
            Image(systemName: (node.deviceType ?? (isLocal ? .laptop : .server)).symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background((isLocal ? Color.indigo : Color.orange).gradient, in: RoundedRectangle(cornerRadius: Radius.card))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if node.label != nil { Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary) }
                    if isHub { SourceChip(text: String(localized: "Hub"), tint: .green) }
                }
                if let line = addressLine {
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if isExpanded, let line = lanLine {
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let machine = node.machine, !machine.containers.isEmpty {
                    Text(String(format: String(localized: "%lld/%lld działa"), Int64(machine.runningCount), Int64(machine.containers.count)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if node.machine?.hasDetail == true {
                IconButton(
                    symbol: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle",
                    description: isExpanded ? String(localized: "Zwiń maszynę") : String(localized: "Rozwiń maszynę"),
                    action: toggle
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(isExpanded ? AnyShapeStyle(Color.accentColor.opacity(0.5)) : AnyShapeStyle(.quaternary)))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var addressLine: String? {
        let addresses = node.machine?.overlayAddresses ?? []
        return addresses.isEmpty ? nil : addresses.joined(separator: ", ")
    }

    private var lanLine: String? {
        let addresses = node.machine?.networkAddresses ?? []
        return addresses.isEmpty ? nil : "LAN " + addresses.joined(separator: ", ")
    }

    private var runtime: some View {
        VStack(spacing: 0) {
            Text(node.title).font(.caption.weight(.medium))
            if let subtitle = node.subtitle {
                Text(subtitle).font(.caption2).opacity(0.8)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, node.subtitle == nil ? 4 : 3)
        .background(Color.cyan.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.5)))
        .foregroundStyle(Color.cyan)
    }

    private var container: some View {
        let state = node.container?.topologyState ?? .stopped
        let tint: Color = switch state {
        case .running: .green
        case .stopped: .gray
        case .other: .orange
        }
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.title).font(.caption.weight(.semibold)).lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 150, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(tint.opacity(state == .stopped ? 0.25 : 0.55)))
        .shadow(color: .black.opacity(state == .stopped ? 0 : 0.1), radius: 3, y: 1)
        .opacity(state == .stopped ? 0.55 : 1)
    }

    private var network: some View {
        HStack(spacing: 5) {
            Image(systemName: "network").font(.caption2)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.title).font(.caption.weight(.medium)).lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption2.monospaced()).opacity(0.8).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: 140, alignment: .leading)
        .background(Color.teal.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.teal.opacity(0.5)))
        .foregroundStyle(Color.teal)
    }

    private var volume: some View {
        HStack(spacing: 4) {
            Image(systemName: node.volume?.isBind == true ? "folder" : "externaldrive").font(.caption2)
            Text(node.title).font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 130, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color.orange.opacity(0.45)))
        .foregroundStyle(Color.orange)
    }

    private var more: some View {
        HStack(spacing: 4) {
            Image(systemName: node.isMoreExpanded ? "minus" : "plus").font(.caption2.weight(.bold))
            Text(node.title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .foregroundStyle(.secondary)
    }

    private var unknown: some View {
        VStack(spacing: 2) {
            Image(systemName: node.deviceType?.symbol ?? "questionmark")
                .font(.body.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(.secondary))
            HStack(spacing: 3) {
                Text(node.title).font(.caption2.weight(.medium)).lineLimit(1)
                if node.label != nil { Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary) }
            }
            if let subtitle = node.subtitle {
                Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(4)
    }

    private var tooltip: String {
        switch node.kind {
        case .machine:
            let runtimes = (node.machine?.engines ?? []).map(\.title).joined(separator: ", ")
            return [node.title, labelledAutoName, addressLine, lanLine, runtimes.isEmpty ? nil : runtimes, node.note]
                .compactMap { $0 }.joined(separator: " · ")
        case .runtime: return [node.title, node.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .unknownPeer: return [node.title, node.subtitle, node.note].compactMap { $0 }.joined(separator: " · ")
        case .container:
            return [node.title, node.container?.imageReference, node.container?.state, node.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .network: return [node.title, node.network?.driver, node.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .volume: return [node.volume?.name, node.volume?.path].compactMap { $0 }.joined(separator: " · ")
        case .more: return node.title
        }
    }

    /// "(Mac Studio)" after a label, so the machine behind it is still named.
    private var labelledAutoName: String? {
        guard node.label != nil, let auto = node.autoTitle, auto != node.title else { return nil }
        return "(\(auto))"
    }
}

// MARK: - Details

private struct TopologyDetailPanel: View {
    let topology: NetworkTopology
    let selection: NetworkTopologyView.Selection
    let edit: (WireGuardPeerLabelTarget) -> Void
    let close: () -> Void
    var openContainer: (ContainerInfo) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).lineLimit(2)
                Spacer()
                IconButton(symbol: "xmark", description: String(localized: "Zamknij"), action: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { content }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(width: 290)
        .frame(maxHeight: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private var title: String {
        switch selection {
        case .node(let id): topology.node(id)?.title ?? ""
        case .edge(let id):
            topology.edges.first { $0.id == id }.map { edge in
                "\(topology.node(edge.a)?.title ?? edge.a) ↔ \(topology.node(edge.b)?.title ?? edge.b)"
            } ?? ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .node(let id):
            if let node = topology.node(id) { nodeDetails(node) }
        case .edge(let id):
            if let edge = topology.edges.first(where: { $0.id == id }) { edgeDetails(edge) }
        }
    }

    @ViewBuilder
    private func nodeDetails(_ node: TopologyNode) -> some View {
        switch node.kind {
        case .machine:
            if let machine = node.machine {
                deviceTypePicker(for: node)
                if node.label != nil, let auto = node.autoTitle { row(String(localized: "Nazwa maszyny"), auto) }
                if let note = node.note { row(String(localized: "Notatka"), note) }
                row(String(localized: "Maszyna"), machine.key == .local ? ContainerLocation.local.title : ContainerLocation.external.title)
                if !machine.overlayAddresses.isEmpty {
                    row(String(localized: "Adres WireGuard"), machine.overlayAddresses.joined(separator: ", "))
                }
                if !machine.networkAddresses.isEmpty {
                    row(String(localized: "Adresy LAN"), machine.networkAddresses.joined(separator: ", "))
                }
                if machine.hasDetail {
                    row(String(localized: "Kontenery"), String(format: String(localized: "%lld/%lld działa"), Int64(machine.runningCount), Int64(machine.containers.count)))
                }
                if !machine.engines.isEmpty {
                    row(String(localized: "Silniki"), machine.engines.map(\.title).joined(separator: ", "))
                }
                ForEach(machine.engines, id: \.self) { engine in
                    if let names = machine.networkNames[engine], !names.isEmpty {
                        row(String(format: String(localized: "Sieci %@"), engine.title), names.joined(separator: ", "))
                    }
                }
                ForEach(machine.interfaces, id: \.name) { interface in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: String(localized: "Interfejs WireGuard: %@"), interface.name)).fontWeight(.semibold)
                        if let port = interface.listenPort { Text("Port nasłuchu: \(port)") }
                        if let key = interface.publicKey {
                            Text(String(format: String(localized: "Klucz publiczny: %@"), WireGuardFormat.shortKey(key))).help(key)
                        }
                        if interface.source == .dump {
                            Text("Peery (\(interface.peers.count))")
                        } else if interface.peerDetailsNeedRoot {
                            Label(String(localized: "Szczegóły peerów wymagają roota"), systemImage: "info.circle").foregroundStyle(.orange)
                        }
                    }
                }
                if !node.peerKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Etykiety peerów").foregroundStyle(.secondary)
                        ForEach(node.peerKeys, id: \.self) { key in
                            keyLabelRow(key: key, autoName: node.autoTitle)
                        }
                    }
                }
                let links = topology.edges.filter { $0.kind == .wireGuard && ($0.a == node.id || $0.b == node.id) }
                if !links.isEmpty {
                    row(String(localized: "Tunele"), links.map { edge in
                        let other = edge.a == node.id ? edge.b : edge.a
                        return topology.node(other)?.title ?? other
                    }.joined(separator: ", "))
                }
            }
        case .runtime:
            if let machineID = node.machineID, let machine = topology.node(machineID) {
                row(String(localized: "Maszyna"), machine.title)
            }
            if let engine = node.engine, let machine = node.machineID.flatMap({ topology.node($0)?.machine }) {
                let mine = machine.containers.filter { $0.engine == engine }
                if !mine.isEmpty {
                    row(String(localized: "Kontenery"), String(format: String(localized: "%lld/%lld działa"), Int64(mine.filter(\.isRunning).count), Int64(mine.count)))
                }
                if let names = machine.networkNames[engine], !names.isEmpty {
                    row(String(localized: "Sieci kontenerów"), names.joined(separator: ", "))
                }
            }
        case .container:
            if let container = node.container { containerDetails(container, node: node) }
        case .network:
            if let network = node.network { networkDetails(network, node: node) }
        case .volume:
            if let volume = node.volume { volumeDetails(volume, node: node) }
        case .more:
            EmptyView()
        case .unknownPeer:
            if let peer = node.peer {
                Text(String(localized: "Peer nie pasuje do żadnej znanej maszyny.")).foregroundStyle(.secondary)
                peerDetails(peer, label: node.label, note: node.note, autoName: nil)
            }
        }
    }

    private func owner(of node: TopologyNode) -> String {
        [node.machineID.flatMap { topology.node($0)?.title }, node.engine?.title].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func containerDetails(_ container: ContainerInfo, node: TopologyNode) -> some View {
        let tint: Color = switch container.topologyState {
        case .running: .green
        case .stopped: .gray
        case .other: .orange
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("Stan").foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(container.state)
            }
        }
        row(String(localized: "Obraz"), container.imageReference)
        row(String(localized: "Maszyna"), owner(of: node))
        if let project = container.composeProject {
            row(String(localized: "Projekt Compose"), project + (container.composeService.map { " / \($0)" } ?? ""))
        }
        let addresses = container.networkAddresses
        if !addresses.isEmpty {
            row(String(localized: "Adresy IP"), addresses.map { $0.network.isEmpty ? $0.address : "\($0.address)  (\($0.network))" }.joined(separator: "\n"))
        }
        let networks = container.attachedNetworkNames
        if !networks.isEmpty { row(String(localized: "Sieci"), networks.joined(separator: ", ")) }
        let ports = (container.configuration.publishedPorts ?? []).map(\.display)
        if !ports.isEmpty { row(String(localized: "Porty"), ports.joined(separator: "\n")) }
        let mounts = container.configuration.mounts ?? []
        if !mounts.isEmpty {
            row(String(localized: "Montowania"), mounts.map { "\($0.preferredSource ?? "?") → \($0.destination ?? "?")" }.joined(separator: "\n"))
        }
        Button { openContainer(container) } label: {
            Label(String(localized: "Otwórz na liście"), systemImage: "list.bullet")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    @ViewBuilder
    private func networkDetails(_ network: NetworkEntry, node: TopologyNode) -> some View {
        row(String(localized: "Maszyna"), owner(of: node))
        if let driver = network.driver { row(String(localized: "Sterownik"), driver) }
        if let subnet = network.ipv4Subnet { row(String(localized: "Podsieć"), subnet) }
        if let gateway = network.ipv4Gateway { row(String(localized: "Brama"), gateway) }
        if let subnet = network.ipv6Subnet { row(String(localized: "Podsieć IPv6"), subnet) }
        if network.isInternal { Label(String(localized: "Sieć wewnętrzna"), systemImage: "lock").foregroundStyle(.secondary) }
        let members = topology.edges.filter { $0.kind == .attached && ($0.a == node.id || $0.b == node.id) }
            .compactMap { edge -> String? in
                let other = topology.node(edge.a == node.id ? edge.b : edge.a)
                guard let name = other?.title else { return nil }
                return edge.detail.map { "\(name)  \($0)" } ?? name
            }
        if !members.isEmpty { row(String(localized: "Podłączone kontenery"), members.joined(separator: "\n")) }
    }

    @ViewBuilder
    private func volumeDetails(_ volume: VolumeEntry, node: TopologyNode) -> some View {
        row(String(localized: "Maszyna"), owner(of: node))
        row(String(localized: "Rodzaj"), volume.isBind ? String(localized: "Montowanie katalogu (bind)") : String(localized: "Wolumen"))
        if let path = volume.path { row(String(localized: "Ścieżka"), path) }
        if let driver = volume.driver { row(String(localized: "Sterownik"), driver) }
        if let size = volume.sizeBytes { row(String(localized: "Rozmiar"), WireGuardFormat.bytes(size)) }
        if !volume.usedBy.isEmpty { row(String(localized: "Używany przez"), volume.usedBy.joined(separator: ", ")) }
    }

    /// "Device type" menu of a machine node: Auto plus the eleven types. The choice
    /// is stored under each of the machine's public keys (or the node id when it
    /// has none), so the peer rows that resolve to this machine show it too.
    private func deviceTypePicker(for node: TopologyNode) -> some View {
        let store = WireGuardPeerLabelStore.shared
        let binding = Binding<PeerDeviceType?>(
            get: { node.deviceTypeKeys.lazy.compactMap { store.deviceType(for: $0) }.first },
            set: { store.setDeviceType($0, for: node.deviceTypeKeys) }
        )
        return HStack(spacing: 6) {
            Text("Typ urządzenia").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            PeerDeviceTypePicker(selection: binding)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func edgeDetails(_ edge: TopologyEdge) -> some View {
        if edge.verification == .unverified {
            Label(String(localized: "Niezweryfikowane — odczyt peerów wymaga roota; połączenie wywnioskowano z adresów w tej samej sieci."), systemImage: "info.circle")
                .foregroundStyle(.orange)
            if let overlay = edge.overlay { row(String(localized: "Sieć nakładkowa"), overlay) }
        } else {
            row(String(localized: "Handshake"), WireGuardFormat.handshake(edge.latestHandshake))
            if edge.isStale() {
                Label(String(localized: "Brak świeżego handshake (ponad 3 min)"), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
            }
            row(String(localized: "Transfer"), "↓ \(WireGuardFormat.bytes(edge.rxBytes)) ↑ \(WireGuardFormat.bytes(edge.txBytes))")
            if let keepalive = edge.keepalive {
                row(String(localized: "Keepalive"), String(format: String(localized: "co %lld s"), Int64(keepalive)))
            }
            ForEach(Array(edge.links.enumerated()), id: \.offset) { _, link in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "Zgłasza: %@"), topology.node(link.reporterID)?.title ?? link.reporterID))
                        .fontWeight(.semibold)
                    peerDetails(link.peer, label: link.label, note: link.note, autoName: autoName(for: link, in: edge))
                }
            }
        }
        let kinds = [edge.a, edge.b].compactMap { topology.node($0) }
        ForEach(kinds.filter { $0.kind == .machine }, id: \.id) { node in
            if let machine = node.machine, !machine.engines.isEmpty {
                row(node.title, machine.engines.map(\.title).joined(separator: ", "))
            }
        }
    }

    /// The machine a reported peer resolved to: the edge end that is not the reporter.
    private func autoName(for link: TopologyLink, in edge: TopologyEdge) -> String? {
        let other = edge.a == link.reporterID ? edge.b : edge.a
        guard let node = topology.node(other), node.kind == .machine else { return nil }
        return node.autoTitle ?? node.title
    }

    /// One identifying key of a machine: its label (or the key) and an Edit button.
    private func keyLabelRow(key: String, autoName: String?) -> some View {
        let store = WireGuardPeerLabelStore.shared
        return HStack(spacing: 6) {
            if let label = store.label(for: key) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                Text(label).fontWeight(.semibold)
            }
            Text(WireGuardFormat.shortKey(key)).font(.caption.monospaced()).help(key)
            Spacer(minLength: 0)
            PeerLabelEditButton { edit(WireGuardPeerLabelTarget(peer: peerStub(key: key), autoName: autoName)) }
        }
    }

    /// The peer record for a key, from whichever dump lists it; an interface's own key has none.
    private func peerStub(key: String) -> WireGuardPeer {
        for node in topology.nodes {
            for interface in node.machine?.interfaces ?? [] {
                if let peer = interface.peers.first(where: { $0.publicKey == key }) { return peer }
            }
        }
        return WireGuardPeer(publicKey: key, endpoint: nil, allowedIPs: [], latestHandshake: nil, rxBytes: 0, txBytes: 0, keepalive: nil)
    }

    @ViewBuilder
    private func peerDetails(_ peer: WireGuardPeer, label: String?, note: String?, autoName: String?) -> some View {
        Text(String(format: String(localized: "Klucz publiczny: %@"), WireGuardFormat.shortKey(peer.publicKey))).help(peer.publicKey)
        HStack(spacing: 6) {
            if let label {
                Label(label, systemImage: "tag").fontWeight(.semibold)
            } else {
                Text("Brak etykiety").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            PeerLabelEditButton { edit(WireGuardPeerLabelTarget(peer: peer, autoName: autoName)) }
        }
        if let note { Text(note).foregroundStyle(.secondary) }
        if let type = WireGuardPeerLabelStore.shared.deviceType(for: peer.publicKey) {
            Label(type.title, systemImage: type.symbol)
        }
        Text(String(format: String(localized: "Dozwolone IP: %@"), peer.allowedIPs.isEmpty ? "—" : peer.allowedIPs.joined(separator: ", ")))
        Text("Endpoint: \(peer.endpoint ?? "—")")
        Text(String(format: String(localized: "Ostatni handshake: %@"), WireGuardFormat.handshake(peer.latestHandshake)))
        Text(String(format: String(localized: "Transfer: ↓ %@ ↑ %@"), WireGuardFormat.bytes(peer.rxBytes), WireGuardFormat.bytes(peer.txBytes)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
