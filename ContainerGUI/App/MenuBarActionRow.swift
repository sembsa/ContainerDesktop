import SwiftUI

/// A full-width action row for the menu bar popover.
///
/// Stacked bordered buttons read as a form; a menu-bar popover should read as a
/// menu. These highlight on hover across the whole width, the way real menu
/// items do, and every one carries an icon.
struct MenuBarActionRow<Content: View>: View {
    let content: Content
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void)
    where Content == Label<Text, Image> {
        self.content = Label(title, systemImage: systemImage)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
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
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
