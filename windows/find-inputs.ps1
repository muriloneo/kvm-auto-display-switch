# Finds the VCP 0x60 values your monitor really uses, from Windows. No install needed:
# uses the built-in dxva2 API. Run in PowerShell while the monitor shows this PC:
#   powershell -ExecutionPolicy Bypass -File find-inputs.ps1
# Each value is sent to every monitor; note which one makes it switch, then bring it
# back with the monitor's buttons (most monitors ignore DDC from an inactive input).
param([int[]]$Values = @(1..18 + 0x1B))

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class Ddc {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string d; }
  public delegate bool MonEnum(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnum cb, IntPtr p);
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] public static extern bool SetVCPFeature(IntPtr h, byte code, uint v);
  public static List<PM> All() {
    var l = new List<PM>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m,a,b,c) => { uint n; GetNumberOfPhysicalMonitorsFromHMONITOR(m, out n);
      var arr = new PM[n]; GetPhysicalMonitorsFromHMONITOR(m, n, arr); l.AddRange(arr); return true; }, IntPtr.Zero);
    return l; }
}
"@

$monitors = [Ddc]::All()
Write-Host "Monitors: $($monitors | ForEach-Object { $_.d })"
foreach ($v in $Values) {
  Read-Host ("Press Enter to send 0x{0:X2} (Ctrl+C to stop)" -f $v) | Out-Null
  foreach ($m in $monitors) { [void][Ddc]::SetVCPFeature($m.h, 0x60, [uint32]$v) }
  Write-Host "  -> Note what the monitor shows now. If it left this PC, switch back with its buttons."
}
