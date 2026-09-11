import SwiftUI

/// The shared look of every row in the menu bar popover.
///
/// Applied to the *label* rather than through a `ButtonStyle`, because the rows
/// are not all buttons: one is a `Menu`, one a `SettingsLink`, one a view that
/// owns its own button. Styling them separately is how three of them ended up
/// without a hover highlight while the rest had one.
struct MenuBarRow: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .labelStyle(MenuBarLabelStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.accentColor.opacity(0.18) : .clear)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Makes any control read as a row of the menu bar popover.
    func menuBarRow() -> some View { modifier(MenuBarRow()) }
}

/// A full-width action row for the menu bar popover.
struct MenuBarActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .menuBarRow()
        }
        .buttonStyle(.plain)
    }
}

/// Icon and title on one line, with the icon in a fixed column so every row's
/// text starts at the same x — the thing that makes a stack of rows read as a
/// menu rather than a pile of buttons.
struct MenuBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            configuration.title
            Spacer(minLength: 0)
        }
    }
}
