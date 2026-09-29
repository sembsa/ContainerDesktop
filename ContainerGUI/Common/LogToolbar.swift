import SwiftUI

/// The bar under a log pane.
///
/// There used to be three of these. The container log floated its controls in an
/// overlay at the bottom-right, so log lines scrolled *underneath* them and the
/// newest lines — the reason anyone opens a log — sat behind the buttons. The
/// machine and workload logs used a real bar, but put it at the top, disagreed
/// about what belonged in it, and hid the copy button whenever the log was
/// empty, which is exactly when someone wonders whether copying would help.
///
/// Bottom rather than top: a log is read at its tail, so the controls belong
/// where the eye already is.
struct LogToolbar<Options: View>: View {
    let lineCount: Int
    /// Only the container log has timestamps to offer.
    var timestamps: Binding<Bool>?
    let autoscroll: Binding<Bool>
    let copy: () -> Void
    /// Which scopes this pane can write out. Empty hides the control; one scope
    /// makes it a button, two make it a menu — an "Export" menu with a single
    /// item is a click nobody needs.
    var exportScopes: [LogExportScope] = []
    var export: ((LogExportScope) -> Void)?
    /// Whatever this particular log chooses from: how much history, which
    /// stream, which container.
    @ViewBuilder let options: () -> Options

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                options()

                if let timestamps {
                    Toggle("Znaczniki czasu", isOn: timestamps)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
                Toggle("Autoprzewijanie", isOn: autoscroll)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Spacer(minLength: 8)

                // Labelled rather than "1234 linii", because Polish declines the
                // noun by the number and a plain interpolation gets "1 linii".
                Text(String(format: String(localized: "Linii: %d"), lineCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                // Present but disabled on an empty log, rather than absent: a
                // control that vanishes reads as a bug.
                Button("Kopiuj", systemImage: "doc.on.doc", action: copy)
                    .controlSize(.small)
                    .disabled(lineCount == 0)
                    .help(String(localized: "Kopiuje wszystkie widoczne linie logu do schowka"))

                exportControl
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var exportControl: some View {
        if let export, !exportScopes.isEmpty {
            if exportScopes.count == 1, let only = exportScopes.first {
                Button(label(for: only), systemImage: "square.and.arrow.down") { export(only) }
                    .controlSize(.small)
                    .disabled(only == .visible && lineCount == 0)
            } else {
                Menu {
                    ForEach(exportScopes) { scope in
                        Button(label(for: scope)) { export(scope) }
                            .disabled(scope == .visible && lineCount == 0)
                    }
                } label: {
                    Label("Eksportuj", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .help(String(localized: "Zapisuje log do pliku"))
            }
        }
    }

    private func label(for scope: LogExportScope) -> String {
        switch scope {
        case .visible: String(localized: "Zapisz widoczne…")
        case .everything: String(localized: "Zapisz cały log…")
        }
    }
}

extension LogToolbar where Options == EmptyView {
    init(
        lineCount: Int,
        timestamps: Binding<Bool>? = nil,
        autoscroll: Binding<Bool>,
        copy: @escaping () -> Void,
        exportScopes: [LogExportScope] = [],
        export: ((LogExportScope) -> Void)? = nil
    ) {
        self.init(
            lineCount: lineCount, timestamps: timestamps, autoscroll: autoscroll,
            copy: copy, exportScopes: exportScopes, export: export,
            options: { EmptyView() }
        )
    }
}
