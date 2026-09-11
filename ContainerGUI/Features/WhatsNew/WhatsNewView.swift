import SwiftUI

/// The release notes sheet, shown once per version.
struct WhatsNewView: View {
    let entry: WhatsNew.Entry
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text(String(format: String(localized: "Co nowego w wersji %@"), entry.version))
                    .font(.title2.weight(.semibold))
                Text("Container Desktop został zaktualizowany.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(entry.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            // Without this the sheet opens already scrolled past the first
            // item's icon and heading.
            .defaultScrollAnchor(.top)

            Divider()
            HStack {
                Spacer()
                Button("Zaczynajmy") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 520)
    }
}
