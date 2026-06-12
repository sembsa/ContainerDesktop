import SwiftUI

/// Small (i) button that explains a concept in a click popover.
struct InfoTip: View {
    let text: String
    /// `.small` blends into inline labels; pass `.regular` in toolbars.
    var size: ControlSize = .small
    @State private var isShowing = false

    var body: some View {
        Group {
            if size == .small {
                Button {
                    isShowing.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else {
                // Toolbar variant: NO style/font overrides — the toolbar then
                // renders the glyph exactly like its neighbouring buttons.
                Button {
                    isShowing.toggle()
                } label: {
                    Label("Informacje", systemImage: "info.circle")
                }
            }
        }
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .help("Co to jest?")
    }
}
