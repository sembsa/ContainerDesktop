import SwiftUI

/// Renders a `JSONValue` as an expandable key/value tree.
struct JSONTreeView: View {
    let value: JSONValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                JSONNode(key: nil, value: value, level: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
}

private struct JSONNode: View {
    let key: String?
    let value: JSONValue
    let level: Int

    @State private var expanded = true

    var body: some View {
        switch value {
        case .object(let dictionary):
            container(children: dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        case .array(let items):
            container(children: items.enumerated().map { ("[\($0.offset)]", $0.element) })
        default:
            leafRow
        }
    }

    private var leafRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let key {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(value.scalarDescription ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(value.scalarDescription ?? "")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.leading, CGFloat(level) * 14)
    }

    @ViewBuilder
    private func container(children: [(String, JSONValue)]) -> some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children, id: \.0) { childKey, childValue in
                JSONNode(key: childKey, value: childValue, level: level + 1)
            }
        } label: {
            Text(key ?? "root")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        .padding(.leading, CGFloat(level) * 14)
    }
}
