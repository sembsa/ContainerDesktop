import SwiftUI

/// Shown on Apple silicon when Rosetta is missing.
///
/// `container` enables Rosetta for *any* `amd64` image on an arm64 host,
/// whether or not `--rosetta` was passed — so without it every x86-64 image
/// fails to start, and a major macOS upgrade is the usual reason it is gone.
struct RosettaBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Brakuje Rosetty — obrazy amd64 nie wystartują")
                    .font(.headline)
                Text("Rosetta pozwala uruchamiać obrazy x86-64 na Apple Silicon. Instalacja wymaga hasła administratora i oznacza akceptację licencji Apple.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.system.installRosetta() }
            } label: {
                if model.system.isInstallingRosetta {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Zainstaluj Rosettę")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.system.isInstallingRosetta)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.3)), in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
