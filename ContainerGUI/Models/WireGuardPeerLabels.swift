import Foundation
import Observation

/// What the user typed about one peer: a label (what the peer is called
/// everywhere in the app) and an optional free-text note.
struct WireGuardPeerLabel: Codable, Sendable, Hashable {
    var label: String
    var note: String = ""
}

/// The user's labels, keyed by WireGuard **public** key, and the device type
/// chosen for a key, in the same JSON.
///
/// A public key is not a secret and nothing else is stored, so this lives in
/// plain app preferences. A label is required: an entry with a blank label
/// cannot exist, and removing the label removes its note and device type with
/// it. A device type can also exist without a label (a machine node's type is
/// set from its detail panel, with no label involved); `nil` is "Auto".
///
/// The JSON is backwards compatible: `deviceTypes` is omitted while empty, a
/// file without it decodes with none, and an unknown type is skipped.
struct WireGuardPeerLabels: Codable, Sendable, Equatable {
    static let maxLabelLength = 64
    static let maxNoteLength = 500

    private(set) var entries: [String: WireGuardPeerLabel] = [:]
    private(set) var deviceTypes: [String: PeerDeviceType] = [:]

    init() {}

    var isEmpty: Bool { entries.isEmpty && deviceTypes.isEmpty }

    private enum CodingKeys: String, CodingKey { case entries, deviceTypes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([String: WireGuardPeerLabel].self, forKey: .entries) ?? [:]
        // Raw strings, so a type from a newer version drops that one entry
        // instead of failing the whole file.
        let raw = (try? container.decodeIfPresent([String: String].self, forKey: .deviceTypes)) ?? [:]
        deviceTypes = raw.compactMapValues(PeerDeviceType.init(rawValue:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        if !deviceTypes.isEmpty { try container.encode(deviceTypes.mapValues(\.rawValue), forKey: .deviceTypes) }
    }

    /// Trims and caps a label; `nil` when nothing is left (a label is required).
    static func normalizedLabel(_ text: String) -> String? {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLabelLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedNote(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNoteLength))
    }

    func entry(for publicKey: String) -> WireGuardPeerLabel? { entries[publicKey] }
    func label(for publicKey: String) -> String? { entries[publicKey]?.label }
    func note(for publicKey: String) -> String? {
        guard let note = entries[publicKey]?.note, !note.isEmpty else { return nil }
        return note
    }

    /// Key → label, the shape `WireGuardPeerPresenter` and `TopologyBuilder` take.
    var names: [String: String] { entries.mapValues(\.label) }

    /// Key → note, for the keys that have one.
    var notes: [String: String] { entries.compactMapValues { $0.note.isEmpty ? nil : $0.note } }

    /// The device type the user chose for a key; `nil` is "Auto".
    func deviceType(for publicKey: String) -> PeerDeviceType? { deviceTypes[publicKey] }

    /// Saves a label (and note, and the device type: `nil` is "Auto") for a key.
    /// Returns `false` and changes nothing when the key or the label is blank.
    @discardableResult
    mutating func set(label: String, note: String = "", deviceType: PeerDeviceType? = nil, for publicKey: String) -> Bool {
        guard !publicKey.isEmpty, let label = Self.normalizedLabel(label) else { return false }
        entries[publicKey] = WireGuardPeerLabel(label: label, note: Self.normalizedNote(note))
        deviceTypes[publicKey] = deviceType
        return true
    }

    /// Sets (or, for `nil`, resets to Auto) the device type of a key without
    /// touching its label.
    mutating func setDeviceType(_ type: PeerDeviceType?, for publicKey: String) {
        guard !publicKey.isEmpty else { return }
        deviceTypes[publicKey] = type
    }

    /// Removes the label, its note and the device type: the peer goes back to
    /// its auto-matched machine name and icon, or to its shortened key.
    mutating func clear(for publicKey: String) {
        entries[publicKey] = nil
        deviceTypes[publicKey] = nil
    }

    // MARK: Persistence format

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(from data: Data?) -> WireGuardPeerLabels {
        guard let data, let labels = try? JSONDecoder().decode(WireGuardPeerLabels.self, from: data) else { return WireGuardPeerLabels() }
        return labels
    }

    /// Labels from the earlier alias-only preference (a JSON string of key → name).
    static func migrating(legacy stored: String) -> WireGuardPeerLabels {
        var labels = WireGuardPeerLabels()
        for (key, alias) in WireGuardAliases.decode(stored) { labels.set(label: alias, for: key) }
        return labels
    }
}

/// The labels, shared by the peer list, the topology and the edit sheet, and
/// persisted in `UserDefaults` on every change.
@MainActor @Observable
final class WireGuardPeerLabelStore {
    static let defaultsKey = "wireGuardPeerLabels"
    static let shared = WireGuardPeerLabelStore()

    private(set) var labels: WireGuardPeerLabels

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    /// Loads the saved labels; when there are none yet, picks up the aliases the
    /// previous version kept under `WireGuardAliases.defaultsKey` (left in place).
    init(defaults: UserDefaults = .standard, key: String = WireGuardPeerLabelStore.defaultsKey,
         legacyKey: String = WireGuardAliases.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            labels = WireGuardPeerLabels.decoded(from: data)
        } else if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            labels = WireGuardPeerLabels.migrating(legacy: legacy)
            persist()
        } else {
            labels = WireGuardPeerLabels()
        }
    }

    /// Key → label, for the presenter and the topology builder.
    var names: [String: String] { labels.names }
    var notes: [String: String] { labels.notes }
    /// Key → the device type the user chose, for the keys that have one.
    var deviceTypes: [String: PeerDeviceType] { labels.deviceTypes }

    func deviceType(for publicKey: String) -> PeerDeviceType? { labels.deviceType(for: publicKey) }
    func label(for publicKey: String) -> String? { labels.label(for: publicKey) }
    func note(for publicKey: String) -> String? { labels.note(for: publicKey) }
    func entry(for publicKey: String) -> WireGuardPeerLabel? { labels.entry(for: publicKey) }

    /// `false` (nothing saved) when the label is blank.
    @discardableResult
    func set(label: String, note: String = "", deviceType: PeerDeviceType? = nil, for publicKey: String) -> Bool {
        var updated = labels
        guard updated.set(label: label, note: note, deviceType: deviceType, for: publicKey) else { return false }
        labels = updated
        persist()
        return true
    }

    /// Sets the device type of every key in `publicKeys` (`nil` is "Auto"),
    /// leaving labels alone.
    func setDeviceType(_ type: PeerDeviceType?, for publicKeys: [String]) {
        var updated = labels
        for key in publicKeys { updated.setDeviceType(type, for: key) }
        guard updated != labels else { return }
        labels = updated
        persist()
    }

    func clear(for publicKey: String) {
        guard labels.entry(for: publicKey) != nil || labels.deviceType(for: publicKey) != nil else { return }
        labels.clear(for: publicKey)
        persist()
    }

    private func persist() {
        if let data = labels.encoded() { defaults.set(data, forKey: key) }
    }
}
