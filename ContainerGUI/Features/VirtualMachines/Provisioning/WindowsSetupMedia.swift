import Foundation

/// Builds the small "CDSETUP" CD that turns a stock Windows 11 ARM64 ISO into a
/// hands-off install: `autounattend.xml` (Setup finds it on any removable drive),
/// `cd-setup.cmd` (run once at first logon), our own qemu-ga package with
/// `install.cmd`, and the display helper (`WindowsDisplayHelper`). The Windows
/// ISO itself is never modified.
///
/// What the guest ends up with: a local administrator who logs on automatically,
/// the virtio NetKVM / vioserial / viogpudo drivers, the QEMU-GA service with VSS,
/// no sleep or hibernation — and then it powers itself off, so the install run is
/// over when QEMU exits. See `WindowsQEMUArguments` for the drives and the boot
/// keypress the install run needs.
enum WindowsSetupMedia {
    struct Options: Sendable, Equatable {
        var vmName: String
        var username: String
        var password: String
        /// UI language, system and user locale, e.g. "pl-PL". Must be a language
        /// the ISO carries — `language(ofISO:)` reads it.
        var locale: String
        /// `InputLocale`: a locale name ("pl-PL" = that language's default
        /// keyboard) or "0415:00000415". Nil means the locale's default.
        var keyboard: String? = nil
        /// `/IMAGE/NAME` inside install.wim.
        var edition = "Windows 11 Pro"
    }

    /// Microsoft's public generic installation key for Pro: selects the edition
    /// so Setup does not ask, and does not activate anything.
    static let genericProKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    /// Folder name `install.cmd` expects beside itself.
    static let guestAgentFolder = "qemu-ga-windows-arm64"

    // MARK: - Pure generation

