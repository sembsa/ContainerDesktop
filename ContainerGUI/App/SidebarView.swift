import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private let primary: [AppModel.Section] = [.containers, .images, .volumes, .networks]
    private let orchestration: [AppModel.Section] = [.kubernetes, .workloads, .helm]
    private let secondary: [AppModel.Section] = [.registries, .machines, .system]

    var body: some View {
        // List sidebar selection needs an OPTIONAL binding to drive navigation on
        // click; bridge it onto the non-optional AppModel.selection.
        let selectionBinding = Binding<AppModel.Section?>(
            get: { model.selection },
            set: { if let value = $0 { model.selection = value } }
        )

        List(selection: selectionBinding) {
            Section("Zasoby") {
                ForEach(primary) { section in
                    sidebarRow(section)
                }
            }
            Section("Orkiestracja") {
                ForEach(orchestration) { section in
                    sidebarRow(section)
                }
            }
            Section("Konfiguracja") {
                ForEach(secondary) { section in
                    sidebarRow(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ServiceStatusFooter()
        }
    }

    @ViewBuilder
    private func sidebarRow(_ section: AppModel.Section) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if section == .containers, model.containers.runningCount > 0 {
                    Text("\(model.containers.runningCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if section == .kubernetes, !model.kubernetes.clusters.isEmpty {
                    Text("\(model.kubernetes.clusters.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: section.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
        .tag(section)
    }
}

/// Bottom-of-sidebar service indicator with a quick start/stop control.
struct ServiceStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.system.serviceState.isTransitioning {
                ProgressView().controlSize(.small)
            } else {
                Button(model.system.serviceState.isRunning ? "Zatrzymaj" : "Uruchom") {
                    Task {
                        if model.system.serviceState.isRunning {
                            await model.stopService()
                        } else {
                            await model.startService()
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusColor: Color {
        switch model.system.serviceState {
        case .running: .green
        case .stopped: .red
        case .starting, .stopping: .orange
        case .unknown: .gray
        }
    }

    private var statusText: String {
        switch model.system.serviceState {
        case .running: String(localized: "Usługa działa")
        case .stopped: String(localized: "Usługa zatrzymana")
        case .starting: String(localized: "Uruchamianie…")
        case .stopping: String(localized: "Zatrzymywanie…")
        case .unknown: String(localized: "Sprawdzanie…")
        }
    }
}
