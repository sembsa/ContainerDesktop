import Foundation
import CoreGraphics

/// Layout of what an expanded machine adds around it, relative to the machine.
///
/// Concentric, so the diagram reads from the inside out: the machine, its engines,
/// the engines' containers in staggered tiers (one wedge per engine), then the
/// networks (each at the mean direction of the containers attached to it), then
/// the volumes. Pure and deterministic; the numbers are in points of the virtual
/// plane the rest of `TopologyLayout` uses.
enum TopologyClusterLayout {
    static let engineRadius = 150.0
    static let firstTier = 285.0
    static let tierStep = 72.0
    /// Arc length reserved per container along a tier.
    static let itemSpacing = 160.0
    static let networkGap = 175.0
    static let volumeGap = 135.0
    static let marginAfterLastRing = 75.0

    struct Result: Sendable {
        /// Offsets from the machine's centre.
        var offsets: [String: CGPoint]
        /// Distance from the machine's centre to the outer edge of the cluster.
        var radius: Double
    }

    /// `span` is the angle the cluster may fan out over (2π around a hub or a
    /// lone machine, less for a machine out on the circle, whose inner side
    /// holds the tunnels), pointing towards `orientation` (radians, 0 = +x, y
    /// down). `nil` when the machine has nothing but engines.
    static func compute(machineID: String, in topology: NetworkTopology, span: Double, orientation: Double = 0) -> Result? {
        let drill = topology.drillDownNodes(of: machineID)
        guard !drill.isEmpty else { return nil }
        let engines = topology.nodes.filter { $0.kind == .runtime && $0.machineID == machineID }
        var offsets: [String: CGPoint] = [:]
        let start = -span / 2

        func point(_ radius: Double, _ angle: Double) -> CGPoint { CGPoint(x: cos(angle) * radius, y: sin(angle) * radius) }

        // Containers (and the "+K more" of that list), engine after engine.
        var items: [TopologyNode] = []
        for engine in engines {
            items.append(contentsOf: drill.filter { $0.parentID == engine.id && ($0.kind == .container || ($0.kind == .more && $0.moreCategory == .containers)) })
        }
        var angles: [String: Double] = [:]
        var outer = 0.0
        let tiers = tierCounts(for: items.count, span: span)
        if !tiers.isEmpty {
            // Hand items to tiers so each tier holds items from the whole list,
            // evenly: engines then keep a wedge across all tiers.
            var lists = Array(repeating: [TopologyNode](), count: tiers.count)
            var assigned = Array(repeating: 0, count: tiers.count)
            for (index, item) in items.enumerated() {
                var best = -1
                var bestDeficit = -Double.infinity
                for tier in tiers.indices where assigned[tier] < tiers[tier] {
                    let deficit = Double(tiers[tier]) * Double(index + 1) / Double(items.count) - Double(assigned[tier])
                    if deficit > bestDeficit + 1e-9 { best = tier; bestDeficit = deficit }
                }
                lists[best].append(item)
                assigned[best] += 1
            }
            for (tier, list) in lists.enumerated() where !list.isEmpty {
                let radius = firstTier + Double(tier) * tierStep
                outer = max(outer, radius)
                for (index, item) in list.enumerated() {
                    // Odd tiers sit between the even ones, so neighbours in
                    // adjacent tiers never line up.
                    let fraction = tier % 2 == 0
                        ? (Double(index) + 0.5) / Double(list.count)
                        : (Double(index) + 1) / Double(list.count + 1)
                    let angle = start + span * fraction
                    angles[item.id] = angle
                    offsets[item.id] = point(radius, angle)
                }
            }
        }

        // Engines at the middle of their containers, or in an equal share.
        var engineAngles: [String: Double] = [:]
        let weights = engines.map { engine in Double(max(items.filter { $0.parentID == engine.id }.count, 1)) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var cumulative = 0.0
        for (index, engine) in engines.enumerated() {
            let mine = items.filter { $0.parentID == engine.id }.compactMap { angles[$0.id] }
            if mine.isEmpty {
                engineAngles[engine.id] = start + span * (cumulative + weights[index] / 2) / totalWeight
            } else {
                engineAngles[engine.id] = mine.reduce(0, +) / Double(mine.count)
            }
            cumulative += weights[index]
        }
        let engineIDs = engines.map(\.id)
        let spreadEngines = spread(engineIDs.map { engineAngles[$0] ?? 0 }, minGap: 96 / engineRadius, circular: span >= 2 * .pi - 0.01)
        for (index, id) in engineIDs.enumerated() {
            engineAngles[id] = spreadEngines[index]
            offsets[id] = point(engineRadius, spreadEngines[index])
        }
        outer = max(outer, engineRadius)

        // A ring of nodes each wanting a direction: networks, then volumes.
        func ring(_ nodes: [TopologyNode], baseRadius: Double, width: Double, wanted: (TopologyNode) -> Double) -> Double {
            guard !nodes.isEmpty else { return baseRadius }
            let capacity = max(1, Int(baseRadius * span / width))
            let staggered = nodes.count > capacity
            let order = nodes.indices.sorted { wanted(nodes[$0]) < wanted(nodes[$1]) }
            let wantedAngles = order.map { wanted(nodes[$0]) }
            let gap = (staggered ? width / 2 : width) / baseRadius
            let placed = spread(wantedAngles, minGap: gap, circular: span >= 2 * .pi - 0.01)
            for (rank, index) in order.enumerated() {
                let radius = baseRadius + (staggered && rank % 2 == 1 ? tierStep : 0)
                offsets[nodes[index].id] = point(radius, placed[rank])
            }
            return baseRadius + (staggered ? tierStep : 0)
        }

        func meanAngle(of node: TopologyNode, kind: TopologyEdge.Kind) -> Double {
            let linked = topology.edges.filter { $0.kind == kind && ($0.a == node.id || $0.b == node.id) }
                .compactMap { edge in angles[edge.a == node.id ? edge.b : edge.a] }
            if !linked.isEmpty { return linked.reduce(0, +) / Double(linked.count) }
            return node.parentID.flatMap { engineAngles[$0] } ?? 0
        }

        let networks = drill.filter { $0.kind == .network || ($0.kind == .more && $0.moreCategory == .networks) }
        let networkRadius = (outer == engineRadius ? firstTier - networkGap : outer) + networkGap
        let networkOuter = ring(networks, baseRadius: networkRadius, width: 150) { meanAngle(of: $0, kind: .attached) }
        if !networks.isEmpty { outer = max(outer, networkOuter) }

        let volumes = drill.filter { $0.kind == .volume || ($0.kind == .more && $0.moreCategory == .volumes) }
        let volumeRadius = outer + volumeGap
        let volumeOuter = ring(volumes, baseRadius: volumeRadius, width: 140) { meanAngle(of: $0, kind: .mount) }
        if !volumes.isEmpty { outer = max(outer, volumeOuter) }

        // Turn the fan to face outwards, then — in the final orientation, since
        // the pills are wider than tall — nudge whatever still touches.
        let cosine = cos(orientation), sine = sin(orientation)
        offsets = offsets.mapValues { CGPoint(x: $0.x * cosine - $0.y * sine, y: $0.x * sine + $0.y * cosine) }
        separate(&offsets, nodes: drill + engines, around: topology.node(machineID))
        var reach = outer + marginAfterLastRing
        for node in drill + engines {
            guard let offset = offsets[node.id] else { continue }
            let size = TopologyLayout.nodeSize(node)
            reach = max(reach, hypot(abs(offset.x) + size.width / 2, abs(offset.y) + size.height / 2) + 30)
        }
        return Result(offsets: offsets, radius: reach)
    }

    /// Pushes overlapping nodes apart along the axis they overlap least, the
    /// machine in the middle staying where it is. Deterministic; stops when
    /// nothing touches (or after a fixed number of passes).
    static func separate(_ offsets: inout [String: CGPoint], nodes: [TopologyNode], around machine: TopologyNode?, padding: Double = 8) {
        struct Item { let id: String; let w: Double; let h: Double; let fixed: Bool }
        var items = nodes.compactMap { node -> Item? in
            guard offsets[node.id] != nil else { return nil }
            let size = TopologyLayout.nodeSize(node)
            return Item(id: node.id, w: size.width, h: size.height, fixed: false)
        }
        if let machine {
            let size = TopologyLayout.nodeSize(machine)
            items.insert(Item(id: machine.id, w: size.width, h: size.height, fixed: true), at: 0)
            offsets[machine.id] = .zero
        }
        for _ in 0..<160 {
            var moved = false
            for i in items.indices {
                for j in items.indices where j > i {
                    guard var a = offsets[items[i].id], var b = offsets[items[j].id] else { continue }
                    let dx = b.x - a.x, dy = b.y - a.y
                    let overlapX = (items[i].w + items[j].w) / 2 + padding - abs(dx)
                    let overlapY = (items[i].h + items[j].h) / 2 + padding - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    moved = true
                    let share = items[i].fixed ? 1.0 : 0.5
                    if overlapX < overlapY {
                        let direction: Double = dx > 0 || (dx == 0 && i < j) ? 1 : -1
                        b.x += direction * overlapX * share
                        if !items[i].fixed { a.x -= direction * overlapX * 0.5 }
                    } else {
                        let direction: Double = dy > 0 || (dy == 0 && i < j) ? 1 : -1
                        b.y += direction * overlapY * share
                        if !items[i].fixed { a.y -= direction * overlapY * 0.5 }
                    }
                    offsets[items[i].id] = a
                    offsets[items[j].id] = b
                }
            }
            if !moved { break }
        }
        if let machine { offsets[machine.id] = nil }
    }

    /// How many items go on each tier: the fewest tiers whose combined capacity
    /// holds `count`, filled in proportion to capacity.
    static func tierCounts(for count: Int, span: Double) -> [Int] {
        guard count > 0 else { return [] }
        var capacities: [Int] = []
        var total = 0
        while total < count {
            let radius = firstTier + Double(capacities.count) * tierStep
            let capacity = max(1, Int(radius * span / itemSpacing))
            capacities.append(capacity)
            total += capacity
        }
        var counts = capacities.map { count * $0 / total }
        var remainder = count - counts.reduce(0, +)
        var tier = 0
        while remainder > 0 {
            if counts[tier % counts.count] < capacities[tier % counts.count] {
                counts[tier % counts.count] += 1
                remainder -= 1
            }
            tier += 1
        }
        return counts
    }

    /// Moves angles apart until neighbours are at least `minGap` from each
    /// other, keeping their order. Input and output are in the same order.
    static func spread(_ angles: [Double], minGap: Double, circular: Bool = false) -> [Double] {
        guard angles.count > 1 else { return angles }
        let order = angles.indices.sorted { angles[$0] < angles[$1] }
        var sorted = order.map { angles[$0] }
        for _ in 0..<80 {
            var moved = false
            for i in 0..<(sorted.count - 1) {
                let gap = sorted[i + 1] - sorted[i]
                if gap < minGap - 1e-9 {
                    let push = (minGap - gap) / 2
                    sorted[i] -= push
                    sorted[i + 1] += push
                    moved = true
                }
            }
            if circular {
                // Keep the last and the first one apart across the seam.
                let gap = sorted[0] + 2 * .pi - sorted[sorted.count - 1]
                if gap < minGap - 1e-9 {
                    let push = (minGap - gap) / 2
                    sorted[sorted.count - 1] += push
                    sorted[0] -= push
                    moved = true
                }
            }
            if !moved { break }
        }
        var result = angles
        for (rank, index) in order.enumerated() { result[index] = sorted[rank] }
        return result
    }
}
