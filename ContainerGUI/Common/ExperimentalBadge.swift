import SwiftUI

/// Small pill marking a surface that wraps a CLI feature Apple still labels
/// EXPERIMENTAL (e.g. `--read-only-path`, the `k8s` plugin) — those flags can
/// change or disappear between `container` releases.
struct ExperimentalBadge: View {
    var body: some View {
        Text("EKSPERYMENTALNE")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.orange)
            .help("Funkcja oznaczona przez Apple jako eksperymentalna — jej działanie może się zmienić w kolejnych wersjach container.")
    }
}
