import Foundation

/// What a Windows 11 ARM64 guest needs from `QEMULauncher` beyond its normal
/// arguments, for the install run and for every run after it. Pure data: the
/// launcher owns the command line, this says what to change in it.
///
/// Proven by a full unattended install (test B, `vms/win-b-test`):
/// - **Boot order.** The disk boots before the Windows ISO. An empty disk fails
///   at once and UEFI falls to the CD; after Setup's first reboot the disk boots
///   and the CD is never asked again. The ISO *must* carry a bootindex: ArmVirt
///   UEFI only connects devices in QEMU's boot order, and without one it lands in
///   the UEFI shell. The CDSETUP and virtio-win CDs need none — Windows finds them.
/// - **"Press any key to boot from CD or DVD".** The ISO's `bootaa64.efi` waits
///   ~5 s for a key and otherwise falls through. See `bootKeypress`. A
///   `startup.nsh` does not get around it: from the UEFI shell the ISO's
///   `cdboot_noprompt.efi` returns EFI_NOT_FOUND and `bootmgfw.efi`
///   EFI_INVALID_PARAMETER — both only boot from the El Torito device path, and
///   the shell can only reach the CD through its UDF file system.
/// - **Display.** `ramfb` during the install (a linear framebuffer Setup can
///   draw on with no driver), `virtio-gpu-pci` afterwards, once `cd-setup.cmd`
///   has staged viogpudo — that gives 1280×800 from the first frame. Never both:
///   Windows gets two heads and VNC shows the first.
/// - **The install run ends by itself.** `cd-setup.cmd` powers the guest off, so
///   QEMU exiting means: done. Then drop the extra drives and switch the display.
enum WindowsQEMUArguments {
    enum Run { case install, normal }

    struct Media: Sendable, Equatable {
        var windowsISO: URL
        /// The CDSETUP ISO from `WindowsSetupMedia.buildISO`.
        var setupISO: URL
        /// virtio-win (NetKVM, vioserial, viogpudo for ARM64).
        var virtioISO: URL
    }

    /// `vm.json` `extraDrives` for the install run. The Windows ISO is first and
    /// needs `windowsISOBootIndex` on its `usb-storage` device.
    static func installDrives(_ media: Media) -> [VirtualMachine.ExtraDrive] {
        [media.windowsISO, media.setupISO, media.virtioISO].map { VirtualMachine.ExtraDrive(path: $0.path) }
    }

    /// One more than the disk's (`QEMULauncher` gives the NVMe disk `bootindex=1`).
    static let windowsISOBootIndex = 2

    /// Replaces the launcher's `-device ramfb`.
    static func display(_ run: Run) -> [String] {
        switch run {
        case .install: ["-device", "ramfb"]
        // xres/yres are the mode viogpudo reports as preferred; 1280×800 is
        // QEMU's default too, spelled out so nobody wonders.
        case .normal: ["-device", "virtio-gpu-pci,xres=1280,yres=800"]
        }
    }

    /// Getting past "Press any key to boot from CD": send this QMP command every
    /// `interval` from launch until `duration` has passed. Keep the window short —
    /// Setup's progress screen appears ~25 s in with **Cancel focused**, and an
    /// Enter there aborts the install. 15 s covered the prompt with room to spare.
    struct BootKeypress: Sendable, Equatable {
        var qmp = #"{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}"#
        var interval: Duration = .milliseconds(500)
        var duration: Duration = .seconds(15)
    }
    static let bootKeypress = BootKeypress()
}
