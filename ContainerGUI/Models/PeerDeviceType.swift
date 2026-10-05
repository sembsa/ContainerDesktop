import Foundation

/// What kind of device a WireGuard peer (or a machine node) is, as the user
/// states it in the peer's Edit form. "Auto" is not a case: it is the absence of
/// a choice (`nil`), and the icon then comes from what the app already knows.
enum PeerDeviceType: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case laptop
    case desktop
    case server
    case phone
    case tablet
    case router
    case singleBoard
    case smartTV
    case cloud
    case iot
    case other

    var id: String { rawValue }

    /// SF Symbol for the topology node and the peer row.
    var symbol: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .server: "server.rack"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .router: "wifi.router"
        case .singleBoard: "cpu"
        case .smartTV: "tv"
        case .cloud: "cloud"
        case .iot: "sensor"
        case .other: "questionmark.square.dashed"
        }
    }

    var title: String {
        switch self {
        case .laptop: String(localized: "Laptop")
        case .desktop: String(localized: "Komputer stacjonarny")
        case .server: String(localized: "Serwer")
        case .phone: String(localized: "Telefon")
        case .tablet: String(localized: "Tablet")
        case .router: String(localized: "Router")
        case .singleBoard: String(localized: "Komputer jednopłytkowy (Raspberry Pi)")
        case .smartTV: String(localized: "Smart TV")
        case .cloud: String(localized: "Chmura / VPS")
        case .iot: String(localized: "Urządzenie IoT")
        case .other: String(localized: "Inne")
        }
    }

    /// The "Auto" choice of the picker.
    static var autoSymbol: String { "wand.and.stars" }
    static var autoTitle: String { String(localized: "Auto") }

    // MARK: Auto detection

    /// A type read off a machine's own name ("Rick's iPhone", "pi-garage",
    /// "edge-router"), or `nil` when the name says nothing certain. Only types a
    /// name gives away reliably are guessed: a Mac Studio might be a desktop or a
    /// server, so it is left to the machine's existing icon.
    static func inferred(fromName name: String) -> PeerDeviceType? {
        let lowered = name.lowercased()
        let tokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ substrings: [String]) -> Bool { substrings.contains { lowered.contains($0) } }
        func token(_ words: [String]) -> Bool { words.contains { tokens.contains($0) } }

        if has(["iphone", "android", "pixel"]) || token(["phone", "galaxy"]) { return .phone }
        if has(["ipad", "tablet"]) { return .tablet }
        if has(["raspberry", "raspi", "rpi"]) || token(["pi", "pi4", "pi5", "jetson"]) { return .singleBoard }
        if has(["router", "openwrt", "mikrotik", "unifi"]) || token(["gateway", "ap"]) { return .router }
        if has(["appletv", "chromecast", "smarttv", "firetv"]) || token(["tv"]) { return .smartTV }
        if has(["vps", "droplet", "ec2", "hetzner", "linode", "vultr"]) || token(["cloud"]) { return .cloud }
        if has(["macbook", "laptop", "thinkpad"]) { return .laptop }
        return nil
    }

    /// Which icon wins, highest priority first:
    /// 1. the type the user chose;
    /// 2. a type read off the machine's name;
    /// 3. the machine's built-in default (this Mac a laptop, an external machine a server).
    /// `nil` when none applies: an unknown peer on Auto, drawn as "?".
    static func resolved(user: PeerDeviceType?, inferred: PeerDeviceType?, builtIn: PeerDeviceType?) -> PeerDeviceType? {
        user ?? inferred ?? builtIn
    }
}
