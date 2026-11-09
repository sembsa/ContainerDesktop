import CoreGraphics
import Foundation
import ImageIO

/// One VNC input event, or a pause between two of them.
enum VMInputStep: Equatable, Sendable {
    case key(UInt32, down: Bool)
    /// `buttons` is the RFB mask: 1 left, 2 middle, 4 right.
    case pointer(buttons: UInt8, x: Int, y: Int)
    case wait(milliseconds: Int)
}

/// Text, key combos and clicks as VNC event sequences. Pure, so it is tested
/// without a machine.
///
/// QEMU turns each keysym back into a PC scancode through its `en-us` keymap and
/// never adds a modifier on its own, so "A" or "!" only arrive shifted if Shift
/// is pressed around them. That assumes a US (or Polish programmer's) layout in
/// the guest.
enum VMInput {
    static let shift: UInt32 = 0xffe1
    static let returnKey: UInt32 = 0xff0d
    private static let shiftedSymbols = Set("~!@#$%^&*()_+{}|:\"<>?")

    /// The events that type `text`, and the characters outside ASCII. Those are
    /// still sent (as Unicode keysyms), but QEMU's `en-us` keymap has no scancode
    /// for them, so they are most likely dropped.
    static func typing(_ text: String) -> (steps: [VMInputStep], nonASCII: [Character]) {
        var steps: [VMInputStep] = []
        var nonASCII: [Character] = []
        for character in text {
            // Swift reads "\r\n" as one Character.
            if character == "\n" || character == "\r\n" || character == "\r" {
                steps += press(returnKey)
                continue
            }
            if character == "\t" {
                steps += press(0xff09)
                continue
            }
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
                nonASCII.append(character)
                continue
            }
            let value = scalar.value
            if value >= 0x20 && value < 0x7f {
                let needsShift = ("A"..."Z").contains(character) || shiftedSymbols.contains(character)
                steps += needsShift ? [.key(shift, down: true)] + press(value) + [.key(shift, down: false)] : press(value)
            } else if value >= 0xa0 {
                nonASCII.append(character)
                // Latin-1 keysyms equal their code points; past that X11 offsets by 0x01000000.
                steps += press(value < 0x100 ? value : 0x0100_0000 | value)
            } else {
                nonASCII.append(character) // other control characters: nothing sensible to send
            }
        }
        return (steps, nonASCII)
    }

    private static func press(_ keysym: UInt32) -> [VMInputStep] {
        [.key(keysym, down: true), .key(keysym, down: false)]
    }

    static let namedKeys: [String: UInt32] = {
        var keys: [String: UInt32] = [
            "ctrl": 0xffe3, "control": 0xffe3, "shift": 0xffe1, "alt": 0xffe9, "altgr": 0xfe03,
            "win": 0xffeb, "super": 0xffeb, "meta": 0xffeb, "cmd": 0xffeb,
            "enter": 0xff0d, "return": 0xff0d, "tab": 0xff09, "esc": 0xff1b, "escape": 0xff1b,
            "backspace": 0xff08, "delete": 0xffff, "del": 0xffff, "insert": 0xff63, "ins": 0xff63,
            "home": 0xff50, "end": 0xff57, "pageup": 0xff55, "pgup": 0xff55, "pagedown": 0xff56, "pgdn": 0xff56,
            "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54,
            "space": 0x20, "plus": 0x2b, "printscreen": 0xff61, "menu": 0xff67, "capslock": 0xffe5,
        ]
        for n in 1...12 { keys["f\(n)"] = 0xffbe + UInt32(n - 1) }
        return keys
    }()

    /// "ctrl+alt+delete", "win+r", "f5": pressed left to right, released right to left.
    static func combo(_ spec: String) throws -> [VMInputStep] {
        let names = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !names.isEmpty, !names.contains("") else {
            throw InvalidParams("key '\(spec)' must look like ctrl+alt+delete (write 'plus' for the + key)")
        }
        let keysyms: [UInt32] = try names.map { name in
            if let keysym = namedKeys[name] { return keysym }
            if name.count == 1, let scalar = name.unicodeScalars.first, scalar.value > 0x20, scalar.value < 0x7f {
                return scalar.value
            }
            throw InvalidParams("unknown key '\(name)' in '\(spec)'")
        }
        return keysyms.map { .key($0, down: true) } + keysyms.reversed().map { .key($0, down: false) }
    }

    static func buttonMask(_ name: String) throws -> UInt8 {
        switch name {
        case "left": 1
        case "middle": 2
        case "right": 4
        default: throw InvalidParams("button must be left, right or middle")
        }
    }

    /// Move first, then press and release: some UIs ignore a press that arrives
    /// with the pointer still somewhere else. Coordinates are absolute (usb-tablet).
    static func click(x: Int, y: Int, buttons: UInt8, double: Bool) -> [VMInputStep] {
        var steps: [VMInputStep] = [.pointer(buttons: 0, x: x, y: y), .wait(milliseconds: 50)]
        for index in 0..<(double ? 2 : 1) {
            if index > 0 { steps.append(.wait(milliseconds: 50)) }
            steps += [.pointer(buttons: buttons, x: x, y: y), .wait(milliseconds: 50), .pointer(buttons: 0, x: x, y: y)]
        }
        return steps
    }
}

