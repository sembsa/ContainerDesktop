import Foundation

/// The cloud-init NoCloud seed that turns a stock Ubuntu cloud image into a
/// machine with our user, the QEMU guest agent and, optionally, a desktop: a
/// small CD labelled `cidata` holding `user-data` and `meta-data`. cloud-init
/// reads it on the first boot only (it keys on `instance-id`).
///
/// Like Windows Setup, the run ends by powering the guest off, so QEMU exiting
/// is what says "done" — see `LinuxInstaller`.
enum LinuxCloudInit {
    struct Options: Sendable, Equatable {
        var hostname: String
        var username: String
        var password: String
        var desktop: Bool
        var language: Language = .polish
        /// An XKB layout: "pl", "us", "de", …
        var keyboard = "pl"
        /// An IANA zone; the host's by default, so the guest's clock reads the same.
        var timezone = TimeZone.current.identifier
    }

    enum Language: String, CaseIterable, Sendable, Identifiable {
        case polish = "pl", english = "en", chinese = "zh-Hans"
        var id: String { rawValue }

        var locale: String {
            switch self {
            case .polish: "pl_PL.UTF-8"
            case .english: "en_US.UTF-8"
            case .chinese: "zh_CN.UTF-8"
            }
        }

        /// Translations; GNOME's own come in a separate pack.
        func packages(desktop: Bool) -> [String] {
            let pack: String? = switch self {
            case .polish: "pl"
            case .english: nil
            case .chinese: "zh-hans"
            }
            guard let pack else { return [] }
            return ["language-pack-\(pack)"] + (desktop ? ["language-pack-gnome-\(pack)"] : [])
        }

        /// The app's own language, Polish when it has none of these.
        static var preferred: Language {
            Bundle.main.preferredLocalizations.lazy.compactMap(Language.init(rawValue:)).first ?? .polish
        }
    }

    static let keyboards = ["pl", "us", "gb", "de", "fr"]

    // MARK: - Pure generation

    static func userData(_ o: Options) -> String {
        var packages = ["qemu-guest-agent"] + o.language.packages(desktop: o.desktop)
        if o.desktop { packages += ["ubuntu-desktop-minimal", "spice-vdagent"] }
        let user = o.username, home = "/home/\(o.username)"

        var text = """
        #cloud-config
        hostname: \(o.hostname)
        locale: \(o.language.locale)
        keyboard:
          layout: \(o.keyboard)
        timezone: \(o.timezone)
        ssh_pwauth: true
        users:
          - name: \(user)
            gecos: \(user)
            groups: [adm, sudo]
            shell: /bin/bash
            lock_passwd: false
            plain_text_passwd: \(yamlString(o.password))
        package_update: true
        packages:
        \(packages.map { "  - \($0)" }.joined(separator: "\n"))

        """
        if o.desktop {
            // Deferred until after `packages`: custom.conf is gdm3's conffile.
            text += """
            write_files:
              - path: /etc/gdm3/custom.conf
                defer: true
                content: |
                  [daemon]
                  AutomaticLoginEnable=true
                  AutomaticLogin=\(user)
              - path: /etc/dconf/profile/user
                defer: true
                content: |
                  user-db:user
                  system-db:local
              - path: /etc/dconf/db/local.d/00-containerdesktop
                defer: true
                content: |
                  [org/gnome/desktop/session]
                  idle-delay=uint32 0
                  [org/gnome/desktop/screensaver]
                  lock-enabled=false

            """
        }
        text += "runcmd:\n  - [systemctl, start, qemu-guest-agent]\n"
        if o.desktop {
            text += """
              - [dconf, update]
              # The desktop hands the network to NetworkManager, and networkd's
              # wait-online, now waiting for nothing, held up boot (and gdm) for 2 minutes.
              - [systemctl, disable, systemd-networkd-wait-online.service]
              - [systemctl, set-default, graphical.target]
              - [install, -d, -o, \(user), -g, \(user), \(home)/.config]
              - [sh, -c, 'echo yes > \(home)/.config/gnome-initial-setup-done && chown \(user): \(home)/.config/gnome-initial-setup-done']

            """
        }
        text += """
        power_state:
          mode: poweroff
          message: Container Desktop setup finished
          timeout: 30
          condition: true

        """
        return text
    }

    static func metaData(instanceID: String, hostname: String) -> String {
        "instance-id: \(instanceID)\nlocal-hostname: \(hostname)\n"
    }

    /// A JSON string is a valid YAML double-quoted scalar, escapes and all.
    static func yamlString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// RFC 1123 label from a machine's directory name: ASCII letters, digits, hyphens.
    static func hostname(from id: String) -> String {
        let ascii = id.lowercased().map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-")
        let label = String(ascii.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return label.isEmpty ? "ubuntu" : label
    }

    /// `useradd`'s default rule, minus names that already exist in the image.
    static func isValidUsername(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) != nil
            && !["root", "daemon", "bin", "sys", "sync", "nobody", "ubuntu", "syslog", "messagebus"].contains(name)
    }

    // MARK: - Seed ISO

    /// Writes the `cidata` ISO to `output` (replacing it).
    static func buildSeedISO(_ options: Options, instanceID: String, output: URL) async throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appending(path: "cidata-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try userData(options).write(to: stage.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try metaData(instanceID: instanceID, hostname: options.hostname)
            .write(to: stage.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: output)
        let r = try await ProcessRunner.run(
            executable: "/usr/bin/hdiutil",
            arguments: ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", output.path, stage.path],
            timeout: .seconds(120))
        guard r.exitCode == 0 else { throw CLIError.command(exitCode: r.exitCode, stderr: r.stderr) }
    }
}
