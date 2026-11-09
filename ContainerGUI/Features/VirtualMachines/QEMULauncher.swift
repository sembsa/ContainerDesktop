import Darwin
import Foundation

/// Turns a `vm.json` into a running `qemu-system-aarch64`, detached from the app.
///
/// The argument list mirrors the spike's `start.sh`, which is what booted
/// Windows 11 on ARM64 in the first place; the differences are deliberate and
/// listed where they occur.
enum QEMULauncher {
    static let qemu = "/opt/homebrew/bin/qemu-system-aarch64"
    static let qemuImg = "/opt/homebrew/bin/qemu-img"
    static let firmwareCode = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    static let firmwareVarsTemplate = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"
    /// The block node of the boot disk, named so QMP snapshot jobs can address it.
    static let diskNode = "disk0"

    enum Failure: LocalizedError {
        case qemuMissing
        case alreadyRunning
        case backsAClone(String)
        case noFreeDisplay
        case spawn(Int32)
        case exitedEarly(String)

        var errorDescription: String? {
            switch self {
            case .qemuMissing:
                String(localized: "Nie znaleziono QEMU. Zainstaluj je poleceniem brew install qemu.")
            case .alreadyRunning:
                String(localized: "Maszyna już działa.")
            case .backsAClone(let clone):
                String(format: String(localized: "Na dysku tej maszyny opiera się klon „%@”. Uruchomienie jej uszkodziłoby klon."), clone)
            case .noFreeDisplay:
                String(localized: "Brak wolnego portu VNC.")
            case .spawn(let code):
                String(format: String(localized: "Nie udało się uruchomić QEMU (błąd %d)."), code)
            case .exitedEarly(let log):
                String(format: String(localized: "QEMU zakończyło działanie zaraz po starcie: %@"), log)
            }
        }
    }

    // MARK: - Paths

    /// Where a machine's sockets, pidfile and log live.
    struct Paths: Equatable, Sendable {
        let directory: URL
        /// Holds the sockets: the machine's own directory, or a short one in
        /// /tmp when that path is too long for a Unix socket.
        let socketDirectory: URL
        var qmp: String { socketDirectory.appending(path: "qmp.sock").path }
        var qga: String { socketDirectory.appending(path: "qga.sock").path }
        var pidFile: URL { directory.appending(path: "qemu.pid") }
        var log: URL { directory.appending(path: "qemu.log") }
    }

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, terminator included.
    static let maxSocketPathBytes = 103

    /// A pure function of the directory, so the launcher and every client that
    /// connects later arrive at the same socket without storing it anywhere.
    static func paths(for directory: URL) -> Paths {
        let own = directory.appending(path: "qga.sock").path
        guard own.utf8.count > maxSocketPathBytes else {
            return Paths(directory: directory, socketDirectory: directory)
        }
        return Paths(directory: directory,
                     socketDirectory: URL(fileURLWithPath: "/tmp/cd-vm-\(shortID(directory.path))"))
    }

    /// FNV-1a: Swift's own `hashValue` changes on every launch.
    static func shortID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(String(hash, radix: 16).prefix(10))
    }

    // MARK: - Arguments

    /// QEMU splits option values on commas; a literal one is written twice.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }

    /// The full argument list (without the executable).
    ///
    /// Against `start.sh`: no `-daemonize` (it forks after the Hypervisor
    /// framework has initialised Objective-C, and the first `snapshot-save`
    /// then aborts in the child — observed); `-rtc base=localtime`, because
    /// Windows keeps the RTC in local time and was an hour off without it; and
    /// the disk gets a node name so snapshot jobs can name it.
    static func arguments(for vm: VirtualMachine, paths: Paths, vncDisplay: Int) -> [String] {
        let dir = paths.directory
        func file(_ path: String) -> String {
            escape(path.hasPrefix("/") ? path : dir.appending(path: path).path)
        }
        var args = [
            "-name", escape(vm.id),
            "-M", "virt", "-accel", "hvf", "-cpu", "host",
            "-smp", "\(vm.cpus)", "-m", "\(vm.memoryMiB)M",
            "-rtc", "base=localtime",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(escape(firmwareCode))",
            "-drive", "if=pflash,format=raw,file=\(file("vars.fd"))",
            "-device", "ramfb", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
            "-drive", "file=\(file(vm.disk)),format=qcow2,if=none,id=d0,node-name=\(diskNode)",
            "-device", "nvme,drive=d0,serial=cd0,bootindex=1",
        ]
        for (index, drive) in vm.extraDrives.enumerated() {
            let id = "x\(index)"
            var options = "file=\(file(drive.path)),if=none,id=\(id)"
            if drive.cdrom { options += ",media=cdrom" }
            if drive.readOnly { options += ",readonly=on" }
            args += ["-drive", options, "-device", "usb-storage,drive=\(id),removable=on"]
        }
        args += [
            "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
            "-device", "virtio-serial-pci",
            "-chardev", "socket,path=\(escape(paths.qga)),server=on,wait=off,id=qga0",
            "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
            "-display", "none",
            "-vnc", "127.0.0.1:\(vncDisplay),password=on",
            "-qmp", "unix:\(escape(paths.qmp)),server=on,wait=off",
        ]
        return args
    }

    // MARK: - VNC display

    /// The first display from 1 up whose port nobody listens on. Display 0 is
    /// left alone: 5900 is macOS Screen Sharing.
    /// shortcut: two machines started in the same instant can pick the same
    /// display; the second QEMU then fails to bind and says so in qemu.log.
    static func freeVNCDisplay(in range: ClosedRange<Int> = 1...99) -> Int? {
        range.first { isPortFree(UInt16(5900 + $0)) }
    }

    static func isPortFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: - Spawning

    /// Starts QEMU in its own session so it outlives the app, with the
    /// machine's directory as its working directory and its output in
    /// `qemu.log`. Returns the pid, which is also written to `qemu.pid`.
    static func spawn(arguments: [String], paths: Paths) throws -> pid_t {
        guard FileManager.default.isExecutableFile(atPath: qemu) else { throw Failure.qemuMissing }
        try FileManager.default.createDirectory(at: paths.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for socket in [paths.qmp, paths.qga] { unlink(socket) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, paths.log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, paths.directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETSID: no controlling terminal, no SIGHUP when the app goes.
        // CLOEXEC_DEFAULT: none of the app's descriptors leak into QEMU.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = ([qemu] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, qemu, &actions, &attributes, argv, environ)
        guard result == 0 else { throw Failure.spawn(result) }

        // QEMU is our child until the app quits: reap it, or a stopped machine
        // lingers as a zombie that `kill(pid, 0)` still reports alive.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        try "\(pid)\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
        return pid
    }
}
