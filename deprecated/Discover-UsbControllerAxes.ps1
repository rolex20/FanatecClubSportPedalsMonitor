<#
.SYNOPSIS
    Discover-UsbControllerAxes.ps1
    Live axis dump for WinMM (joyGetPosEx) devices so you can identify which axis is Brake.

.DESCRIPTION
    This script prints ALL joystick axes (X, Y, Z, R, U, V) and their percentages.
    Press each pedal and watch which axis changes.

    Notes:
    - Default flags = JOY_RETURNALL (255) => values usually scale to 0..65535.
    - If you include JOY_RETURNRAWDATA (256) in -JoyFlags, many Fanatec devices report 0..1023 instead.

.EXAMPLE
    # List all devices once
    .\Discover-UsbControllerAxes.ps1 -ListOnly

.EXAMPLE
    # Monitor device 0 with default flags
    .\Discover-UsbControllerAxes.ps1 -DeviceId 0

.EXAMPLE
    # Monitor by VID/PID (hex strings)
    .\Discover-UsbControllerAxes.ps1 -VendorId 0EB7 -ProductId 1839

.EXAMPLE
    # Use raw data mode (example combines RAWDATA + RETURNALL)
    .\Discover-UsbControllerAxes.ps1 -JoyFlags 511
#>

[CmdletBinding()]
param(
    [int]$RefreshMs = 150,
    [int]$JoyFlags = 255,
    [int]$DeviceId = -1,
    [string]$VendorId,
    [string]$ProductId,
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- C# WinMM Interop ---------------------------------------------------------
$cs = @"
using System;
using System.Runtime.InteropServices;

public static class WinMM {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct JOYCAPS {
        public ushort wMid;
        public ushort wPid;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;

        public int wXmin;
        public int wXmax;
        public int wYmin;
        public int wYmax;
        public int wZmin;
        public int wZmax;
        public int wNumButtons;
        public int wPeriodMin;
        public int wPeriodMax;
        public int wRmin;
        public int wRmax;
        public int wUmin;
        public int wUmax;
        public int wVmin;
        public int wVmax;
        public int wCaps;
        public int wMaxAxes;
        public int wNumAxes;
        public int wMaxButtons;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szRegKey;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szOEMVxD;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOYINFOEX {
        public uint dwSize;
        public uint dwFlags;
        public uint dwXpos;
        public uint dwYpos;
        public uint dwZpos;
        public uint dwRpos;
        public uint dwUpos;
        public uint dwVpos;
        public uint dwButtons;
        public uint dwButtonNumber;
        public uint dwPOV;
        public uint dwReserved1;
        public uint dwReserved2;
    }

    [DllImport("winmm.dll")]
    public static extern uint joyGetNumDevs();

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    public static extern uint joyGetDevCaps(uint id, out JOYCAPS caps, uint cbjc);

    [DllImport("winmm.dll")]
    public static extern uint joyGetPosEx(uint id, ref JOYINFOEX pji);

    public const uint JOYERR_NOERROR = 0;

    public const uint JOY_RETURNALL      = 0x000000FF;
    public const uint JOY_RETURNRAWDATA  = 0x00000100;
}
"@

if (-not ("WinMM" -as [type])) {
    Add-Type -TypeDefinition $cs -Language CSharp
}

function Get-AxisMax {
    param([int]$Flags)
    if (($Flags -band 0x00000100) -ne 0) { return 1023 }
    return 65535
}

function Get-DeviceList {
    $count = [WinMM]::joyGetNumDevs()
    $devices = @()

    for ($i = 0; $i -lt $count; $i++) {
        $caps = New-Object WinMM+JOYCAPS
        $res = [WinMM]::joyGetDevCaps([uint32]$i, [ref]$caps, [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([WinMM+JOYCAPS]))
        if ($res -eq [WinMM]::JOYERR_NOERROR) {
            $devices += [pscustomobject]@{
                Id       = $i
                Name     = $caps.szPname
                Mid      = $caps.wMid
                Pid      = $caps.wPid
                NumAxes  = $caps.wNumAxes
                NumBtns  = $caps.wNumButtons
            }
        }
    }
    return $devices
}

function Find-DeviceByVidPid {
    param([int]$Vid, [int]$Pid)

    foreach ($d in (Get-DeviceList)) {
        if ($d.Mid -eq $Vid -and $d.Pid -eq $Pid) { return $d.Id }
    }
    return $null
}

$devices = Get-DeviceList
if ($devices.Count -eq 0) {
    throw "No WinMM joystick devices found (joyGetDevCaps returned none)."
}

if ($ListOnly) {
    $devices | Sort-Object Id | Format-Table -AutoSize
    return
}

$targetId = $null

if ($DeviceId -ge 0) {
    $targetId = $DeviceId
} elseif ($VendorId -and $ProductId) {
    $vid = [Convert]::ToInt32($VendorId, 16)
    $pid = [Convert]::ToInt32($ProductId, 16)
    $targetId = Find-DeviceByVidPid -Vid $vid -Pid $pid
    if ($null -eq $targetId) {
        throw ("No device matched VID:{0} PID:{1} (decimal MID/PID in JOYCAPS)." -f $vid, $pid)
    }
} else {
    # If nothing specified, just pick the first available device.
    $targetId = ($devices | Sort-Object Id | Select-Object -First 1).Id
}

$axisMax = Get-AxisMax -Flags $JoyFlags

Write-Host "Monitoring WinMM deviceId=$targetId  JoyFlags=$JoyFlags  AxisMax=$axisMax" -ForegroundColor Cyan
Write-Host "Press pedals and watch which axis changes. Ctrl+C to stop." -ForegroundColor Cyan

$prev = $null

while ($true) {
    $ji = New-Object WinMM+JOYINFOEX
    $ji.dwSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([WinMM+JOYINFOEX])
    $ji.dwFlags = [uint32]$JoyFlags

    $res = [WinMM]::joyGetPosEx([uint32]$targetId, [ref]$ji)
    if ($res -ne [WinMM]::JOYERR_NOERROR) {
        Write-Host ("joyGetPosEx failed (res={0}). Is the device disconnected?" -f $res) -ForegroundColor Red
        Start-Sleep -Milliseconds 500
        continue
    }

    $cur = [pscustomobject]@{
        X = [uint32]$ji.dwXpos
        Y = [uint32]$ji.dwYpos
        Z = [uint32]$ji.dwZpos
        R = [uint32]$ji.dwRpos
        U = [uint32]$ji.dwUpos
        V = [uint32]$ji.dwVpos
        Buttons = [uint32]$ji.dwButtons
        POV = [uint32]$ji.dwPOV
    }

    function pct([uint32]$v) { [math]::Round(100.0 * $v / $axisMax, 1) }
    function inv([uint32]$v) { [uint32]($axisMax - $v) }

    $rows = @()
    foreach ($axis in @('X','Y','Z','R','U','V')) {
        $raw = $cur.$axis
        $invv = inv $raw
        $delta = if ($prev) { [int64]$raw - [int64]$prev.$axis } else { 0 }
        $rows += [pscustomobject]@{
            Axis   = $axis
            Raw    = $raw
            Inv    = $invv
            RawPct = pct $raw
            InvPct = pct $invv
            Delta  = $delta
        }
    }

    Clear-Host
    $dev = $devices | Where-Object { $_.Id -eq $targetId } | Select-Object -First 1
    Write-Host ("Device {0}: {1} (MID={2} PID={3} Axes={4} Btns={5})" -f $dev.Id, $dev.Name, $dev.Mid, $dev.Pid, $dev.NumAxes, $dev.NumBtns) -ForegroundColor Cyan
    Write-Host ("JoyFlags={0}  AxisMax={1}  (RawPct is raw/AxisMax; InvPct is (AxisMax-raw)/AxisMax)" -f $JoyFlags, $axisMax) -ForegroundColor DarkCyan
    Write-Host ("Buttons={0}  POV={1}" -f $cur.Buttons, $cur.POV) -ForegroundColor DarkCyan
    ""
    $rows | Format-Table -AutoSize

    $prev = $cur
    Start-Sleep -Milliseconds $RefreshMs
}
