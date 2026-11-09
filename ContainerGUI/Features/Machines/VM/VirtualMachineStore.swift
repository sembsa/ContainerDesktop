import Foundation
import Observation

/// A full virtual machine run by QEMU — Windows, for now — as opposed to a
/// `container machine`, which is a Linux VM the container service manages.
///
/// Each one is a directory under `~/Library/Application Support/ContainerDesktop/vms`
/// holding its disk, firmware variables, sockets and a `vm.json` describing it.
struct VirtualMachine: Identifiable, Hashable, Decodable, Sendable {
    /// The directory name.
    var id: String = ""
    var name: String
    var os: String
    var vncPort: UInt16
    /// shortcut: stored in plain text in vm.json; move to the Keychain once the
    /// app creates machines itself.
    var vncPassword: String
    var isRunning = false

    private enum CodingKeys: String, CodingKey { case name, os, vncPort, vncPassword }

    var isWindows: Bool { os.lowercased() == "windows" }
}

@MainActor @Observable
final class VirtualMachineStore {
    private(set) var items: [VirtualMachine] = []

    nonisolated static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/ContainerDesktop/vms")
    }

    func refresh() {
        items = Self.scan(Self.directory)
    }

    /// Reads every `vm.json` one level down; directories without one (tools,
    /// half-made machines) are skipped rather than reported.
    nonisolated static func scan(_ root: URL) -> [VirtualMachine] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> VirtualMachine? in
            guard let data = try? Data(contentsOf: dir.appending(path: "vm.json")),
                  var vm = try? JSONDecoder().decode(VirtualMachine.self, from: data) else { return nil }
            vm.id = dir.lastPathComponent
            vm.isRunning = isAlive(pidFile: dir.appending(path: "qemu.pid"))
            return vm
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// QEMU leaves its pidfile behind when it exits, so the file alone proves nothing.
    nonisolated static func isAlive(pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }
}
