import Foundation

/// A random identifier for this installation, generated once and kept in
/// `UserDefaults`.
///
/// It is derived from nothing — not the hardware, not an account, not an
/// address — and exists for one reason: the appcast is fetched on every update
/// check, so without it the feed can only be counted in requests, and a machine
/// that checks daily is indistinguishable from thirty machines that checked
/// once. With it, "how many people run this, and on which version" has an
/// answer, and the answer still says nothing about who they are.
enum InstallIdentifier {
    static let defaultsKey = "installIdentifier"

    /// Set to `false` to stop sending the identifier. The update check itself
    /// still happens — only the parameter is dropped.
    static let optOutKey = "metricsOptOut"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: optOutKey)
    }

    /// The stored identifier, generating and persisting one on first use.
    static func current(in defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: defaultsKey), isValid(stored) {
            return stored
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// The server drops anything that is not a UUID, so a value mangled by hand
    /// or left by an older build is replaced rather than sent into a void.
    static func isValid(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Just the marketing version — "0.8.3", never a build number.
    static func appVersion(from bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// "27.0". Enough to tell whether a release can raise the deployment target,
    /// and deliberately not the full system profile Sparkle would otherwise send
    /// (which includes the model, the CPU and how much memory the machine has).
    static func systemVersion(from info: ProcessInfo = .processInfo) -> String {
        let version = info.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// The feed parameters Sparkle appends to `SUFeedURL`.
    static func feedParameters(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        info: ProcessInfo = .processInfo
    ) -> [[String: String]] {
        guard isEnabled(in: defaults) else { return [] }
        var parameters = [["key": "id", "value": current(in: defaults)]]
        // Sparkle's User-Agent carries the version too, but that format is
        // Sparkle's to change, so the version is sent explicitly as well.
        if let version = appVersion(from: bundle) {
            parameters.append(["key": "v", "value": version])
        }
        parameters.append(["key": "os", "value": systemVersion(from: info)])
        return parameters
    }
}
