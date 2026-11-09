import XCTest

/// The cloud-init seed's text; the install itself was run live (see LinuxInstaller).
final class LinuxCloudInitTests: XCTestCase {

    private func options(desktop: Bool, password: String = "secret") -> LinuxCloudInit.Options {
        .init(hostname: "ubuntu-1", username: "anna", password: password, desktop: desktop,
              language: .polish, keyboard: "pl", timezone: "Europe/Warsaw")
    }

    func testServerSeedHasTheAgentAndPowersOffWithoutADesktop() {
        let text = LinuxCloudInit.userData(options(desktop: false))
        XCTAssertTrue(text.hasPrefix("#cloud-config\n"))
        for line in ["hostname: ubuntu-1", "locale: pl_PL.UTF-8", "  layout: pl", "timezone: Europe/Warsaw",
                     "ssh_pwauth: true", "  - name: anna", "    groups: [adm, sudo]", "    lock_passwd: false",
                     "  - qemu-guest-agent", "  - language-pack-pl", "  - [systemctl, start, qemu-guest-agent]",
                     "  mode: poweroff"] {
            XCTAssertTrue(text.contains(line + "\n"), line)
        }
        XCTAssertFalse(text.contains("ubuntu-desktop"))
        XCTAssertFalse(text.contains("gdm3"))
    }

    func testDesktopSeedLogsTheUserInAndNeverLocks() {
        let text = LinuxCloudInit.userData(options(desktop: true))
        for line in ["  - ubuntu-desktop-minimal", "  - spice-vdagent", "  - language-pack-gnome-pl",
                     "      AutomaticLogin=anna", "      lock-enabled=false", "    defer: true",
                     "  - [systemctl, set-default, graphical.target]",
                     "  - [systemctl, disable, systemd-networkd-wait-online.service]"] {
            XCTAssertTrue(text.contains(line + "\n"), line)
        }
        // `power_state` comes last; the module order is cloud-init's own anyway.
        XCTAssertLessThan(text.range(of: "runcmd:")!.lowerBound, text.range(of: "power_state:")!.lowerBound)
    }

    func testPasswordIsADoubleQuotedScalar() {
        XCTAssertEqual(LinuxCloudInit.yamlString(#"Ab"c:#d x/1\"#), #""Ab\"c:#d x/1\\""#)
        XCTAssertTrue(LinuxCloudInit.userData(options(desktop: false, password: "a: b"))
            .contains(#"    plain_text_passwd: "a: b""# + "\n"))
    }

    func testEnglishNeedsNoLanguagePack() {
        XCTAssertEqual(LinuxCloudInit.Language.english.packages(desktop: true), [])
        XCTAssertEqual(LinuxCloudInit.Language.chinese.packages(desktop: false), ["language-pack-zh-hans"])
    }

    func testHostnameIsAnASCIILabel() {
        XCTAssertEqual(LinuxCloudInit.hostname(from: "ubuntu-24-04"), "ubuntu-24-04")
        XCTAssertEqual(LinuxCloudInit.hostname(from: "zazołc-gesla"), "zazo-c-gesla")
        XCTAssertEqual(LinuxCloudInit.hostname(from: "测试"), "ubuntu")
        XCTAssertEqual(LinuxCloudInit.hostname(from: String(repeating: "a", count: 80)).count, 63)
    }

    func testUsernames() {
        XCTAssertTrue(LinuxCloudInit.isValidUsername("anna"))
        XCTAssertTrue(LinuxCloudInit.isValidUsername("_svc-1"))
        for bad in ["", "Anna", "1anna", "root", "ubuntu", "an na", String(repeating: "a", count: 33)] {
            XCTAssertFalse(LinuxCloudInit.isValidUsername(bad), bad)
        }
    }

    func testMetaData() {
        XCTAssertEqual(LinuxCloudInit.metaData(instanceID: "x-1", hostname: "x"), "instance-id: x-1\nlocal-hostname: x\n")
    }
}