/// The QEMU machine tools: power, screen, keyboard and mouse over VNC, commands
/// and files through the guest agent, snapshots. Every one but `vm_list` needs the
/// machine's `agentControl` switched on by the user.
enum VMTools {
    // MARK: - Machine lookup

    /// The machine by directory name (or display name), refused unless the user opted in.
    static func machine(_ id: String, in root: URL = VirtualMachineStore.directory, requireControl: Bool = true) throws -> VirtualMachine {
        let machines = VirtualMachineStore.scan(root)
        guard let vm = machines.first(where: { $0.id == id }) ?? machines.first(where: { $0.name == id }) else {
            throw ToolFailure("No virtual machine '\(id)'. vm_list shows the ids.")
        }
        guard vm.agentControl || !requireControl else {
            throw ToolFailure("""
                Virtual machine '\(vm.id)' does not allow agent control. Only the user can allow it: \
                in Container Desktop, open Virtual Machines, select "\(vm.name)" and switch on \
                "Allow the AI agent to control this machine". Ask the user to do that, then retry.
                """)
        }
        return vm
    }

    private static func running(_ args: ToolArguments) throws -> VirtualMachine {
        let vm = try machine(try args.requiredString("id"))
        guard vm.isRunning else { throw ToolFailure("Virtual machine '\(vm.id)' is not running. Start it with vm_start.") }
        return vm
    }

    // MARK: - Host paths

