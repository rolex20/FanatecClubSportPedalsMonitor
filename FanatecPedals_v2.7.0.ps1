<#
.SYNOPSIS
  FanatecPedals.ps1 v2.7.0
  Unified Fanatec Pedals monitor + HTTP telemetry bridge (replacement for main.c + pedBridge.ps1).

.DESCRIPTION
  - Samples WinMM joystick axes (joyGetPosEx)
  - Optional clutch noise + gas drift alerts (TTS)
  - Serves PedDash-compatible telemetry frames over HTTP (localhost:8181)

  v2.7.0 focuses on:
    - main.c-compatible JoyFlags support (equivalent to --flags N)
    - Brake axis telemetry (raw + normalized + percent) with a top-of-file constant
    - Single-source-of-truth state machine (no "locals that must be copied" bug class)
    - No pointless re-assignment inside the sampling loop for values that never change

.VERSION HISTORY
  2.7.0 - JoyFlags parameter (main.c --flags parity), Brake axis telemetry, optimized state updates
  2.6.x - Brake telemetry prototype
  2.5.1 - Legacy contract fixes (disconnect/reconnect publish, clean shutdown, metrics)
#>

# -----------------------------------------------------------------------------
# SECTION 0: TOP-LEVEL CONSTANTS
# -----------------------------------------------------------------------------
# Which JOY axis corresponds to the brake pedal on your device.
# Allowed: X, Y, Z, R, U, V
$BRAKE_AXIS = 'Z'

[CmdletBinding()]
param (
  # --- LOOP / TIMING ---
  [Alias("s")][int]$SleepTime = 1000,               # ms between samples
  [Alias("i")][int]$Iterations = 0,                 # 0 = infinite

  # --- main.c parity: --flags N ---
  [Alias("f","flags")][uint32]$JoyFlags = 255,      # default: JOY_RETURNALL (0xFF)

  # --- CLUTCH ---
  [Alias("m")][int]$Margin = 5,                     # percent tolerance for clutch noise diff
  [Alias("clutch-repeat")][int]$ClutchRepeat = 4,   # consecutive "stable" samples to trigger Rudder alert
  [switch]$MonitorClutch,

  # --- GAS ---
  [switch]$MonitorGas,
  [Alias("gas-deadzone-in")][int]$GasDeadzoneIn = 5,
  [Alias("gas-deadzone-out")][int]$GasDeadzoneOut = 93,
  [Alias("gas-window")][int]$GasWindow = 30,
  [Alias("gas-cooldown")][int]$GasCooldown = 60,
  [Alias("gas-timeout")][int]$GasTimeout = 10,
  [Alias("gas-min-usage")][int]$GasMinUsage = 20,
  [Alias("estimate-gas-deadzone-out")][switch]$EstimateGasDeadzone,
  [Alias("adjust-deadzone-out-with-minimum")][int]$AutoGasDeadzoneMin = -1, # -1 disables

  # --- AXIS NORMALIZATION ---
  [switch]$NoAxisNormalization,     # if set: do not invert (raw values)
  [switch]$DebugRaw,                # verbose raw vs normalized dumps

  # --- DEVICE SELECTION / AUTO-RECONNECT ---
  [Alias("j")][int]$JoystickID = 17,  # 17 = sentinel meaning "use VID/PID scan"
  [Alias("v")][string]$VendorId,      # hex string (e.g. 0EB7)
  [Alias("p")][string]$ProductId,     # hex string (e.g. 1839)

  # --- TELEMETRY / TTS ---
  [switch]$Telemetry = $true,         # required for PedDash
  [switch]$Tts = $true,
  [switch]$NoTts,
  [switch]$NoConsoleBanner,

  # --- HELP ---
  [switch]$Help
)

