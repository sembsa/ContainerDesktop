import SwiftUI

/// Shown when the `container` CLI and the background service run different builds.
///
/// A `.pkg` upgrade replaces every binary on disk but leaves the old apiserver
/// running, and the resulting failures never mention versions: `cp` reports
/// "path not found" for files that plainly exist, `clean` fails with a raw XPC
/// error, and the k8s plugin comes back empty. The app used to detect this only
/// when `k8s list` failed, so anyone not using Kubernetes was left guessing.
struct VersionSkewBanner: View {
    @Environment(AppModel.self) private var model
    let skew: SystemStatus.VersionSkew

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Usługa container wymaga restartu po aktualizacji")
                    .font(.headline)
                Text(
                    String(
                        format: String(localized: "Wiersz poleceń jest w wersji %@, a usługa działająca w tle nadal w %@. Kopiowanie plików, czyszczenie kontenerów i wtyczka k8s będą zawodzić, dopóki usługa nie zostanie zrestartowana."),
                        skew.cli, skew.service
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.restartService() }
            } label: {
                if model.system.serviceState.isTransitioning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Uruchom ponownie usługę")
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
