import SwiftUI
import AppKit

/// The MCP server AI agents use to drive the app.
struct AgentsSettings: View {
    @State private var mcpBusy = false
    @State private var mcpMessage: String?
    @State private var mcpFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Ścieżka pomocnika") {
                    HStack(spacing: 6) {
                        if FileManager.default.isExecutableFile(atPath: MCPSetup.helperPath) {
                            Text(verbatim: MCPSetup.helperPath)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("nie znaleziono")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Dodaj do Claude Code") {
                        mcpBusy = true
                        Task {
                            let outcome = await MCPSetup.addToClaudeCode()
                            mcpMessage = outcome.message
                            mcpFailed = !outcome.ok
                            mcpBusy = false
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(mcpBusy)
                    Button("Kopiuj konfigurację") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MCPSetup.configSnippet(helperPath: MCPSetup.helperPath), forType: .string)
                        mcpMessage = String(localized: "Skopiowano konfigurację do schowka.")
                        mcpFailed = false
                    }
                    .buttonStyle(.glass)
                    if mcpBusy { ProgressView().controlSize(.small) }
                }
                if let mcpMessage {
                    Text(verbatim: mcpMessage)
                        .font(.caption)
                        .foregroundStyle(mcpFailed ? .red : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.purple.gradient)
                    Text("Agenci AI (MCP)")
                }
            } footer: {
                Text("Agenci AI (Claude Code, Codex, Cursor…) mogą zarządzać kontenerami, obrazami, wolumenami, sieciami i maszynami przez serwer MCP wbudowany w aplikację. Działa bez otwartego okna programu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTab(height: 280)
    }
}