# -----------------------------------------------------------------------------
# SECTION 1: HELP TEXT
# -----------------------------------------------------------------------------
$ShowHelp = $Help.IsPresent -or ($PSBoundParameters.Count -eq 0)
if ($ShowHelp) {
  Write-Host @"
Usage: .\FanatecPedals.ps1 [options]

General:
  -SleepTime MS        Sample interval (ms). Default=1000
  -Iterations N        Number of loops (0 = infinite)
  -JoyFlags N          WinMM JOYINFOEX.dwFlags (main.c --flags).
                       Examples:
                         255 = JOY_RETURNALL
                         266 = JOY_RETURNRAWDATA|JOY_RETURNR|JOY_RETURNY
                         270 = 266 + JOY_RETURNZ (adds Z axis for brake)

Device:
  -JoystickID N        0-15 to force a joystick id
                       17 means VID/PID scan mode (requires -VendorId/-ProductId)
  -VendorId HEX        wMid from joyGetDevCaps() (hex)
  -ProductId HEX       wPid from joyGetDevCaps() (hex)

Axis:
  -NoAxisNormalization Do NOT invert pedal axes (use raw values)
  -DebugRaw            In verbose mode, print raw and normalized

Clutch:
  -MonitorClutch       Enable clutch noise monitoring
  -Margin N            % tolerance for clutch diff. Default=5
  -ClutchRepeat N      Consecutive stable samples to alert. Default=4

Gas:
  -MonitorGas                Enable gas drift monitoring
  -GasDeadzoneIn N           % idle deadzone (0-100). Default=5
  -GasDeadzoneOut N          % full threshold (0-100). Default=93
  -GasWindow Sec             seconds to require full. Default=30
  -GasTimeout Sec            idle timeout seconds. Default=10
  -GasCooldown Sec           cooldown seconds. Default=60
  -GasMinUsage %             minimum % to alert. Default=20
  -EstimateGasDeadzone       enable estimator output
  -AutoGasDeadzoneMin N      auto-decrease out threshold, but never below N

Telemetry / TTS:
  -Telemetry           Enable HTTP JSON telemetry server (default on)
  -Tts                 Enable TTS alerts (default on)
  -NoTts               Disable TTS alerts
  -NoConsoleBanner     Hide startup banner

Top-of-file constant:
  `$BRAKE_AXIS = 'Z'   Select brake axis (X/Y/Z/R/U/V)
"@
  exit 0
}

# -----------------------------------------------------------------------------
# SECTION 2: FLAGS / BASIC VALIDATION
# -----------------------------------------------------------------------------
$VerboseEnabled = ($PSCmdlet.MyInvocation.BoundParameters["Verbose"] -eq $true) -or ($VerbosePreference -ne 'SilentlyContinue')

if ($NoTts) { $Tts = $false }
$AxisNormalization = -not $NoAxisNormalization
$AutoGasAdjustEnabled = ($AutoGasDeadzoneMin -ge 0)

if (($VendorId -and -not $ProductId) -or (-not $VendorId -and $ProductId)) {
  throw "Provide both -VendorId and -ProductId (HEX) for auto-reconnect."
}

$TargetVid = if ($VendorId) { [Convert]::ToInt32($VendorId, 16) } else { 0 }
$TargetPid = if ($ProductId) { [Convert]::ToInt32($ProductId, 16) } else { 0 }

if ($JoystickID -ge 16 -and ($TargetVid -eq 0 -or $TargetPid -eq 0)) {
  throw "JoystickID $JoystickID is the auto-detect sentinel. Provide -VendorId/-ProductId or set -JoystickID to 0..15."
}

# -----------------------------------------------------------------------------
# SECTION 3: C# INTEROP
# -----------------------------------------------------------------------------
$Source = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Concurrent;

namespace Fanatec {

  [Serializable]
  public class PedalMonState {
    // --- 70 legacy main.c fields (MUST MATCH NAMES) ---
    public int verbose_flag;
    public int monitor_clutch;
    public int monitor_gas;
    public int gas_deadzone_in;
    public int gas_deadzone_out;
    public int gas_window;
    public int gas_cooldown;
    public int gas_timeout;
    public int gas_min_usage_percent;
    public int axis_normalization_enabled;
    public int debug_raw_mode;
    public int clutch_repeat_required;
    public int estimate_gas_deadzone_enabled;
    public int auto_gas_deadzone_enabled;
    public int auto_gas_deadzone_minimum;
    public int target_vendor_id;
    public int target_product_id;
    public int telemetry_enabled;
    public int tts_enabled;
    public int ipc_enabled;
    public int no_console_banner;

    public uint gas_physical_pct;
    public uint clutch_physical_pct;
    public uint gas_logical_pct;
    public uint clutch_logical_pct;

    public uint joy_ID;
    public uint joy_Flags;
    public uint iterations;
    public uint margin;
    public uint sleep_Time;

    public uint axisMax;
    public uint axisMargin;
    public uint lastClutchValue;
    public int  repeatingClutchCount;
    public int  isRacing;
    public uint peakGasInWindow;
    public uint lastFullThrottleTime;
    public uint lastGasActivityTime;
    public uint lastGasAlertTime;
    public uint gasIdleMax;
    public uint gasFullMin;
    public uint gas_timeout_ms;
    public uint gas_window_ms;
    public uint gas_cooldown_ms;

    public uint best_estimate_percent;
    public uint last_printed_estimate;
    public uint estimate_window_peak_percent;
    public uint estimate_window_start_time;
    public uint last_estimate_print_time;

    public uint currentTime;
    public uint rawGas;
    public uint rawClutch;
    public uint gasValue;
    public uint clutchValue;
    public int  closure;
    public uint percentReached;
    public uint currentPercent;
    public uint iLoop;

    public uint producer_loop_start_ms;
    public uint producer_notify_ms;
    public uint fullLoopTime_ms;
    public uint telemetry_sequence;

    public int gas_alert_triggered;
    public int clutch_alert_triggered;
    public int controller_disconnected;
    public int controller_reconnected;
    public int gas_estimate_decreased;
    public int gas_auto_adjust_applied;
    public uint last_disconnect_time_ms;
    public uint last_reconnect_time_ms;

    // --- Bridge extensions used by PedDash ---
    public long receivedAtUnixMs;
    public double metricHttpProcessMs;
    public double metricTtsSpeakMs;
    public double metricLoopProcessMs;

    // --- NEW brake telemetry (extra keys; no legacy consumers rely on them) ---
    public uint rawBrake;
    public uint brakeValue;
    public uint brake_physical_pct;
    public uint brake_logical_pct;

    public PedalMonState Clone() { return (PedalMonState)this.MemberwiseClone(); }
  }

  public static class Shared {
    public static ConcurrentQueue<PedalMonState> TelemetryQueue = new ConcurrentQueue<PedalMonState>();
    public static double LastHttpTimeMs = 0;
    public static double LastTtsTimeMs = 0;
    public static volatile bool StopSignal = false;
    public static System.Net.HttpListener GlobalListener = null;
    public static int BatchId = 0;
  }

  public static class Hardware {
    [StructLayout(LayoutKind.Sequential)]
    public struct JOYCAPS {
      public ushort wMid;
      public ushort wPid;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
      public uint wXmin; public uint wXmax;
      public uint wYmin; public uint wYmax;
      public uint wZmin; public uint wZmax;
      public uint wNumButtons;
      public uint wPeriodMin;
      public uint wPeriodMax;
      public uint wRmin; public uint wRmax;
      public uint wUmin; public uint wUmax;
      public uint wVmin; public uint wVmax;
      public uint wCaps;
      public uint wMaxAxes;
      public uint wNumAxes;
      public uint wMaxButtons;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD;
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

    [DllImport("winmm.dll")] public static extern uint joyGetNumDevs();
    [DllImport("winmm.dll")] public static extern uint joyGetDevCaps(uint uJoyID, out JOYCAPS pjc, uint cbjc);
    [DllImport("winmm.dll")] public static extern uint joyGetPosEx(uint uJoyID, ref JOYINFOEX pji);

    public const uint JOY_RETURNX       = 0x00000001;
    public const uint JOY_RETURNY       = 0x00000002;
    public const uint JOY_RETURNZ       = 0x00000004;
    public const uint JOY_RETURNR       = 0x00000008;
    public const uint JOY_RETURNU       = 0x00000010;
    public const uint JOY_RETURNV       = 0x00000020;
    public const uint JOY_RETURNRAWDATA = 0x00000100;
    public const uint JOY_RETURNALL     = 0x000000FF;

    public const uint JOYERR_NOERROR = 0;

    public static bool CheckDevice(uint id, int vid, int pid) {
      JOYCAPS caps = new JOYCAPS();
      if (joyGetDevCaps(id, out caps, (uint)Marshal.SizeOf(caps)) == JOYERR_NOERROR) {
        return (caps.wMid == vid && caps.wPid == pid);
      }
      return false;
    }

    public static int GetPosition(uint id, uint flags, out uint x, out uint y, out uint z, out uint r, out uint u, out uint v) {
      JOYINFOEX info = new JOYINFOEX();
      info.dwSize  = (uint)Marshal.SizeOf(info);
      info.dwFlags = flags;

      uint res = joyGetPosEx(id, ref info);
      x = info.dwXpos;
      y = info.dwYpos;
      z = info.dwZpos;
      r = info.dwRpos;
      u = info.dwUpos;
      v = info.dwVpos;
      return (int)res;
    }
  }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'Fanatec.Hardware').Type) {
  Add-Type -TypeDefinition $Source -Language CSharp
} else {
  Write-Warning "Using existing C# definition. If you changed embedded C# code, restart PowerShell."
}

# -----------------------------------------------------------------------------
# SECTION 4: HELPERS
# -----------------------------------------------------------------------------
function Find-FanatecDevice {
  param([int]$Vid, [int]$Pid)
  $count = [Fanatec.Hardware]::joyGetNumDevs()
  for ($i = 0; $i -lt $count; $i++) {
    if ([Fanatec.Hardware]::CheckDevice([uint32]$i, $Vid, $Pid)) { return $i }
  }
  return -1
}

function Convert-ToLogicalPct {
  <#
    main.c ComputeLogicalPct behavior (including divide-by-zero/negative guard)
  #>
  param(
    [Parameter(Mandatory=$true)][uint32]$Value,
    [Parameter(Mandatory=$true)][uint32]$IdleMax,
    [Parameter(Mandatory=$true)][uint32]$FullMin
  )

  if ($Value -le $IdleMax) { return [uint32]0 }
  if ($Value -ge $FullMin) { return [uint32]100 }
  if ($FullMin -le $IdleMax) { return [uint32]0 }

  return [uint32](100 * ($Value - $IdleMax) / ($FullMin - $IdleMax))
}

function Get-AxisFlag {
  param([Parameter(Mandatory=$true)][string]$AxisLetter)
  switch ($AxisLetter.ToUpperInvariant()) {
    'X' { return [Fanatec.Hardware]::JOY_RETURNX }
    'Y' { return [Fanatec.Hardware]::JOY_RETURNY }
    'Z' { return [Fanatec.Hardware]::JOY_RETURNZ }
    'R' { return [Fanatec.Hardware]::JOY_RETURNR }
    'U' { return [Fanatec.Hardware]::JOY_RETURNU }
    'V' { return [Fanatec.Hardware]::JOY_RETURNV }
    default { throw "Invalid BRAKE_AXIS '$AxisLetter'. Use X/Y/Z/R/U/V." }
  }
}

function Select-AxisValue {
  param(
    [Parameter(Mandatory=$true)][string]$AxisLetter,
    [Parameter(Mandatory=$true)][uint32]$X,
    [Parameter(Mandatory=$true)][uint32]$Y,
    [Parameter(Mandatory=$true)][uint32]$Z,
    [Parameter(Mandatory=$true)][uint32]$R,
    [Parameter(Mandatory=$true)][uint32]$U,
    [Parameter(Mandatory=$true)][uint32]$V
  )

  switch ($AxisLetter.ToUpperInvariant()) {
    'X' { return $X }
    'Y' { return $Y }
    'Z' { return $Z }
    'R' { return $R }
    'U' { return $U }
    'V' { return $V }
    default { return 0 }
  }
}

function Publish-TelemetryFrame {
  <#
    Publishes one frame:
      - increments telemetry_sequence
      - sets notify timestamp + perf metrics
      - enqueues a Clone() snapshot
  #>
  param(
    [Parameter(Mandatory=$true)][Fanatec.PedalMonState]$State,
    [Parameter(Mandatory=$true)][ref]$TelemetrySeq,
    [Parameter(Mandatory=$true)][double]$LoopStartMs,
    [Parameter(Mandatory=$true)][System.Diagnostics.Stopwatch]$Stopwatch
  )

  $TelemetrySeq.Value++
  $State.telemetry_sequence = [uint32]$TelemetrySeq.Value
  $State.producer_notify_ms = [uint32][Environment]::TickCount

  $State.receivedAtUnixMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  $State.metricHttpProcessMs = [double][Fanatec.Shared]::LastHttpTimeMs
  $State.metricTtsSpeakMs = [double][Fanatec.Shared]::LastTtsTimeMs
  $State.metricLoopProcessMs = [double]($Stopwatch.Elapsed.TotalMilliseconds - $LoopStartMs)

  [Fanatec.Shared]::TelemetryQueue.Enqueue($State.Clone())
}

function Create-HttpServerInstance {
  param($Queue)

  $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
  $rs.ApartmentState = "MTA"
  $rs.Open()
  $rs.SessionStateProxy.SetVariable('Q', $Queue)

  $logPath = "$PWD\http_debug.log"
  $rs.SessionStateProxy.SetVariable('LogPath', $logPath)

  $ps = [PowerShell]::Create()
  $ps.Runspace = $rs

  $ps.AddScript({
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:8181/")
    $listener.Start()

    try { [Fanatec.Shared]::GlobalListener = $listener } catch {}

    $sw = [System.Diagnostics.Stopwatch]::New()

    try {
      while ($listener.IsListening -and -not [Fanatec.Shared]::StopSignal) {
        try {
          $context = $listener.GetContext()
          $sw.Restart()

          $request  = $context.Request
          $response = $context.Response

          $response.AddHeader("Access-Control-Allow-Origin", "*")
          $response.AddHeader("Access-Control-Allow-Methods", "GET, OPTIONS")
          $response.AddHeader("Access-Control-Allow-Headers", "*")
          $response.AddHeader("Cache-Control", "no-store")

          if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 200
            $response.Close()
            continue
          }

          $frames = [System.Collections.Generic.List[Object]]::new()
          $f = $null
          while ($Q.TryDequeue([ref]$f)) { $frames.Add($f) }

          $batchId = [System.Threading.Interlocked]::Increment([ref][Fanatec.Shared]::BatchId)

          $payload = @{
            schemaVersion = 1
            bridgeInfo = @{
              batchId = $batchId
              servedAtUnixMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
              pendingFrameCount = $frames.Count
            }
            frames = $frames
          }

          $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 6))
          $response.ContentType = "application/json; charset=utf-8"
          $response.ContentLength64 = $jsonBytes.Length
          $response.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length)
          $response.Close()

          $sw.Stop()
          try { [Fanatec.Shared]::LastHttpTimeMs = $sw.Elapsed.TotalMilliseconds } catch {}

        } catch {
          if ([Fanatec.Shared]::StopSignal) { break }
          Add-Content -Path $LogPath -Value ("[{0}] HTTP loop error: {1}" -f [DateTime]::Now, $_)
        }
      }
    }
    finally {
      try { $listener.Stop(); $listener.Close() } catch {}
      try { [Fanatec.Shared]::GlobalListener = $null } catch {}
    }
  }) | Out-Null

  return $ps
}

# -----------------------------------------------------------------------------
# SECTION 5: STARTUP / STATIC ASSIGNMENTS (ONCE)
# -----------------------------------------------------------------------------
# Required axis bits (gas=Y, clutch=R, brake=$BRAKE_AXIS)
$BrakeAxisFlag = Get-AxisFlag -AxisLetter $BRAKE_AXIS
$RequiredBits = ([Fanatec.Hardware]::JOY_RETURNY -bor [Fanatec.Hardware]::JOY_RETURNR -bor $BrakeAxisFlag)

if (($JoyFlags -band $RequiredBits) -ne $RequiredBits) {
  $missing = @()
  if (($JoyFlags -band [Fanatec.Hardware]::JOY_RETURNY) -eq 0) { $missing += "Y" }
  if (($JoyFlags -band [Fanatec.Hardware]::JOY_RETURNR) -eq 0) { $missing += "R" }
  if (($JoyFlags -band $BrakeAxisFlag) -eq 0) { $missing += $BRAKE_AXIS.ToUpperInvariant() }
  Write-Warning ("JoyFlags={0} does not request axis(es): {1}. In WinMM, missing axis bits usually return 0 for those positions." -f $JoyFlags, ($missing -join ", "))
}

$AxisMax = if (($JoyFlags -band [Fanatec.Hardware]::JOY_RETURNRAWDATA) -ne 0) { 1023 } else { 65535 }
$AxisMargin = [uint32]($AxisMax * $Margin / 100)

$GasIdleMax = [uint32]($AxisMax * $GasDeadzoneIn / 100)
$GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)

$GasTimeoutMs  = [uint32]($GasTimeout * 1000)
$GasWindowMs   = [uint32]($GasWindow * 1000)
$GasCooldownMs = [uint32]($GasCooldown * 1000)

# Initialize shared state cleanly (important when re-running in the same PS session)
[Fanatec.Shared]::StopSignal = $false
[Fanatec.Shared]::LastHttpTimeMs = 0
[Fanatec.Shared]::LastTtsTimeMs = 0
try { [Fanatec.Shared]::BatchId = 0 } catch {}
try { [Fanatec.Shared]::GlobalListener = $null } catch {}

# Clear queue (avoid serving stale frames after restart)
try {
  [Fanatec.Shared]::TelemetryQueue = [System.Collections.Concurrent.ConcurrentQueue[Fanatec.PedalMonState]]::new()
} catch {
  $tmp = $null
  while ([Fanatec.Shared]::TelemetryQueue.TryDequeue([ref]$tmp)) { }
}

# TTS setup
$Synth = $null
$TtsWatch = $null
if ([bool]$Tts) {
  Add-Type -AssemblyName System.speech
  $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $Synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)
  $TtsWatch = [System.Diagnostics.Stopwatch]::New()
}

# Start HTTP server if telemetry enabled
$HttpInstance = $null
$HttpAsyncResult = $null
if ([bool]$Telemetry) {
  $HttpInstance = Create-HttpServerInstance -Queue ([Fanatec.Shared]::TelemetryQueue)
  $HttpAsyncResult = $HttpInstance.BeginInvoke()
}

# Optional startup scan if in VID/PID mode
if ($JoystickID -ge 16 -and $TargetVid -ne 0 -and $TargetPid -ne 0) {
  if ($VerboseEnabled) { Write-Host ("Looking for Controller VID:{0} PID:{1}..." -f $VendorId, $ProductId) -ForegroundColor Cyan }
  $found = Find-FanatecDevice $TargetVid $TargetPid
  if ($found -ne -1) {
    $JoystickID = $found
    if ($VerboseEnabled) { Write-Host ("Found at ID: {0}" -f $JoystickID) -ForegroundColor Green }
  } else {
    Write-Warning "Device not found at startup. Will wait for it to appear..."
  }
}

# Create the state object ONCE. It is cloned on publish; the live instance persists.
$State = New-Object Fanatec.PedalMonState

# ---- Static/main.c config fields (set ONCE) ----
$State.verbose_flag = [int][bool]$VerboseEnabled
$State.monitor_clutch = [int][bool]$MonitorClutch
$State.monitor_gas = [int][bool]$MonitorGas
$State.gas_deadzone_in = [int]$GasDeadzoneIn
$State.gas_deadzone_out = [int]$GasDeadzoneOut
$State.gas_window = [int]$GasWindow
$State.gas_cooldown = [int]$GasCooldown
$State.gas_timeout = [int]$GasTimeout
$State.gas_min_usage_percent = [int]$GasMinUsage
$State.axis_normalization_enabled = [int][bool]$AxisNormalization
$State.debug_raw_mode = [int][bool]$DebugRaw
$State.clutch_repeat_required = [int]$ClutchRepeat
$State.estimate_gas_deadzone_enabled = [int][bool]$EstimateGasDeadzone
$State.auto_gas_deadzone_enabled = [int][bool]$AutoGasAdjustEnabled
$State.auto_gas_deadzone_minimum = [int]$AutoGasDeadzoneMin
$State.target_vendor_id = [int]$TargetVid
$State.target_product_id = [int]$TargetPid
$State.telemetry_enabled = [int][bool]$Telemetry
$State.tts_enabled = [int][bool]$Tts
$State.ipc_enabled = 0
$State.no_console_banner = [int][bool]$NoConsoleBanner

# ---- Static/main.c runtime parameters (set ONCE; joy_ID may change on reconnect) ----
$State.joy_ID = [uint32]$JoystickID
$State.joy_Flags = [uint32]$JoyFlags
$State.iterations = [uint32]$Iterations
$State.margin = [uint32]$Margin
$State.sleep_Time = [uint32]$SleepTime

# ---- Static derived calibration thresholds (set ONCE; gasFullMin can change on auto-adjust) ----
$State.axisMax = [uint32]$AxisMax
$State.axisMargin = [uint32]$AxisMargin
$State.gasIdleMax = [uint32]$GasIdleMax
$State.gasFullMin = [uint32]$GasFullMin
$State.gas_timeout_ms = $GasTimeoutMs
$State.gas_window_ms = $GasWindowMs
$State.gas_cooldown_ms = $GasCooldownMs

# ---- Init dynamic/runtime fields (set ONCE to known safe values) ----
$nowTick = [uint32][Environment]::TickCount
$State.lastClutchValue = 0
$State.repeatingClutchCount = 0
$State.isRacing = 0
$State.peakGasInWindow = 0
$State.lastFullThrottleTime = $nowTick
$State.lastGasActivityTime = $nowTick
$State.lastGasAlertTime = 0

$State.best_estimate_percent = 100
$State.last_printed_estimate = 100
$State.estimate_window_peak_percent = 0
$State.estimate_window_start_time = $nowTick
$State.last_estimate_print_time = 0

$State.closure = 0
$State.percentReached = 0
$State.currentPercent = 0

$State.controller_disconnected = 0
$State.controller_reconnected = 0
$State.last_disconnect_time_ms = 0
$State.last_reconnect_time_ms = 0

$State.gas_alert_triggered = 0
$State.clutch_alert_triggered = 0
$State.gas_estimate_decreased = 0
$State.gas_auto_adjust_applied = 0

$TelemetrySeq = 0
$PrevLoopMs = 0
$LoopCount = 0
$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $NoConsoleBanner) {
  Write-Host "Fanatec Pedals Monitor & Bridge v2.7.0 started." -ForegroundColor Green
}

if ($VerboseEnabled) {
  Write-Host ("JoyFlags: {0} (0x{1})  AxisMax: {2}  BrakeAxis: {3}" -f $JoyFlags, ('{0:X}' -f $JoyFlags), $AxisMax, $BRAKE_AXIS.ToUpperInvariant()) -ForegroundColor Cyan
  Write-Host ("Telemetry: {0}  TTS: {1}" -f ([bool]$Telemetry), ([bool]$Tts)) -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# SECTION 6: MAIN LOOP (only update values that can actually change)
# -----------------------------------------------------------------------------
try {
  while ($Iterations -eq 0 -or $LoopCount -lt $Iterations) {
    $LoopStartMs = $Stopwatch.Elapsed.TotalMilliseconds

    $LoopCount++
    $State.iLoop = [uint32]$LoopCount

    $tickStart = [uint32][Environment]::TickCount
    $State.producer_loop_start_ms = $tickStart
    $State.fullLoopTime_ms = [uint32]$PrevLoopMs

    # Reset one-shot event flags each iteration (main.c behavior)
    $State.gas_alert_triggered = 0
    $State.clutch_alert_triggered = 0
    $State.controller_reconnected = 0
    $State.gas_estimate_decreased = 0
    $State.gas_auto_adjust_applied = 0

    # --- Read joystick ---
    $x=0; $y=0; $z=0; $r=0; $u=0; $v=0
    $res = [Fanatec.Hardware]::GetPosition([uint32]$JoystickID, [uint32]$JoyFlags, [ref]$x, [ref]$y, [ref]$z, [ref]$r, [ref]$u, [ref]$v)

    if ($res -ne 0) {
      # Disconnect transition
      if ($State.controller_disconnected -eq 0) {
        $State.controller_disconnected = 1
        $State.last_disconnect_time_ms = [uint32][Environment]::TickCount
        $State.currentTime = $State.last_disconnect_time_ms

        if ($VerboseEnabled) { Write-Host "Joystick read error ($res). Marking disconnected." -ForegroundColor Red }
        if ($Synth) { $Synth.SpeakAsync("Controller disconnected. Waiting...") | Out-Null }

        if ([bool]$Telemetry) {
          Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -LoopStartMs $LoopStartMs -Stopwatch $Stopwatch
        }
      }

      # If in VID/PID mode, match main.c reconnection scan cadence
      if ($TargetVid -ne 0 -and $TargetPid -ne 0) {
        if ($VerboseEnabled) { Write-Host "Entering Reconnection Mode..." -ForegroundColor Yellow }
        while (-not [Fanatec.Shared]::StopSignal) {
          Start-Sleep -Seconds 60
          $newId = Find-FanatecDevice $TargetVid $TargetPid
          if ($newId -ne -1) {
            $JoystickID = $newId
            $State.joy_ID = [uint32]$newId

            if ($VerboseEnabled) { Write-Host ("Reconnected at ID {0}" -f $newId) -ForegroundColor Green }
            if ($Synth) { $Synth.SpeakAsync("Controller connected.") | Out-Null }

            $State.controller_disconnected = 0
            $State.controller_reconnected = 1
            $State.last_reconnect_time_ms = [uint32][Environment]::TickCount
            $State.currentTime = $State.last_reconnect_time_ms

            # Reset dynamic runtime state to avoid immediate false positives
            $now = $State.last_reconnect_time_ms
            $State.isRacing = 0
            $State.peakGasInWindow = 0
            $State.lastFullThrottleTime = $now
            $State.lastGasActivityTime = $now
            $State.lastGasAlertTime = 0
            $State.lastClutchValue = 0
            $State.repeatingClutchCount = 0
            $State.closure = 0
            $State.percentReached = 0
            $State.currentPercent = 0

            $State.best_estimate_percent = 100
            $State.last_printed_estimate = 100
            $State.estimate_window_peak_percent = 0
            $State.estimate_window_start_time = $now
            $State.last_estimate_print_time = 0

            if ([bool]$Telemetry) {
              Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -LoopStartMs $LoopStartMs -Stopwatch $Stopwatch
            }
            break
          }
        }
      } else {
        Start-Sleep -Milliseconds 1000
      }

      # Loop timing bookkeeping
      $tickEnd = [uint32][Environment]::TickCount
      $PrevLoopMs = [uint32]($tickEnd - $tickStart)
      continue
    }

    # Reconnect transition (same ID starts responding again)
    if ($State.controller_disconnected -eq 1) {
      if ($VerboseEnabled) { Write-Host "Controller responding again (same ID). Marking reconnected." -ForegroundColor Green }
      if ($Synth) { $Synth.SpeakAsync("Controller connected.") | Out-Null }

      $State.controller_disconnected = 0
      $State.controller_reconnected = 1
      $State.last_reconnect_time_ms = [uint32][Environment]::TickCount
      $State.currentTime = $State.last_reconnect_time_ms

      # Reset dynamic runtime state
      $now = $State.last_reconnect_time_ms
      $State.isRacing = 0
      $State.peakGasInWindow = 0
      $State.lastFullThrottleTime = $now
      $State.lastGasActivityTime = $now
      $State.lastGasAlertTime = 0
      $State.lastClutchValue = 0
      $State.repeatingClutchCount = 0
      $State.closure = 0
      $State.percentReached = 0
      $State.currentPercent = 0

      $State.best_estimate_percent = 100
      $State.last_printed_estimate = 100
      $State.estimate_window_peak_percent = 0
      $State.estimate_window_start_time = $now
      $State.last_estimate_print_time = 0

      if ([bool]$Telemetry) {
        Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -LoopStartMs $LoopStartMs -Stopwatch $Stopwatch
      }

      $tickEnd = [uint32][Environment]::TickCount
      $PrevLoopMs = [uint32]($tickEnd - $tickStart)
      Start-Sleep -Milliseconds 250
      continue
    }

    # --- Normal sampling path ---
    $nowTick = [uint32][Environment]::TickCount
    $State.currentTime = $nowTick

    # Raw values (gas=Y, clutch=R, brake selectable)
    $State.rawGas = [uint32]$y
    $State.rawClutch = [uint32]$r
    $State.rawBrake = [uint32](Select-AxisValue -AxisLetter $BRAKE_AXIS -X $x -Y $y -Z $z -R $r -U $u -V $v)

    # Normalize (invert) if enabled
    $gasValue   = if ($AxisNormalization) { [uint32]($AxisMax - $State.rawGas) } else { [uint32]$State.rawGas }
    $clutchValue= if ($AxisNormalization) { [uint32]($AxisMax - $State.rawClutch) } else { [uint32]$State.rawClutch }
    $brakeValue = if ($AxisNormalization) { [uint32]($AxisMax - $State.rawBrake) } else { [uint32]$State.rawBrake }

    $State.gasValue = $gasValue
    $State.clutchValue = $clutchValue
    $State.brakeValue = $brakeValue

    if ($VerboseEnabled) {
      if ($DebugRaw) {
        Write-Host ("{0}, gas_raw={1} gas_norm={2}, clutch_raw={3} clutch_norm={4}, brake_raw={5} brake_norm={6}" -f $nowTick, $State.rawGas, $gasValue, $State.rawClutch, $clutchValue, $State.rawBrake, $brakeValue)
      } else {
        Write-Host ("{0}, gas={1}, clutch={2}, brake={3}" -f $nowTick, $gasValue, $clutchValue, $brakeValue)
      }
    }

    # Physical % (always updated)
    $State.gas_physical_pct = [uint32](100 * $gasValue / $AxisMax)
    $State.clutch_physical_pct = [uint32](100 * $clutchValue / $AxisMax)
    $State.brake_physical_pct = [uint32](100 * $brakeValue / $AxisMax)

    # Logical % (gas/clutch follow main.c deadzone mapping; brake is linear for now)
    $State.gas_logical_pct = Convert-ToLogicalPct -Value $gasValue -IdleMax $GasIdleMax -FullMin $GasFullMin
    $State.clutch_logical_pct = Convert-ToLogicalPct -Value $clutchValue -IdleMax $GasIdleMax -FullMin $GasFullMin
    $State.brake_logical_pct = $State.brake_physical_pct

    # --- Clutch monitoring ---
    if ($MonitorClutch) {
      $State.closure = 0
      if ($gasValue -le $GasIdleMax -and $clutchValue -gt 0) {
        $diff = [Math]::Abs([int64]$clutchValue - [int64]$State.lastClutchValue)
        $State.closure = [int]$diff

        if ($diff -le $AxisMargin) {
          $State.repeatingClutchCount++
        } else {
          $State.repeatingClutchCount = 0
        }
      } else {
        $State.repeatingClutchCount = 0
      }

      $State.lastClutchValue = $clutchValue

      if ($State.repeatingClutchCount -ge $ClutchRepeat) {
        $State.clutch_alert_triggered = 1
        $State.repeatingClutchCount = 0

        if ($VerboseEnabled) { Write-Host "Rudder Alert" -ForegroundColor Yellow }
        if ($Synth) {
          $TtsWatch.Restart()
          $Synth.SpeakAsync("Rudder.") | Out-Null
          $TtsWatch.Stop()
          [Fanatec.Shared]::LastTtsTimeMs = $TtsWatch.Elapsed.TotalMilliseconds
        }
      }
    }

    # --- Gas drift monitoring ---
    if ($MonitorGas) {
      $isRacing = ($State.isRacing -ne 0)

      if ($gasValue -gt $GasIdleMax) {
        if (-not $isRacing) {
          $State.isRacing = 1
          $State.lastFullThrottleTime = $nowTick
          $State.peakGasInWindow = 0

          if ($EstimateGasDeadzone) {
            $State.estimate_window_start_time = $nowTick
            $State.estimate_window_peak_percent = 0
          }
        }
        $State.lastGasActivityTime = $nowTick
      }
      elseif ($isRacing -and ([uint32]($nowTick - $State.lastGasActivityTime) -gt $GasTimeoutMs)) {
        $State.isRacing = 0
        $isRacing = $false
      }

      $isRacing = ($State.isRacing -ne 0)
      if ($isRacing) {
        if ($gasValue -gt $State.peakGasInWindow) { $State.peakGasInWindow = $gasValue }

        if ($gasValue -ge $GasFullMin) {
          $State.lastFullThrottleTime = $nowTick
          $State.peakGasInWindow = 0
        }
        elseif ([uint32]($nowTick - $State.lastFullThrottleTime) -gt $GasWindowMs) {
          if ([uint32]($nowTick - $State.lastGasAlertTime) -gt $GasCooldownMs) {
            $pctReached = [uint32]($State.peakGasInWindow * 100 / $AxisMax)
            $State.percentReached = $pctReached

            if ($pctReached -gt $GasMinUsage) {
              $State.gas_alert_triggered = 1
              $State.lastGasAlertTime = $nowTick

              $msg = ("Gas {0} percent." -f $pctReached)
              if ($VerboseEnabled) { Write-Host $msg -ForegroundColor Yellow }
              if ($Synth) {
                $TtsWatch.Restart()
                $Synth.SpeakAsync($msg) | Out-Null
                $TtsWatch.Stop()
                [Fanatec.Shared]::LastTtsTimeMs = $TtsWatch.Elapsed.TotalMilliseconds
              }
            }
          }
        }

        # Estimator
        if ($EstimateGasDeadzone) {
          if ($gasValue -gt $GasIdleMax) {
            $currPct = [uint32]($gasValue * 100 / $AxisMax)
            $State.currentPercent = $currPct
            if ($currPct -gt $State.estimate_window_peak_percent) { $State.estimate_window_peak_percent = $currPct }
          }

          if ([uint32]($nowTick - $State.estimate_window_start_time) -ge $GasCooldownMs) {
            $peakPct = $State.estimate_window_peak_percent

            if ($peakPct -ge $GasMinUsage -and $peakPct -lt $State.best_estimate_percent) {
              $State.best_estimate_percent = $peakPct

              if ([uint32]($nowTick - $State.last_estimate_print_time) -ge $GasCooldownMs) {
                $State.gas_estimate_decreased = 1
                $State.last_estimate_print_time = $nowTick
                $State.last_printed_estimate = $peakPct

                $msg = ("New deadzone estimation {0} percent." -f $peakPct)
                if ($VerboseEnabled) { Write-Host $msg -ForegroundColor Cyan }
                if ($Synth) { $Synth.SpeakAsync($msg) | Out-Null }
              }

              if ($AutoGasAdjustEnabled -and $peakPct -lt $GasDeadzoneOut -and $peakPct -ge $AutoGasDeadzoneMin) {
                # Auto-adjust is a REAL runtime config change: recompute gasFullMin (do not do this every loop).
                $GasDeadzoneOut = $peakPct
                $State.gas_deadzone_out = [int]$GasDeadzoneOut

                $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
                $State.gasFullMin = $GasFullMin
                $State.gas_auto_adjust_applied = 1

                $msg = ("Auto adjusted deadzone to {0} percent." -f $GasDeadzoneOut)
                if ($VerboseEnabled) { Write-Host $msg -ForegroundColor Cyan }
                if ($Synth) { $Synth.SpeakAsync($msg) | Out-Null }
              }
            }

            $State.estimate_window_start_time = $nowTick
            $State.estimate_window_peak_percent = 0
          }
        }
      }
    }

    # --- Publish normal telemetry frame ---
    if ([bool]$Telemetry) {
      Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -LoopStartMs $LoopStartMs -Stopwatch $Stopwatch
    }

    $tickEnd = [uint32][Environment]::TickCount
    $PrevLoopMs = [uint32]($tickEnd - $tickStart)

    Start-Sleep -Milliseconds $SleepTime
  }
}
finally {
  Write-Host "Shutting down..." -ForegroundColor Yellow
  [Fanatec.Shared]::StopSignal = $true

  # Stop the HttpListener to unblock GetContext() and release port 8181 immediately.
  try {
    if ([Fanatec.Shared]::GlobalListener) {
      [Fanatec.Shared]::GlobalListener.Stop()
      [Fanatec.Shared]::GlobalListener.Close()
      [Fanatec.Shared]::GlobalListener = $null
    }
  } catch {}

  try { if ($HttpInstance) { $HttpInstance.Stop(); $HttpInstance.Dispose() } } catch {}
  try { if ($HttpInstance -and $HttpInstance.Runspace) { $HttpInstance.Runspace.Close() } } catch {}

  if ($Synth) { try { $Synth.Dispose() } catch {} }

  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
  Write-Host "Finalized." -ForegroundColor Yellow
}
