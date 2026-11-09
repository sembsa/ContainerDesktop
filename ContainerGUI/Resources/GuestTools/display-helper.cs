// Container Desktop display helper. Runs in the signed-in user's session (a
// scheduled task at logon), because the guest agent is a session-0 service and
// cannot change the user's display mode. The host writes "WIDTHxHEIGHT <id>"
// into display-request.txt, after asking QEMU for that size over VNC; this
// switches to it, or to the closest mode the driver lists, and reports in
// display-status.txt.
//
// display-helper-install.ps1 compiles it with Add-Type into a Windows-subsystem
// .exe: no console window, and none of the races conhost --headless lost at
// logon (it failed to start PowerShell on three logons out of five).
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

public static class ContainerDesktopDisplayHelper {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr param);

  const int Fields = 0x80000 | 0x100000; // DM_PELSWIDTH | DM_PELSHEIGHT

  static DEVMODE Mode(int i) { var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm); return EnumDisplaySettings(null, i, ref dm) ? dm : new DEVMODE(); }

  static string Current() { var c = Mode(-1); return c.dmPelsWidth + "x" + c.dmPelsHeight; }

  static string Modes() {
    var seen = new List<string>();
    for (int i = 0; ; i++) { var m = Mode(i); if (m.dmSize == 0) break; var s = m.dmPelsWidth + "x" + m.dmPelsHeight; if (!seen.Contains(s)) seen.Add(s); }
    return string.Join(" ", seen);
  }

  // Never persisted (flags 0), so the next boot starts at the machine's own
  // resolution again.
  static string Apply(int w, int h) {
    var cur = Mode(-1);
    if (cur.dmPelsWidth == w && cur.dmPelsHeight == h) return "unchanged " + Current();
    // The exact size first: viogpudo (FlexResolution) accepts the size the host
    // asked QEMU for with SetDesktopSize, although it never lists it — but only
    // once it has handled that event, which can take a few hundred milliseconds.
    var exact = cur; exact.dmPelsWidth = w; exact.dmPelsHeight = h; exact.dmFields = Fields;
    for (int attempt = 0; attempt < 10; attempt++) {
      if (ChangeDisplaySettingsEx(null, ref exact, IntPtr.Zero, 0, IntPtr.Zero) == 0) return "ok " + Current();
      Thread.Sleep(200);
    }
    // Otherwise the closest listed mode at the current colour depth.
    DEVMODE best = cur; long bestD = long.MaxValue;
    for (int i = 0; ; i++) {
      var m = Mode(i); if (m.dmSize == 0) break;
      if (m.dmBitsPerPel != cur.dmBitsPerPel) continue;
      long d = Math.Abs(m.dmPelsWidth - w) + Math.Abs(m.dmPelsHeight - h);
      if (d < bestD) { bestD = d; best = m; }
    }
    if (best.dmPelsWidth == cur.dmPelsWidth && best.dmPelsHeight == cur.dmPelsHeight) return "closest " + Current();
    best.dmFields = Fields;
    int r = ChangeDisplaySettingsEx(null, ref best, IntPtr.Zero, 0, IntPtr.Zero);
    return (r == 0 ? "closest " : "error " + r + " ") + Current();
  }

  static string Read(string path) { try { return File.ReadAllText(path); } catch { return ""; } }

  static void Report(string path, string text) { try { File.WriteAllText(path, text + "\r\nmodes " + Modes()); } catch { } }

  public static void Main() {
    string dir = AppDomain.CurrentDomain.BaseDirectory;
    string request = Path.Combine(dir, "display-request.txt"), status = Path.Combine(dir, "display-status.txt");
    bool first;
    using (new Mutex(true, @"Local\ContainerDesktopDisplayHelper", out first)) {
      if (!first) return;
      // Each request carries a fresh id after the size, so one write is applied
      // once however many change events it raises. The one already there at
      // logon counts as done: an old request would undo whatever the machine
      // was started with.
      string applied = Read(request);
      Report(status, "started " + Current());
      var watcher = new FileSystemWatcher(dir, "display-request.txt");
      while (true) {
        // Wakes on a write, and every few seconds anyway in case an event was missed.
        watcher.WaitForChanged(WatcherChangeTypes.All, 5000);
        Thread.Sleep(100); // let the host finish writing
        string text = Read(request);
        var match = Regex.Match(text, @"^(\d+)x(\d+)");
        if (text == applied || !match.Success) continue;
        applied = text;
        try { Report(status, Apply(int.Parse(match.Groups[1].Value), int.Parse(match.Groups[2].Value))); }
        catch (Exception e) { Report(status, "error " + e.Message); }
      }
    }
  }
}
