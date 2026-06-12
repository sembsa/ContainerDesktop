import SwiftUI

/// Prominent banner shown when the `container` system service is stopped.
struct ServiceBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Usługa systemowa nie jest uruchomiona")
                    .font(.headline)
                Text("Uruchom usługę container, aby zarządzać kontenerami i obrazami.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.startService() }
            } label: {
                if model.system.serviceState.isTransitioning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Uruchom usługę")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.system.serviceState.isTransitioning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.3)), in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
