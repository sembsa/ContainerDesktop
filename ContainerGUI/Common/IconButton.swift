import SwiftUI

extension View {
    /// Describes a control whose visible label cannot serve as its name, once,
    /// for the pointer and for VoiceOver — a bare glyph, or an abbreviation like
    /// "ro".
    ///
    /// `.help()` is the tooltip a mouse finds; VoiceOver reads
    /// `accessibilityLabel` and nothing else. A control whose whole label is an
    /// SF Symbol and that sets only the first is announced as "button" — which
    /// described every icon control in this app, nine of which said nothing at
    /// all. The two strings are always the same sentence, so they are written
    /// once.
    func iconHelp(_ description: String) -> some View {
        help(description).accessibilityLabel(Text(description))
    }
}

/// A row-action button: an SF Symbol, borderless, and described.
///
/// It exists so the description cannot be left out — there is no way to build
/// one of these without saying what it does. Icon controls whose shape differs
/// from this (menu labels, the bordered pair in the file browser) keep their own
/// styling and reach for `iconHelp` instead; pulling those into one shape is a
/// visual change, and a separate pass.
struct IconButton: View {
    let symbol: String
    let description: String
    var tint: Color?
    var size: ControlSize = .small
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .controlSize(size)
        .tint(tint)
        .iconHelp(description)
    }
}
