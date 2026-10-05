import Foundation
import CoreGraphics

/// The in-between frames when a machine is expanded or collapsed (or a "+K more"
/// opened): nodes present before and after glide from one place to the other,
/// new ones grow out of their parent, vanishing ones shrink back into it. Pure,
/// so the animation can be checked without a screen.
struct TopologyTransition {
    struct Frame {
        struct NodeState {
            let node: TopologyNode
            var point: CGPoint
            /// 0…1; also used as the scale of nodes that are appearing or leaving.
            var opacity: Double
        }

        struct EdgeState {
            let edge: TopologyEdge
            var opacity: Double
        }

        var nodes: [NodeState]
        var edges: [EdgeState]
        var positions: [String: CGPoint]
    }

    let from: NetworkTopology
    let fromPositions: [String: CGPoint]
    let to: NetworkTopology
    let toPositions: [String: CGPoint]

    /// Smooth start and finish.
    static func eased(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    func frame(at progress: Double) -> Frame {
        let t = Self.eased(progress)
        let fromIDs = Set(from.nodes.map(\.id)), toIDs = Set(to.nodes.map(\.id))
        let parents: [String: String] = Dictionary(
            (from.nodes + to.nodes).compactMap { node in node.parentID.map { (node.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var cache: [String: CGPoint] = [:]

        func position(_ id: String, depth: Int = 0) -> CGPoint? {
            if let cached = cache[id] { return cached }
            guard depth < 8 else { return toPositions[id] ?? fromPositions[id] }
            let point: CGPoint?
            switch (fromPositions[id], toPositions[id]) {
            case let (a?, b?) where fromIDs.contains(id) && toIDs.contains(id):
                point = lerp(a, b, t)
            case let (_, b?) where toIDs.contains(id):
                // Appearing: out of the parent, which may itself be moving.
                point = parents[id].flatMap { position($0, depth: depth + 1) }.map { lerp($0, b, t) } ?? b
            case let (a?, _) where fromIDs.contains(id):
                // Leaving: back into the parent.
                point = parents[id].flatMap { position($0, depth: depth + 1) }.map { lerp(a, $0, t) } ?? a
            default:
                point = toPositions[id] ?? fromPositions[id]
            }
            if let point { cache[id] = point }
            return point
        }

        func opacity(_ id: String) -> Double {
            switch (fromIDs.contains(id), toIDs.contains(id)) {
            case (true, true): 1
            case (false, true): t
            case (true, false): 1 - t
            default: 0
            }
        }

        // New topology's nodes first, so what stays keeps its drawing order.
        let all = to.nodes + from.nodes.filter { !toIDs.contains($0.id) }
        var states: [Frame.NodeState] = []
        var positions: [String: CGPoint] = [:]
        for node in all {
            guard let point = position(node.id) else { continue }
            positions[node.id] = point
            states.append(.init(node: node, point: point, opacity: opacity(node.id)))
        }

        let toEdgeIDs = Set(to.edges.map(\.id))
        let allEdges = to.edges + from.edges.filter { !toEdgeIDs.contains($0.id) }
        let edges = allEdges.compactMap { edge -> Frame.EdgeState? in
            guard positions[edge.a] != nil, positions[edge.b] != nil else { return nil }
            return .init(edge: edge, opacity: min(opacity(edge.a), opacity(edge.b)))
        }
        return Frame(nodes: states, edges: edges, positions: positions)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
