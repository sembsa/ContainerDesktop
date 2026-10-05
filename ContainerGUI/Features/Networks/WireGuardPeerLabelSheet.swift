import SwiftUI
import AppKit

/// What the edit sheet is opened for: one peer, and the name it would have
/// without a label (the machine its address matched, if any).
struct WireGuardPeerLabelTarget: Identifiable, Hashable {
    let peer: WireGuardPeer
    var autoName: String?

    var id: String { peer.publicKey }
}

/// The form for a peer's label and note.
///
/// The same sheet opens from a peer row in the list and from a topology node or
/// edge panel. Only the peer's public key is ever stored, with the label and note.
/// The key, allowed IPs and endpoint are shown read-only so the right peer can be
/// told apart from its neighbours.
struct WireGuardPeerLabelSheet: View {
    let target: WireGuardPeerLabelTarget
    var store: WireGuardPeerLabelStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var note: String
    @State private var deviceType: PeerDeviceType?
    @FocusState private var labelFocused: Bool

    init(target: WireGuardPeerLabelTarget, store: WireGuardPeerLabelStore = .shared) {
        self.target = target
        self.store = store
        let saved = store.entry(for: target.peer.publicKey)
        _label = State(initialValue: saved?.label ?? "")
        _note = State(initialValue: saved?.note ?? "")
        _deviceType = State(initialValue: store.deviceType(for: target.peer.publicKey))
    }

    private var peer: WireGuardPeer { target.peer }
    private var canSave: Bool { WireGuardPeerLabels.normalizedLabel(label) != nil }
    private var hasSavedLabel: Bool {
        store.entry(for: peer.publicKey) != nil || store.deviceType(for: peer.publicKey) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(Color.green.gradient)
                    .font(.title3)
                Text("Etykieta peera").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            Form {
                Section {
                    TextField("Etykieta", text: $label)
                        .focused($labelFocused)
                        .onSubmit(save)
                    TextField("Notatka (opcjonalnie)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                    LabeledContent("Typ urządzenia") {
                        PeerDeviceTypePicker(selection: $deviceType)
                            .labelsHidden()
                    }
                    if !canSave {
                        Text("Etykieta jest wymagana, aby zapisać.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(fallbackHint)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Auto: znana maszyna zachowuje swoją ikonę, nieznany peer jest pokazywany jako „?”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Klucz publiczny") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(peer.publicKey)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                            IconButton(symbol: "doc.on.doc", description: String(localized: "Kopiuj klucz publiczny")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(peer.publicKey, forType: .string)
                            }
                        }
                    }
                    LabeledContent("Dozwolone IP") {
                        Text(peer.allowedIPs.isEmpty ? "—" : peer.allowedIPs.joined(separator: ", "))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Endpoint") {
                        Text(peer.endpoint ?? "—").textSelection(.enabled)
                    }
                } header: {
                    Text("Peer")
                } footer: {
                    Text("Zapisywany jest tylko klucz publiczny wraz z etykietą, notatką i typem urządzenia, w preferencjach aplikacji.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Wyczyść etykietę", role: .destructive) {
                    store.clear(for: peer.publicKey)
                    dismiss()
                }
                .disabled(!hasSavedLabel)
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zapisz", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: SheetWidth.standard)
        .onAppear { labelFocused = true }
    }

    private var fallbackHint: String {
        if let name = target.autoName {
            return String(format: String(localized: "Bez etykiety peer jest pokazywany jako „%@”."), name)
        }
        return String(format: String(localized: "Bez etykiety peer jest pokazywany jako skrócony klucz (%@)."), WireGuardFormat.shortKey(peer.publicKey))
    }

    private func save() {
        guard canSave, store.set(label: label, note: note, deviceType: deviceType, for: peer.publicKey) else { return }
        dismiss()
    }
}

/// "Auto" plus the eleven device types, each with its SF Symbol. `nil` is Auto.
struct PeerDeviceTypePicker: View {
    @Binding var selection: PeerDeviceType?

    var body: some View {
        Picker("Typ urządzenia", selection: $selection) {
            Label(PeerDeviceType.autoTitle, systemImage: PeerDeviceType.autoSymbol)
                .tag(PeerDeviceType?.none)
            Divider()
            ForEach(PeerDeviceType.allCases) { type in
                Label(type.title, systemImage: type.symbol)
                    .tag(PeerDeviceType?.some(type))
            }
        }
        .pickerStyle(.menu)
    }
}

/// The visible "Edit" button of a peer row, node panel or edge panel.
struct PeerLabelEditButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Edytuj", systemImage: "pencil")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(String(localized: "Edytuj etykietę peera"))
    }
}
