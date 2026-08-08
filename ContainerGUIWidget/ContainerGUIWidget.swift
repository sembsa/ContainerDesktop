import WidgetKit
import SwiftUI

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct ContainerProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.read() ?? .preview))
    }

    /// WidgetKit budgets roughly 40–70 refreshes a day, so asking for anything
    /// like the app's 3-second poll would be wasted. The app calls
    /// `WidgetCenter.reloadTimelines` whenever state actually changes; this
    /// 15-minute cadence is only the fallback for when the app isn't running.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

// MARK: - Widget

@main
struct ContainerGUIWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContainerStatusWidget()
    }
}

struct ContainerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.containerdesktop.ContainerGUI.status", provider: ContainerProvider()) { entry in
            ContainerWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(Text("Container Desktop"))
        .description(Text("Stan usługi i kontenerów na jednym spojrzeniu."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct ContainerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall: SmallWidget(snapshot: snapshot)
            case .systemLarge: LargeWidget(snapshot: snapshot)
            default: MediumWidget(snapshot: snapshot)
            }
        } else {
            NoDataView()
        }
    }
}

/// Small: the one number worth glancing at, plus service health.
struct SmallWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Kontenery")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                ServiceDot(running: snapshot.serviceRunning)
            }
            Spacer(minLength: 4)
            Text("\(snapshot.runningCount)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(snapshot.runningCount > 0 ? Color.green : Color.secondary)
                .contentTransition(.numericText())
            Text("działa")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text("\(snapshot.stoppedCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                Text("zatrzymanych")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            StalenessLabel(generatedAt: snapshot.generatedAt)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Medium: a short list — what is running and where to reach it.
struct MediumWidget: View {
    let snapshot: WidgetSnapshot

    private var rows: [WidgetSnapshot.Entry] {
        // Running first, then the rest, so the useful half is always on screen.
        Array(snapshot.containers.sorted { lhs, rhs in
            lhs.isRunning == rhs.isRunning ? lhs.id < rhs.id : lhs.isRunning
        }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HeaderRow(snapshot: snapshot)
            if rows.isEmpty {
                Spacer()
                Text("Brak kontenerów")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(rows) { entry in
                    ContainerRowView(entry: entry, showsUsage: true)
                }
                if snapshot.containers.count > rows.count {
                    Text("+\(snapshot.containers.count - rows.count) więcej")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            StalenessLabel(generatedAt: snapshot.generatedAt)
        }
    }
}

/// Large: everything, grouped by Compose project the way the app groups it.
struct LargeWidget: View {
    let snapshot: WidgetSnapshot

    private struct Group: Identifiable {
        let id: String
        let title: String?
        let entries: [WidgetSnapshot.Entry]
    }

    private var groups: [Group] {
        var byProject: [String: [WidgetSnapshot.Entry]] = [:]
        var loose: [WidgetSnapshot.Entry] = []
        for entry in snapshot.containers {
            if let project = entry.project {
                byProject[project, default: []].append(entry)
            } else {
                loose.append(entry)
            }
        }
        var result = byProject.keys.sorted().map {
            Group(id: $0, title: $0, entries: byProject[$0]?.sorted { $0.id < $1.id } ?? [])
        }
        if !loose.isEmpty {
            result.append(Group(id: "loose", title: nil, entries: loose.sorted { $0.id < $1.id }))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(snapshot: snapshot)
            ForEach(groups.prefix(4)) { group in
                if let title = group.title {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.down.right.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan)
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                ForEach(group.entries.prefix(4)) { entry in
                    ContainerRowView(entry: entry, showsUsage: true)
                }
            }
            Spacer(minLength: 0)
            StalenessLabel(generatedAt: snapshot.generatedAt)
        }
    }
}

// MARK: - Shared pieces

struct HeaderRow: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Container Desktop")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text("\(snapshot.runningCount)/\(snapshot.containers.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(snapshot.runningCount > 0 ? Color.green : Color.secondary)
            ServiceDot(running: snapshot.serviceRunning)
        }
    }
}

struct ContainerRowView: View {
    let entry: WidgetSnapshot.Entry
    let showsUsage: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(entry.id)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if showsUsage, entry.isRunning, let cpu = entry.cpuPercent {
                Text(String(format: "%.0f%%", cpu))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let ip = entry.ipv4, entry.isRunning {
                Text(ip)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ServiceDot: View {
    let running: Bool

    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.red)
            .frame(width: 7, height: 7)
            .help(running ? Text("Usługa działa") : Text("Usługa zatrzymana"))
    }
}

/// The widget shows the last snapshot the app wrote, which can be old. Saying
/// so is better than presenting stale numbers as if they were live.
struct StalenessLabel: View {
    let generatedAt: Date

    var body: some View {
        Text(generatedAt, style: .relative)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Uruchom Container Desktop")
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
            Text("Widżet pokazuje dane zapisane przez aplikację.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview data

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        generatedAt: Date(),
        serviceRunning: true,
        containers: [
            .init(id: "outline", image: "outlinewiki/outline:latest", state: "running", ipv4: "192.168.69.4", project: "outline", cpuPercent: 12, memoryUsedBytes: 512 * 1024 * 1024),
            .init(id: "outline-db", image: "postgres:18", state: "running", ipv4: "192.168.69.5", project: "outline", cpuPercent: 3, memoryUsedBytes: 128 * 1024 * 1024),
            .init(id: "sql2025", image: "mssql/server:2025", state: "stopped", ipv4: nil, project: nil, cpuPercent: nil, memoryUsedBytes: nil),
        ]
    )
}
