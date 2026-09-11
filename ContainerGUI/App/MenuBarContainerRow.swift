import SwiftUI

extension ProjectAccent {
    /// Six hues, distinct at the 3 pt width the menu bar gives them.
    ///
    /// Deliberately no red: the bar is a project tag, and a red one next to a
    /// perfectly healthy container reads as an alarm.
    static let palette: [Color] = [.blue, .indigo, .teal, .purple, .cyan, .orange]

    /// Green for a container that belongs to no compose project — it matches the
    /// "running" dot used everywhere else in the app.
    static func color(for project: String?) -> Color {
        slot(for: project).map { palette[$0] } ?? .green
    }
}

/// One running container in the menu bar: who it is, what it is doing now, and
/// what it has been doing for the last couple of minutes.
struct MenuBarContainerRow: View {
    let container: ContainerInfo
    /// Passed as plain numbers rather than the store's `LiveUsage`, so the row
    /// depends on nothing but its own inputs — and can be rendered on its own.
    let cpuPercent: Double?
    let memoryUsedBytes: Int64?
    let history: UsageHistory?
    let onStop: () -> Void

    private var accent: Color { ProjectAccent.color(for: container.composeProject) }

    var body: some View {
        HStack(spacing: 9) {
            // The project's colour, so containers from one stack read as a group
            // without nesting them under headers.
            Capsule()
                .fill(accent.gradient)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(container.id)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Sparkline(values: history?.normalised() ?? [], tint: accent)
                        .frame(width: 56, height: 15)

                    Text(Format.cpu(cpuPercent))
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Text(Format.memory(memoryUsedBytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    // `.borderless` still draws a bezel here, which renders as a
                    // grey box with no visible glyph.
                    .buttonStyle(.plain)
                    .help(String(localized: "Zatrzymaj kontener"))
                }
            }
        }
        .frame(height: 36)
    }

    /// Address and published ports — the two things you reach for a container's
    /// row to find out.
    private var subtitle: String {
        var parts: [String] = []
        if let ip = container.primaryIPv4Address, !ip.isEmpty { parts.append(ip) }
        let ports = (container.configuration.publishedPorts ?? [])
            .compactMap(\.hostPort)
            .prefix(3)
            .map { ":\($0)" }
        if !ports.isEmpty { parts.append(ports.joined(separator: " ")) }
        return parts.isEmpty ? String(localized: "bez adresu") : parts.joined(separator: "  ·  ")
    }
}