    /// An absolute host path inside the user's home, with symlinks resolved, so a
    /// link cannot carry a copy outside it.
    static func hostPath(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw InvalidParams("host path '\(path)' must be absolute") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: resolved.path) { resolved = resolved.resolvingSymlinksInPath() }
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(homePath + "/") else {
            throw ToolFailure("Refused: host path '\(path)' is outside the home directory (\(homePath)).")
        }
        return resolved
    }

    // MARK: - VNC

    static let connectTimeout: Duration = .seconds(10)

    /// Waits for the first event `match` accepts; a timer closes the connection
    /// if none comes in time, which ends the stream.
    private static func firstEvent<T>(_ client: RFBClient, _ match: (RFBClient.Event) -> T?) async throws -> T {
        let timer = Task {
            try await Task.sleep(for: connectTimeout)
            await client.stop()
        }
        defer { timer.cancel() }
        for await event in client.events {
            if let value = match(event) { return value }
            if case .disconnected(let reason) = event {
                throw ToolFailure("VNC: \(reason ?? "no answer within \(connectTimeout)")")
            }
        }
        throw ToolFailure("VNC connection closed")
    }

    static func screenshot(_ vm: VirtualMachine) async throws -> CGImage {
        let client = RFBClient(port: vm.vncPort, password: vm.vncPassword)
        await client.start()
        do {
            // The first frame answers the full (non-incremental) request sent after the handshake.
            let image = try await firstEvent(client) { event -> CGImage? in
                if case .frame(let frame) = event { return frame.image }
                return nil
            }
            await client.stop()
            return image
        } catch {
            await client.stop()
            throw error
        }
    }

    /// Connects, checks the steps against the screen, replays them, and always
    /// lets go of every key and button it pressed before disconnecting.
    @discardableResult
    static func send(_ vm: VirtualMachine, _ makeSteps: (_ width: Int, _ height: Int) throws -> [VMInputStep]) async throws -> (width: Int, height: Int) {
        let client = RFBClient(port: vm.vncPort, password: vm.vncPassword)
        await client.start()
        do {
            let size = try await firstEvent(client) { event -> (Int, Int)? in
                if case .connected(let width, let height, _) = event { return (width, height) }
                return nil
            }
            let steps = try makeSteps(size.0, size.1)
            var pressed: [UInt32] = []
            var buttons = false
            var last = (x: 0, y: 0)
            for step in steps {
                if Task.isCancelled { break }
                switch step {
                case .key(let keysym, let down):
                    client.sendKey(keysym, down: down)
                    if down { pressed.append(keysym) } else { pressed.removeAll { $0 == keysym } }
                    // QEMU's USB keyboard queue is short; a burst overflows it and drops keys.
                    try? await Task.sleep(for: .milliseconds(20))
                case .pointer(let mask, let x, let y):
                    client.sendPointer(buttons: mask, x: x, y: y)
                    buttons = mask != 0
                    last = (x, y)
                case .wait(let ms):
                    try? await Task.sleep(for: .milliseconds(ms))
                }
            }
            for keysym in pressed.reversed() { client.sendKey(keysym, down: false) }
            if buttons { client.sendPointer(buttons: 0, x: last.x, y: last.y) }
            // `cancel()` can drop bytes not yet handed to the socket.
            try? await Task.sleep(for: .milliseconds(150))
            await client.stop()
            return size
        } catch {
            await client.stop()
            throw error
        }
    }

    static func png(_ image: CGImage, scale: Double) throws -> (data: Data, width: Int, height: Int) {
        var image = image
        if scale != 1 {
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ToolFailure("could not scale the screenshot")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { throw ToolFailure("could not scale the screenshot") }
            image = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ToolFailure("could not encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolFailure("could not encode PNG") }
        return (data as Data, image.width, image.height)
    }

    // MARK: - Guest agent

    /// Runs `body` with the machine's agent, then lets go of the socket: the
    /// agent's chardev takes one client, and the app may want it next.
    private static func withAgent<T>(_ vm: VirtualMachine, _ body: (QGAClient) async throws -> T) async throws -> T {
        let agent = QGAClient.shared(for: vm.directory)
        do {
            let value = try await body(agent)
            await agent.close()
            return value
        } catch QEMUSocket.Failure.timeout {
            await agent.close()
            throw ToolFailure("The guest agent did not answer in time (the command may still be running in the guest).")
        } catch QEMUSocket.Failure.connect(_, let code) {
            await agent.close()
            throw ToolFailure("Cannot reach the guest agent of '\(vm.id)' (\(String(cString: strerror(code)))). Is qemu-ga installed and running in the guest?")
        } catch QEMUSocket.Failure.qemu(let message) {
            await agent.close()
            throw ToolFailure("Guest agent: \(message)")
        } catch {
            await agent.close()
            throw error
        }
    }

    /// The .cmd prologue: no echoed prompt lines, and the console code page set to
    /// UTF-8 so cmd reads the rest of the (UTF-8) script — and writes its output — as UTF-8.
    /// Verified on Polish Windows 11 (OEMCP 852): without it, `echo x> zażółć.txt` from a
    /// UTF-8 script creates `za┼╝├│┼é─ç.txt`; with it, `zażółć.txt`. `echo` alone round-trips
    /// either way (bytes in, same bytes out), so it proves nothing.
    static func windowsScript(_ command: String) -> String {
        "@echo off\r\nchcp 65001 >nul\r\n" + command
    }

    // MARK: - Tools

    private static let idOnly = #"{"type":"object","properties":{"id":{"type":"string","description":"VM id from vm_list"}},"required":["id"]}"#

    static let all: [MCPTool] = [
        MCPTool(
            name: "vm_list",
            description: "List the QEMU virtual machines (Windows VMs) Container Desktop manages: id, name, os, running, agentControl, cpus, memoryMiB (vm_screenshot reports the screen size). Every other vm_* tool works only on a VM with agentControl=true.",
            schema: #"{"type":"object","properties":{}}"#,
            readOnly: true
        ) { _ in
            let rows = VirtualMachineStore.scan(VirtualMachineStore.directory).map { vm -> JSONValue in
                .object([
                    "id": .string(vm.id), "name": .string(vm.name), "os": .string(vm.os),
                    "running": .bool(vm.isRunning), "agentControl": .bool(vm.agentControl),
                    "cpus": .number(Double(vm.cpus)), "memoryMiB": .number(Double(vm.memoryMiB)),
                ])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return .text(String(decoding: try encoder.encode(JSONValue.array(rows)), as: UTF8.self))
        },
        MCPTool(name: "vm_start", description: "Boot a virtual machine. Returns once QEMU runs; the guest OS is still booting (watch it with vm_screenshot).", schema: idOnly) { args in
            let vm = try machine(try args.requiredString("id"))
            guard !vm.isRunning else { return .text("'\(vm.id)' is already running.") }
            try await VMEngine.start(vm)
            return .text("Started '\(vm.id)'. The guest is booting.")
        },
        MCPTool(name: "vm_stop", description: "Ask the guest OS to shut down cleanly (guest agent, else the ACPI power button). Does not wait; check vm_list.", schema: idOnly) { args in
            let vm = try running(args)
            try await VMEngine.stop(vm)
            return .text("Shutdown requested for '\(vm.id)'.")
        },
        MCPTool(
            name: "vm_force_stop",
            description: "Kill the VM at once, like pulling the plug. Unsaved work in the guest is lost.",
            schema: idOnly,
            destructive: true
        ) { args in
            let vm = try running(args)
            try await VMEngine.forceStop(vm)
            return .text("Stopped '\(vm.id)'.")
        },
        MCPTool(
            name: "vm_screenshot",
            description: "PNG of the VM's screen over VNC. Coordinates for vm_click are pixels of the full-size screen (scale 1).",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"scale":{"type":"number","description":"0.1–1, shrinks the image (default 1)"}},"required":["id"]}"#,
            readOnly: true
        ) { args in
            let vm = try running(args)
            let scale: Double
            switch args.values["scale"] {
            case nil, .null: scale = 1
            case .number(let value) where value >= 0.1 && value <= 1: scale = value
            default: throw InvalidParams("'scale' must be a number from 0.1 to 1")
            }
            let image = try await screenshot(vm)
            let png = try png(image, scale: scale)
            var note = "screen \(image.width)x\(image.height); coordinates for vm_click are pixels of this image"
            if scale != 1 {
                note = "screen \(image.width)x\(image.height), image scaled to \(png.width)x\(png.height) (scale \(scale)); vm_click takes full-size screen pixels, so divide this image's coordinates by \(scale)"
            }
            return MCPToolResult(content: [.image(png.data, mimeType: "image/png"), .text(note)])
        },
        MCPTool(
            name: "vm_click",
            description: "Mouse click at x,y in full-size screen pixels (as vm_screenshot at scale 1 shows them).",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"string","enum":["left","right","middle"],"description":"default left"},"double":{"type":"boolean","description":"double-click"}},"required":["id","x","y"]}"#
        ) { args in
            let vm = try running(args)
            guard let x = try args.int("x"), let y = try args.int("y") else { throw InvalidParams("'x' and 'y' are required") }
            let button = try args.string("button") ?? "left"
            let mask = try VMInput.buttonMask(button)
            let double = try args.bool("double") ?? false
            try await send(vm) { width, height in
                guard (0..<width).contains(x), (0..<height).contains(y) else {
                    throw ToolFailure("(\(x), \(y)) is outside the \(width)x\(height) screen.")
                }
                return VMInput.click(x: x, y: y, buttons: mask, double: double)
            }
            return .text("\(double ? "Double-clicked" : "Clicked") \(button) at (\(x), \(y)).")
        },
        MCPTool(
            name: "vm_type",
            description: "Type text on the VM's keyboard (US layout; newline = Enter). Only ASCII types reliably: for other characters (ą, ę, ł…) use vm_exec or write a file.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"}},"required":["id","text"]}"#
        ) { args in
            let vm = try running(args)
            let text = try args.requiredString("text")
            let typing = VMInput.typing(text)
            try await send(vm) { _, _ in typing.steps }
            var message = "Typed \(text.count) characters."
            if !typing.nonASCII.isEmpty {
                message += " Not ASCII, probably not typed (QEMU's keymap has no key for them): \(String(typing.nonASCII)). Use vm_exec, or a file via vm_copy_in, for such text."
            }
            return .text(message)
        },
        MCPTool(
            name: "vm_key",
            description: "Press a key or combination: \"enter\", \"tab\", \"esc\", \"f5\", \"win+r\", \"alt+f4\", \"ctrl+shift+esc\", \"ctrl+alt+delete\". Keys go down left to right and up in reverse.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"keys":{"type":"string"}},"required":["id","keys"]}"#
        ) { args in
            let vm = try running(args)
            let keys = try args.requiredString("keys")
            let steps = try VMInput.combo(keys)
            try await send(vm) { _, _ in steps }
            return .text("Pressed \(keys).")
        },
        MCPTool(
            name: "vm_exec",
            description: "Run a command line in the guest through the guest agent and wait for it. Windows: run by cmd.exe as a batch script (UTF-8), so `a & b`, pipes and redirects work. Returns exit code, stdout and stderr.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"command":{"type":"string"},"timeout":{"type":"integer","description":"Seconds (default 120)"}},"required":["id","command"]}"#,
            destructive: true
        ) { args in
            let vm = try running(args)
            let command = try args.requiredString("command")
            let timeout = Duration.seconds(max(1, try args.int("timeout") ?? 120))
            let result = try await withAgent(vm) { agent in
                vm.isWindows
                    ? try await agent.runScript(windowsScript(command), timeout: timeout)
                    : try await agent.exec("/bin/sh", ["-c", command], timeout: timeout)
            }
            let exit = result.exitCode.map(String.init) ?? "unknown"
            return MCPToolResult(content: [.text(MCPToolResult.truncated(
                "exit code: \(exit)\n--- stdout ---\n\(result.output)\n--- stderr ---\n\(result.errorOutput)"))],
                isError: result.exitCode != 0)
        },
        MCPTool(
            name: "vm_copy_in",
            description: "Copy a host file (inside your home directory) to a path in the guest, replacing it if it exists.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"hostPath":{"type":"string","description":"Absolute, inside the home directory"},"guestPath":{"type":"string","description":"e.g. C:\\Users\\agent\\Desktop\\file.txt"}},"required":["id","hostPath","guestPath"]}"#,
            destructive: true
        ) { args in
            let vm = try running(args)
            let source = try hostPath(try args.requiredString("hostPath"))
            let guestPath = try args.requiredString("guestPath")
            let data = try Data(contentsOf: source)
            try await withAgent(vm) { try await $0.writeFile(guestPath, data) }
            return .text("Copied \(data.count) bytes to \(guestPath).")
        },
        MCPTool(
            name: "vm_copy_out",
            description: "Copy a guest file to a host path inside your home directory. Refuses to replace an existing host file unless overwrite=true.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"guestPath":{"type":"string"},"hostPath":{"type":"string","description":"Absolute file path, inside the home directory"},"overwrite":{"type":"boolean"}},"required":["id","guestPath","hostPath"]}"#,
            destructive: true
        ) { args in
            let vm = try running(args)
            let guestPath = try args.requiredString("guestPath")
            let target = try hostPath(try args.requiredString("hostPath"))
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { throw ToolFailure("\(target.path) is a directory; give a file path.") }
                guard try args.bool("overwrite") == true else {
                    throw ToolFailure("\(target.path) exists. Pass overwrite=true to replace it.")
                }
            }
            let data = try await withAgent(vm) { try await $0.readFile(guestPath) }
            try data.write(to: target, options: .atomic)
            return .text("Copied \(data.count) bytes to \(target.path).")
        },
        MCPTool(
            name: "vm_snapshot_list",
            description: "List the VM's snapshots (tag, memory state size, date).",
            schema: idOnly,
            readOnly: true
        ) { args in
            let vm = try machine(try args.requiredString("id"))
            let snapshots = try await VMEngine.snapshots(of: vm)
            guard !snapshots.isEmpty else { return .text("No snapshots.") }
            return .text(snapshots.map { snapshot in
                "\(snapshot.tag)\t\(snapshot.hasMemory ? "disk+memory \(snapshot.vmStateSize)" : "disk only")\t\(snapshot.date.map { ISO8601DateFormatter().string(from: $0) } ?? "-")"
            }.joined(separator: "\n"))
        },
        MCPTool(
            name: "vm_snapshot_create",
            description: "Snapshot the VM. While it runs this saves memory too (the guest pauses for a few seconds).",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"tag":{"type":"string","description":"Name; default is a timestamp"}},"required":["id"]}"#
        ) { args in
            let vm = try machine(try args.requiredString("id"))
            let tag = VMSnapshotParser.sanitize(try args.string("tag") ?? VMEngine.suggestedSnapshotTag())
            try await VMEngine.createSnapshot(tag, of: vm)
            return .text("Created snapshot '\(tag)'.")
        },
        MCPTool(
            name: "vm_snapshot_restore",
            description: "Return the VM to a snapshot. Everything since is lost; a running VM is restarted into it.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"tag":{"type":"string"}},"required":["id","tag"]}"#,
            destructive: true
        ) { args in
            let vm = try machine(try args.requiredString("id"))
            let tag = try args.requiredString("tag")
            // Checked first: on a running VM the engine stops it before it finds out.
            guard try await VMEngine.snapshots(of: vm).contains(where: { $0.tag == tag }) else {
                throw ToolFailure("No snapshot '\(tag)'. vm_snapshot_list shows the tags.")
            }
            try await VMEngine.restoreSnapshot(tag, of: vm)
            return .text("Restored '\(vm.id)' to '\(tag)'.")
        },
    ]
}
