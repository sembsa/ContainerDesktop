import Foundation

/// Makes a Windows guest follow the preview window's size.
///
/// QEMU passes a VNC `SetDesktopSize` on to the virtio-gpu device, and viogpudo
/// then *accepts* that size as a mode — but never switches to it by itself, and
/// the guest agent cannot switch for it: it is a session-0 service, and display
/// modes belong to the signed-in user's session. So a small helper
/// (`display-helper.cs` in GuestTools, compiled in the guest by the installer)
/// runs at every logon as a scheduled task, watches `display-request.txt`, and
/// applies what the host writes there.
///
/// Installed by `cd-setup.cmd` on new machines, and through the agent on older
/// ones (`ensureInstalled`).
enum WindowsDisplayHelper {
    static let guestDirectory = #"C:\ProgramData\ContainerDesktop"#
    static let requestPath = guestDirectory + #"\display-request.txt"#
    static let helperFile = "display-helper.cs"
    static let installerFile = "display-helper-install.ps1"
    /// The installer compiles the helper from beside itself into `guestDirectory`.
    static let stagingDirectory = #"C:\Windows\Temp"#

    static var installCommand: String {
        "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \(stagingDirectory)\\\(installerFile)"
    }

    /// The id makes every request new to the helper, which applies a given
    /// text once — a single write raises several change events.
    static func requestText(width: Int, height: Int, id: String = UUID().uuidString) -> String {
        "\(width)x\(height) \(id)"
    }

    /// Installs the helper unless the guest already has this exact version.
    static func ensureInstalled(on dir: URL, guestTools: URL = Bundle.main.resourceURL!) async throws {
        let bundled = try Data(contentsOf: guestTools.appending(path: helperFile))
        let installed = try? await QGAClient.shared(for: dir).readFile(guestDirectory + "\\" + helperFile)
        if installed == bundled { return }
        try await install(on: dir, guestTools: guestTools)
    }

    /// Copies both scripts in, then registers and starts the logon task.
    static func install(on dir: URL, guestTools: URL = Bundle.main.resourceURL!) async throws {
        let qga = QGAClient.shared(for: dir)
        for name in [helperFile, installerFile] {
            try await qga.writeFile(stagingDirectory + "\\" + name, Data(contentsOf: guestTools.appending(path: name)))
        }
        let result = try await qga.runScript(installCommand, timeout: .seconds(120))
        guard result.exitCode == 0, result.output.contains("installed") else {
            throw CLIError.command(exitCode: Int32(result.exitCode ?? -1), stderr: result.errorOutput + result.output)
        }
    }

    /// Asks the helper for a new size. Send `RFBClient.setDesktopSize` with the
    /// same size first, or the driver may not accept it and the helper falls
    /// back to the closest mode it lists.
    static func request(width: Int, height: Int, on dir: URL) async throws {
        try await QGAClient.shared(for: dir).writeFile(requestPath, Data(requestText(width: width, height: height).utf8))
    }
}