    static func autounattendXML(_ o: Options) -> String {
        let user = xmlEscape(o.username), pass = xmlEscape(o.password)
        let locale = xmlEscape(o.locale), input = xmlEscape(o.keyboard ?? o.locale)
        let component = { (name: String) in
            #"<component name="\#(name)" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">"#
        }
        let international = """
              <InputLocale>\(input)</InputLocale>
              <SystemLocale>\(locale)</SystemLocale>
              <UILanguage>\(locale)</UILanguage>
              <UserLocale>\(locale)</UserLocale>
        """
        let labConfig = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"].enumerated().map { i, v in
            #"        <RunSynchronousCommand wcm:action="add"><Order>\#(i + 1)</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v \#(v) /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"#
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            \(component("Microsoft-Windows-International-Core-WinPE"))
              <SetupUILanguage><UILanguage>\(locale)</UILanguage></SetupUILanguage>
        \(international)
            </component>
            \(component("Microsoft-Windows-Setup"))
              <RunSynchronous>
        \(labConfig)
              </RunSynchronous>
              <DiskConfiguration>
                <Disk wcm:action="add">
                  <DiskID>0</DiskID>
                  <WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>
              <ImageInstall>
                <OSImage>
                  <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>\(xmlEscape(o.edition))</Value></MetaData></InstallFrom>
                  <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                </OSImage>
              </ImageInstall>
              <UserData>
                <AcceptEula>true</AcceptEula>
                <ProductKey><Key>\(genericProKey)</Key><WillShowUI>Never</WillShowUI></ProductKey>
              </UserData>
            </component>
          </settings>
          <settings pass="specialize">
            \(component("Microsoft-Windows-Shell-Setup"))
              <ComputerName>\(computerName(from: o.vmName))</ComputerName>
            </component>
          </settings>
          <settings pass="oobeSystem">
            \(component("Microsoft-Windows-International-Core"))
        \(international)
            </component>
            \(component("Microsoft-Windows-Shell-Setup"))
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(user)</Name>
                    <Group>Administrators</Group>
                    <Password><Value>\(pass)</Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled>
                <Username>\(user)</Username>
                <Password><Value>\(pass)</Value><PlainText>true</PlainText></Password>
                <LogonCount>9999</LogonCount>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <CommandLine>cmd /c for %d in (D E F G H I J K) do if exist %d:\\cd-setup.cmd call %d:\\cd-setup.cmd</CommandLine>
                </SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>

        """
    }

    /// Runs elevated at first logon from the CDSETUP drive. The virtio-win ISO is
    /// found by its NetKVM folder; viogpudo is only staged here (the install run
    /// has ramfb, not virtio-gpu) and binds when a normal run brings the device.
    static func setupScript() -> String {
        crlf(#"""
        @echo off
        rem Container Desktop: first-logon setup. Drivers, guest agent, power, then power off.
        set LOG=C:\Windows\Temp\cd-setup.log
        echo start %date% %time% > %LOG%
        set V=
        for %%d in (D E F G H I J K) do if exist %%d:\NetKVM\w11\ARM64\netkvm.inf set V=%%d:
        echo virtio=%V% >> %LOG%
        for %%i in (NetKVM\w11\ARM64\netkvm.inf vioserial\w11\ARM64\vioser.inf viogpudo\w11\ARM64\viogpudo.inf) do pnputil /add-driver %V%\%%i /install >> %LOG% 2>&1
        call "%~dp0install.cmd" >> %LOG% 2>&1
        echo qemu-ga=%errorlevel% >> %LOG%
        powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0\#(WindowsDisplayHelper.installerFile)" >> %LOG% 2>&1
        echo display-helper=%errorlevel% >> %LOG%
        powercfg /change monitor-timeout-ac 0
        powercfg /change standby-timeout-ac 0
        powercfg /hibernate off
        sc query QEMU-GA >> %LOG% 2>&1
        echo done %date% %time% >> %LOG%
        shutdown /s /t 10 /c "Container Desktop: setup complete"
        """#)
    }

    /// NetBIOS rules: at most 15 characters, letters, digits and hyphens, not
    /// only digits.
    static func computerName(from vmName: String) -> String {
        let allowed = vmName.uppercased().unicodeScalars.map {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-"
        }
        var name = String(allowed).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        name = String(name.prefix(15)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty || name.allSatisfy(\.isNumber) ? "WIN-VM" : name
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// `sources/lang.ini` names the ISO's UI languages; the first one is it.
    static func language(fromLangIni text: String) -> String? {
        var inSection = false
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inSection = line.lowercased() == "[available ui languages]"; continue }
            guard inSection, let key = line.split(separator: "=").first else { continue }
            let tag = key.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { continue }
            // lang.ini says "pl-pl"; unattend wants "pl-PL".
            let parts = tag.split(separator: "-")
            return parts.count == 2 ? "\(parts[0].lowercased())-\(parts[1].uppercased())" : tag
        }
        return nil
    }

    static func crlf(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    // MARK: - Building the ISO

    /// Writes the CDSETUP ISO to `output` (replacing it). `guestTools` holds
    /// `install.cmd` and the `qemu-ga-*-windows-arm64.zip`; the app bundle by default.
    static func buildISO(
        _ options: Options,
        output: URL,
        guestTools: URL = Bundle.main.resourceURL!
    ) async throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appending(path: "cdsetup-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        try autounattendXML(options).write(to: stage.appending(path: "autounattend.xml"), atomically: true, encoding: .utf8)
        try setupScript().write(to: stage.appending(path: "cd-setup.cmd"), atomically: true, encoding: .utf8)
        let install = try String(contentsOf: guestTools.appending(path: "install.cmd"), encoding: .utf8)
        try crlf(install).write(to: stage.appending(path: "install.cmd"), atomically: true, encoding: .utf8)
        for name in [WindowsDisplayHelper.helperFile, WindowsDisplayHelper.installerFile] {
            try fm.copyItem(at: guestTools.appending(path: name), to: stage.appending(path: name))
        }

        guard let zip = try fm.contentsOfDirectory(at: guestTools, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("qemu-ga-") && $0.pathExtension == "zip" }) else {
            throw CLIError.command(exitCode: -1, stderr: "qemu-ga package missing from \(guestTools.path)")
        }
        let unpacked = stage.appending(path: "unpacked")
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        // The zip holds one versioned folder; install.cmd wants a fixed name.
        guard let folder = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.hasDirectoryPath }) else {
            throw CLIError.command(exitCode: -1, stderr: "qemu-ga package is empty")
        }
        try fm.moveItem(at: folder, to: stage.appending(path: guestAgentFolder))
        try fm.removeItem(at: unpacked)

        try? fm.removeItem(at: output)
        try await run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "CDSETUP",
                                           "-o", output.path, stage.path])
    }

    /// The ISO's language, read from `sources/lang.ini` on a read-only mount.
    /// Nil when the ISO cannot be mounted or carries no lang.ini.
    static func language(ofISO iso: URL) async -> String? {
        let mount = FileManager.default.temporaryDirectory.appending(path: "winiso-\(UUID().uuidString)")
        do {
            try await run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mount.path, iso.path])
        } catch { return nil }
        let text = try? String(contentsOf: mount.appending(path: "sources/lang.ini"), encoding: .utf8)
        // Detach before QEMU opens the ISO: a mounted image fails its "consistent read" lock.
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path])
        return text.flatMap(language(fromLangIni:))
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) async throws -> String {
        let r = try await ProcessRunner.run(executable: tool, arguments: args, timeout: .seconds(300))
        guard r.exitCode == 0 else { throw CLIError.command(exitCode: r.exitCode, stderr: r.stderr) }
        return r.stdout
    }
}
