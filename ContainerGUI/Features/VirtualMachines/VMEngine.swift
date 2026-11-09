import Darwin
import Foundation

/// One internal snapshot of a machine's disk (and, when taken live, its memory).
struct VMSnapshot: Identifiable, Hashable, Sendable {
    var tag: String
    /// As QEMU prints it, e.g. "1.17 GiB"; "0 B" for a disk-only snapshot.
    var vmStateSize: String
    var date: Date?
    var id: String { tag }
    /// Taken while the machine ran: restoring it resumes the machine.
    var hasMemory: Bool { vmStateSize != "0 B" }
}

enum VMSnapshotParser {
    /// Parses `qemu-img snapshot -l` or HMP `info snapshots` — the same columns
    /// (ID TAG VM_SIZE DATE VM_CLOCK [ICOUNT]) under different headers.
    ///
    /// HMP files every snapshot of ours under "partial (non-loadable)
    /// snapshots on 'd0'", because the UEFI vars flash has none — yet
    /// `snapshot-load` with the same device list restores them fine. So the
    /// sections are not told apart; a tag listed twice counts once.
    static func parse(_ text: String) -> [VMSnapshot] {
        let row = /^\s*(\S+)\s+(\S+)\s+(.*?)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+\S+/
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var snapshots: [VMSnapshot] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = String(line).firstMatch(of: row), match.1 != "ID",
                  !snapshots.contains(where: { $0.tag == match.2 }) else { continue }
            snapshots.append(VMSnapshot(tag: String(match.2), vmStateSize: String(match.3),
                                        date: formatter.date(from: String(match.4))))
        }
        return snapshots
    }

    /// A tag QEMU will take as one word: no spaces, nothing a shell or HMP would split on.
    static func sanitize(_ tag: String) -> String {
        String(tag.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" })
    }
}

/// Starting, stopping, snapshotting and cloning QEMU machines.
enum VMEngine {
    enum Failure: LocalizedError {
        case notRunning
        case mustBeStopped
        case agentUnavailable

        var errorDescription: String? {
            switch self {
            case .notRunning: String(localized: "Maszyna nie jest uruchomiona.")
            case .mustBeStopped: String(localized: "Najpierw zatrzymaj maszynę.")
            case .agentUnavailable: String(localized: "Agent gościa nie odpowiada.")
            }
        }
    }

    // MARK: - Power

