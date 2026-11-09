import Foundation
import Observation

/// A full virtual machine run by QEMU — Windows, for now — as opposed to a
/// `container machine`, which is a Linux VM the container service manages.
///
/// Each one is a directory under `~/Library/Application Support/ContainerDesktop/vms`
/// holding its disk, firmware variables, sockets and a `vm.json` describing it.
/// Every field but `name` has a default, so a `vm.json` from before a field
/// existed still reads.
struct VirtualMachine: Identifiable, Hashable, Codable, Sendable {
    /// An additional drive — an installer ISO, a driver disc, a cloud-init seed.
    struct ExtraDrive: Hashable, Codable, Sendable {
        /// Absolute, or relative to the machine's directory.
        var path: String
        var readOnly = true
        /// A removable CD-ROM (`media=cdrom`) rather than a plain USB disk.
        var cdrom = true
        /// QEMU boot order. ArmVirt UEFI only connects devices that have one, so
        /// an installer ISO without it is never booted.
        var bootIndex: Int?
        /// A virtio-blk disk instead of USB. USB storage enumerates too late
        /// for early-boot probes: cloud-init's ds-identify had already looked
        /// for its seed, found nothing and disabled itself (observed).
        var virtio = false

        init(path: String, readOnly: Bool = true, cdrom: Bool = true, bootIndex: Int? = nil, virtio: Bool = false) {
            self.path = path
            self.readOnly = readOnly
            self.cdrom = cdrom
            self.bootIndex = bootIndex
            self.virtio = virtio
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
            cdrom = try c.decodeIfPresent(Bool.self, forKey: .cdrom) ?? true
            bootIndex = try c.decodeIfPresent(Int.self, forKey: .bootIndex)
            virtio = try c.decodeIfPresent(Bool.self, forKey: .virtio) ?? false
        }
    }

    /// The directory name.
    var id: String = ""
    var name: String
    var os: String = "windows"
    var cpus: Int = 4
    var memoryMiB: Int = 8192
    /// The qcow2 boot disk, relative to the machine's directory.
    var disk: String = "disk.qcow2"
    var extraDrives: [ExtraDrive] = []
    /// Rewritten by the launcher on every start: the display is picked from
    /// whatever is free at the time.
    var vncPort: UInt16 = 5901
    /// shortcut: stored in plain text in vm.json; move to the Keychain once the
    /// app creates machines itself.
    var vncPassword: String = ""
    /// Set on a linked clone: the machine whose disk this one's is layered on.
    /// That machine must not run again, or the clone's disk stops making sense.
    var backingMachine: String?
    /// `ramfb` works with no driver at all; `virtio-gpu` needs viogpudo in the
    /// guest and gives 1280×800. Windows installs start on ramfb and switch.
    var display: Display = .ramfb
    /// Set while Windows Setup or a Linux first boot (cloud-init) runs;
    /// finishing the install clears it.
    var installing = false
    /// Opt-in for the `vm_*` MCP tools: off unless the user switches it on.
    var agentControl = false
    var isRunning = false

    enum Display: String, Codable, Sendable {
        case ramfb
        case virtioGPU = "virtio-gpu"
    }

    private enum CodingKeys: String, CodingKey {
        case name, os, cpus, memoryMiB, disk, extraDrives, vncPort, vncPassword, backingMachine, display, installing, agentControl
    }

    init(name: String, os: String = "windows", cpus: Int = 4, memoryMiB: Int = 8192,
         disk: String = "disk.qcow2", extraDrives: [ExtraDrive] = [],
         vncPort: UInt16 = 5901, vncPassword: String = "", backingMachine: String? = nil) {
        self.name = name
        self.os = os
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.disk = disk
        self.extraDrives = extraDrives
        self.vncPort = vncPort
        self.vncPassword = vncPassword
        self.backingMachine = backingMachine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? os
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? cpus
        memoryMiB = try c.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? memoryMiB
        disk = try c.decodeIfPresent(String.self, forKey: .disk) ?? disk
        extraDrives = try c.decodeIfPresent([ExtraDrive].self, forKey: .extraDrives) ?? []
        vncPort = try c.decodeIfPresent(UInt16.self, forKey: .vncPort) ?? vncPort
        vncPassword = try c.decodeIfPresent(String.self, forKey: .vncPassword) ?? ""
        backingMachine = try c.decodeIfPresent(String.self, forKey: .backingMachine)
        display = try c.decodeIfPresent(Display.self, forKey: .display) ?? .ramfb
        installing = try c.decodeIfPresent(Bool.self, forKey: .installing) ?? false
        agentControl = try c.decodeIfPresent(Bool.self, forKey: .agentControl) ?? false
    }

    var isWindows: Bool { os.lowercased() == "windows" }

    /// "8 GB" for 8192 MiB — binary units, as the guest counts them.
    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryMiB) * 1_048_576, countStyle: .memory)
    }

    /// The machine's own directory.
    var directory: URL { VirtualMachineStore.directory.appending(path: id) }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appending(path: "vm.json"), options: .atomic)
    }
}

@MainActor @Observable
final class VirtualMachineStore {
    private(set) var items: [VirtualMachine] = []
    /// Machines with an operation in flight, so their controls can wait.
    var busy: Set<VirtualMachine.ID> = []

    nonisolated static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/ContainerDesktop/vms")
    }

    func refresh() {
        items = Self.scan(Self.directory)
    }

    /// Runs an engine call with the machine marked busy, then rescans.
    func run(_ vm: VirtualMachine, _ operation: () async throws -> Void) async throws {
        busy.insert(vm.id)
        defer {
            busy.remove(vm.id)
            refresh()
        }
        try await operation()
    }

    /// Reads every `vm.json` one level down; directories without one (tools,
    /// half-made machines) are skipped rather than reported.
    nonisolated static func scan(_ root: URL) -> [VirtualMachine] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { load($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func load(_ dir: URL) -> VirtualMachine? {
        guard let data = try? Data(contentsOf: dir.appending(path: "vm.json")),
              var vm = try? JSONDecoder().decode(VirtualMachine.self, from: data) else { return nil }
        vm.id = dir.lastPathComponent
        vm.isRunning = runningPID(pidFile: dir.appending(path: "qemu.pid")) != nil
        return vm
    }

    /// QEMU leaves its pidfile behind when it is killed, so the file alone proves nothing.
    nonisolated static func isAlive(pidFile: URL) -> Bool {
        runningPID(pidFile: pidFile) != nil
    }

    nonisolated static func runningPID(pidFile: URL) -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else { return nil }
        return pid
    }
}
