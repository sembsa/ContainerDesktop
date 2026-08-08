import SwiftUI

extension ValuesField.Kind {
    /// Whether the control fits on the same line as the key's label. Lists and
    /// YAML blocks need the full width of the pane, so they drop to their own
    /// row underneath.
    var isInline: Bool {
        switch self {
        case .boolean, .number, .string: true
        case .stringList, .yaml: false
        }
    }
}

/// Row editor for a list of scalars — `imagePullSecrets`, `args`, `tolerations`
/// and the many `envs.<component>: []` keys charts are full of.
///
/// A single-line text field holding `["a","b"]` technically worked, but it made
/// the most common edit in a chart (adding one entry to an empty list) an
/// exercise in YAML punctuation.
struct ValuesListEditor: View {
    @Binding var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    TextField(
                        String(localized: "wartość"),
                        text: Binding(
                            get: { index < items.count ? items[index] : "" },
                            set: { if index < items.count { items[index] = $0 } }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    Button("Usuń", systemImage: "minus.circle.fill") {
                        guard index < items.count else { return }
                        items.remove(at: index)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
            Button("Dodaj pozycję", systemImage: "plus.circle") {
                items.append("")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

/// Multi-line YAML box for values a row editor cannot represent: maps and lists
/// of objects (`volumes`, `resources`, an aliased block).
struct ValuesYAMLEditor: View {
    @Binding var text: String
    let placeholder: String

    @State private var isExpanded = false

    private var lineCount: Int {
        max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isExpanded || !text.isEmpty {
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .frame(height: CGFloat(min(max(lineCount, 3), 12)) * 15 + 10)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder.isEmpty ? "klucz: wartość" : placeholder)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                HStack(spacing: 6) {
                    Text(placeholder.isEmpty ? "—" : placeholder)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Edytuj YAML", systemImage: "pencil") { isExpanded = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.caption)
                }
            }
        }
    }
}
