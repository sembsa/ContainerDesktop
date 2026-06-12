import SwiftUI

/// Reusable empty-state placeholder for list sections.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.gradient)
            Text(title)
                .font(.title3.weight(.medium))
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Placeholder for sections not yet implemented in this build stage.
struct PlaceholderSectionView: View {
    let section: AppModel.Section

    var body: some View {
        EmptyStateView(
            symbol: section.symbol,
            title: section.title,
            message: String(localized: "Ta sekcja zostanie udostępniona w kolejnym etapie.")
        )
        .navigationTitle(section.title)
    }
}