    /// Boots the machine and returns it as written back to `vm.json`, with the
    /// VNC port it got this time. Returns once QEMU has taken the VNC password —
    /// the guest itself is still booting.
    ///
    /// With `restoring`, QEMU starts paused, loads that snapshot's memory and
    /// disk, and only then runs — the one way a live restore works here.
    @discardableResult
    static func start(_ vm: VirtualMachine, in directory: URL? = nil, restoring tag: String? = nil) async throws -> VirtualMachine {
        let dir = directory ?? vm.directory
        let paths = QEMULauncher.paths(for: dir)
        guard VirtualMachineStore.runningPID(pidFile: paths.pidFile) == nil else {
            throw QEMULauncher.Failure.alreadyRunning
        }
        if let clone = VirtualMachineStore.scan(dir.deletingLastPathComponent())
            .first(where: { $0.backingMachine == dir.lastPathComponent }) {
            throw QEMULauncher.Failure.backsAClone(clone.name)
        }
        guard let display = QEMULauncher.freeVNCDisplay() else { throw QEMULauncher.Failure.noFreeDisplay }

        var vm = vm
        vm.id = dir.lastPathComponent
        vm.vncPort = UInt16(5900 + display)
        if vm.vncPassword.isEmpty { vm.vncPassword = randomPassword() }
        try vm.save(to: dir)

        var arguments = QEMULauncher.arguments(for: vm, paths: paths, vncDisplay: display)
        if tag != nil { arguments.append("-S") }
        let pid = try QEMULauncher.spawn(arguments: arguments, paths: paths)
        // The QMP socket appears a moment after the process does; until the
        // password is set, `password=on` turns every VNC client away.
        let qmp = QMPClient.shared(for: dir)
        for _ in 0..<50 {
            guard kill(pid, 0) == 0 else { break }
            if (try? await qmp.setVNCPassword(vm.vncPassword)) != nil {
                if let tag {
                    do {
                        try await qmp.loadSnapshot(tag)
                        try await qmp.cont()
                    } catch {
                        try? await qmp.quit()
                        throw error
                    }
                }
                vm.isRunning = true
                return vm
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let log = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
        if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        throw QEMULauncher.Failure.exitedEarly(String(log.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Asks the guest to shut down: through the guest agent when it answers,
    /// otherwise with the ACPI power button. Does not wait for it.
    static func stop(_ vm: VirtualMachine, in directory: URL? = nil) async throws {
        let dir = directory ?? vm.directory
        guard isRunning(dir) else { throw Failure.notRunning }
        do {
            try await QGAClient.shared(for: dir).shutdown()
        } catch {
            try await QMPClient.shared(for: dir).powerdown()
        }
    }

    /// Ends QEMU at once, as pulling the plug would.
    static func forceStop(_ vm: VirtualMachine, in directory: URL? = nil) async throws {
        let dir = directory ?? vm.directory
        let pidFile = QEMULauncher.paths(for: dir).pidFile
        guard let pid = VirtualMachineStore.runningPID(pidFile: pidFile) else { throw Failure.notRunning }
        do {
            try await QMPClient.shared(for: dir).quit()
        } catch {
            kill(pid, SIGTERM)
        }
    }

    /// Polls until QEMU has exited. False if it is still running at `timeout`.
    static func waitUntilStopped(_ directory: URL, timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !isRunning(directory) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return !isRunning(directory)
    }

    static func isRunning(_ directory: URL) -> Bool {
        VirtualMachineStore.runningPID(pidFile: QEMULauncher.paths(for: directory).pidFile) != nil
    }

    // MARK: - Snapshots

    /// Live through QMP while the machine runs; through `qemu-img` on the
    /// disk file while it does not (QEMU holds a lock on it while running).
    static func snapshots(of vm: VirtualMachine, in directory: URL? = nil) async throws -> [VMSnapshot] {
        let dir = directory ?? vm.directory
        if isRunning(dir) {
            return VMSnapshotParser.parse(try await QMPClient.shared(for: dir).hmp("info snapshots"))
        }
        return VMSnapshotParser.parse(try await qemuImg(["snapshot", "-l", diskPath(vm, dir)]))
    }

    static func createSnapshot(_ tag: String, of vm: VirtualMachine, in directory: URL? = nil) async throws {
        let dir = directory ?? vm.directory
        let tag = VMSnapshotParser.sanitize(tag)
        if isRunning(dir) {
            try await QMPClient.shared(for: dir).saveSnapshot(tag)
        } else {
            try await qemuImg(["snapshot", "-c", tag, diskPath(vm, dir)])
        }
    }

    static func restoreSnapshot(_ tag: String, of vm: VirtualMachine, in directory: URL? = nil) async throws {
        let dir = directory ?? vm.directory
        if let clone = VirtualMachineStore.scan(dir.deletingLastPathComponent())
            .first(where: { $0.backingMachine == dir.lastPathComponent }) {
            throw QEMULauncher.Failure.backsAClone(clone.name)
        }
        // A running QEMU cannot load state in place (see `QMPClient.loadSnapshot`),
        // so the machine is pulled down and started again into the snapshot.
        let wasRunning = isRunning(dir)
        let snapshot = try await snapshots(of: vm, in: dir).first { $0.tag == tag }
        if wasRunning {
            try await forceStop(vm, in: dir)
            guard await waitUntilStopped(dir, timeout: .seconds(30)) else { throw Failure.mustBeStopped }
        }
        if let snapshot, snapshot.hasMemory {
            try await start(vm, in: dir, restoring: tag)
        } else {
            try await qemuImg(["snapshot", "-a", tag, diskPath(vm, dir)])
            if wasRunning { try await start(vm, in: dir) }
        }
    }

    static func deleteSnapshot(_ tag: String, of vm: VirtualMachine, in directory: URL? = nil) async throws {
        let dir = directory ?? vm.directory
        if isRunning(dir) {
            try await QMPClient.shared(for: dir).deleteSnapshot(tag)
        } else {
            try await qemuImg(["snapshot", "-d", tag, diskPath(vm, dir)])
        }
    }

    /// "2026-11-09-1042" — a default name for a new snapshot.
    static func suggestedSnapshotTag(at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Linked clone

    /// A new machine whose disk is a thin qcow2 layer over this one's: created
    /// in a second, sized by what it changes. From then on the original is the
    /// clone's base and `start` refuses to boot it.
    @discardableResult
    static func clone(_ vm: VirtualMachine, named name: String, in directory: URL? = nil) async throws -> VirtualMachine {
        let dir = directory ?? vm.directory
        guard !isRunning(dir) else { throw Failure.mustBeStopped }
        let root = dir.deletingLastPathComponent()
        let fm = FileManager.default
        var id = "\(dir.lastPathComponent)-clone"
        var suffix = 2
        while fm.fileExists(atPath: root.appending(path: id).path) {
            id = "\(dir.lastPathComponent)-clone-\(suffix)"
            suffix += 1
        }
        let target = root.appending(path: id)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            try await qemuImg(["create", "-f", "qcow2", "-b", diskPath(vm, dir), "-F", "qcow2",
                               target.appending(path: "disk.qcow2").path])
            try fm.copyItem(at: dir.appending(path: "vars.fd"), to: target.appending(path: "vars.fd"))
            var clone = VirtualMachine(
                name: name, os: vm.os, cpus: vm.cpus, memoryMiB: vm.memoryMiB, disk: "disk.qcow2",
                extraDrives: vm.extraDrives.map { drive in
                    var drive = drive
                    if !drive.path.hasPrefix("/") { drive.path = dir.appending(path: drive.path).path }
                    return drive
                },
                vncPassword: randomPassword(), backingMachine: dir.lastPathComponent)
            try clone.save(to: target)
            clone.id = id
            return clone
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    // MARK: - Helpers

    static func diskPath(_ vm: VirtualMachine, _ dir: URL) -> String {
        vm.disk.hasPrefix("/") ? vm.disk : dir.appending(path: vm.disk).path
    }

    /// VNC authentication uses only the first eight characters.
    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    @discardableResult
    private static func qemuImg(_ arguments: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: QEMULauncher.qemuImg) else {
            throw QEMULauncher.Failure.qemuMissing
        }
        let result = try await ProcessRunner.run(executable: QEMULauncher.qemuImg, arguments: arguments,
                                                 timeout: .seconds(600))
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }
}
