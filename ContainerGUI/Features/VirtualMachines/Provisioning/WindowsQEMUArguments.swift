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
        [VirtualMachine.ExtraDrive(path: media.windowsISO.path, bootIndex: windowsISOBootIndex)]
            + [media.setupISO, media.virtioISO].map { VirtualMachine.ExtraDrive(path: $0.path) }
    }

    /// One more than the disk's (`QEMULauncher` gives the NVMe disk `bootindex=1`).
    static let windowsISOBootIndex = 2

    /// Getting past "Press any key to boot from CD": press `qcode` every
    /// `interval` from launch until `duration` has passed.
    ///
    /// Not Enter. Setup's progress screen comes up with **Cancel focused**, and on
    /// a warm host it arrived inside the 15 s window: an Enter landed on Cancel
    /// and left the install parked at "Czy na pewno chcesz wyjść?". The down
    /// arrow is a key the firmware prompt accepts and that activates no button.
    struct BootKeypress: Sendable, Equatable {
        var qcode = "down"
        var interval: Duration = .milliseconds(500)
        var duration: Duration = .seconds(15)
    }
    static let bootKeypress = BootKeypress()
}
