import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                Text("Container Desktop").font(.headline)
                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText)
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
                }
            }

            if model.system.serviceState.isRunning {
                runningContainersSection
            }

            Divider()

            Button("Otwórz okno główne") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Menu("Przejdź do") {
                ForEach(AppModel.Section.allCases) { section in
                    Button {
                        model.selection = section
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
            }
            Button("Odśwież") {
                Task { await model.refreshCurrent() }
            }

            Divider()

            SettingsLink {
                Text("Ustawienia…")
            }
            Button("Zakończ") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .task { await model.containers.refresh() }
    }

    @ViewBuilder
    private var runningContainersSection: some View {
        let running = model.containers.items.filter(\.isRunning)

        Label("Działające kontenery: \(model.containers.runningCount)", systemImage: "play.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(running.prefix(6)) { container in
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(container.id)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let ip = container.primaryIPv4 {
                            Text(ip)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { try? await model.containers.stop(container) }
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help(String(localized: "Zatrzymaj kontener"))
                    }
                }
                if running.count > 6 {
                    Text("…i \(running.count - 6) więcej")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 2)

            Button("Zatrzymaj wszystkie") {
                Task { try? await model.containers.stopAll() }
            }
            .controlSize(.small)
        }
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
