import SwiftUI

/// Section header of a grouped list: collapse chevron, name and count.
struct GroupHeader: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .accessibilityLabel(Text(String(format: String(localized: "%@, %lld"), title, Int64(count))))
        .accessibilityHint(Text(isCollapsed ? String(localized: "Rozwiń sekcję") : String(localized: "Zwiń sekcję")))
    }
}

/// The toolbar's "Group by" menu.
struct GroupingPicker: View {
    @Binding var selection: ListGrouping
    var options: [ListGrouping] = ListGrouping.containers

    var body: some View {
        Picker("Grupuj wg", selection: $selection) {
            ForEach(options) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.menu)
        .help("Grupuj listę według maszyny, silnika, stanu, projektu lub obrazu")
    }
}
