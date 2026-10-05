import SwiftUI

/// The container's source as separate capsule chips, always shown:
/// location ("Local" / "External"), the external machine's name (external only)
/// and the runtime running it ("Apple", "Docker", "Colima"). One tint per kind.
struct RuntimeBadge: View {
    let container: ContainerInfo

    var body: some View {
        HStack(spacing: 4) {
            ForEach(container.sourceTags, id: \.self) { tag in
                SourceChip(text: tag.text, tint: Self.tint(for: tag.kind))
                    .help(help(for: tag))
            }
        }
    }

    static func tint(for kind: SourceTag.Kind) -> Color {
        switch kind {
        case .location: .indigo
        case .machine: .orange
        case .runtime: .cyan
        }
    }

    private func help(for tag: SourceTag) -> String {
        switch tag.kind {
        case .location:
            container.location == .local
                ? String(localized: "Kontener na tym Macu")
                : String(localized: "Kontener z maszyny zewnętrznej")
        case .machine:
            String(format: String(localized: "Maszyna zewnętrzna: %@"), tag.text)
        case .runtime:
            String(format: String(localized: "Silnik kontenerów: %@"), tag.text)
        }
    }
}

/// The same three chips on a network row: location, machine name (external
/// only) and runtime — which reads "WireGuard" on a tunnel and is tinted apart
/// from the engines so the kind is visible at a glance.
struct NetworkBadge: View {
    let network: NetworkEntry

    var body: some View {
        HStack(spacing: 4) {
            ForEach(network.sourceTags, id: \.self) { tag in
                SourceChip(text: tag.text, tint: tint(for: tag))
                    .help(help(for: tag))
            }
        }
    }

    private func tint(for tag: SourceTag) -> Color {
        tag.kind == .runtime && network.kind == .wireguard ? .green : RuntimeBadge.tint(for: tag.kind)
    }

    private func help(for tag: SourceTag) -> String {
        switch tag.kind {
        case .location:
            network.location == .local
                ? String(localized: "Sieć na tym Macu")
                : String(localized: "Sieć z maszyny zewnętrznej")
        case .machine:
            String(format: String(localized: "Maszyna zewnętrzna: %@"), tag.text)
        case .runtime:
            network.kind == .wireguard
                ? String(localized: "Interfejs WireGuard")
                : String(format: String(localized: "Silnik kontenerów: %@"), tag.text)
        }
    }
}

/// The same three chips on a volume row.
struct VolumeBadge: View {
    let volume: VolumeEntry

    var body: some View {
        HStack(spacing: 4) {
            ForEach(volume.sourceTags, id: \.self) { tag in
                SourceChip(text: tag.text, tint: RuntimeBadge.tint(for: tag.kind))
                    .help(help(for: tag))
            }
        }
    }

    private func help(for tag: SourceTag) -> String {
        switch tag.kind {
        case .location:
            volume.location == .local
                ? String(localized: "Wolumen na tym Macu")
                : String(localized: "Wolumen z maszyny zewnętrznej")
        case .machine:
            String(format: String(localized: "Maszyna zewnętrzna: %@"), tag.text)
        case .runtime:
            String(format: String(localized: "Silnik kontenerów: %@"), tag.text)
        }
    }
}

/// One tinted capsule, styled like the state pill. Never compressed, so a long
/// name elsewhere in the row truncates before a tag does.
struct SourceChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
