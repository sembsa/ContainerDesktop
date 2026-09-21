import Foundation
import Sparkle

/// Appends the installation parameters to every appcast request.
///
/// Sparkle calls this whether or not it is sending its own system profile
/// (`parameterizedFeedURL` adds the delegate's parameters unconditionally and
/// gates only the profile array), which is why `SUEnableSystemProfiling` stays
/// off: the profile would report the machine's model, CPU and memory, and none
/// of that is needed to count installations.
///
/// Holds no mutable state — every value is read on demand from `UserDefaults`,
/// which is itself thread-safe — so it is safe to hand to Sparkle from any
/// thread.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        InstallIdentifier.feedParameters()
    }
}
