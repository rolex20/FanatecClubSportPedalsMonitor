<#
.SYNOPSIS
    FanatecPedals.ps1 v2.5.1
    Unified Fanatec Pedals Monitor and Telemetry Bridge.

.DESCRIPTION
    Monitors Fanatec Pedals for clutch noise and gas drift.
    Provides async TTS alerts and an HTTP JSON telemetry server on port 8181.

    Compatibility Goal:
    Replace main.c + pedBridge.ps1 permanently by serving an equivalent HTTP contract and
    publishing a full, legacy-compatible telemetry frame (field names AND meaningful values).

.VERSION HISTORY
    2.5.1 - Hardening: Guard logical % math when fullMin <= idleMax (matches main.c ComputeLogicalPct)
            Compatibility: bridgeInfo.batchId uses Interlocked increment (matches pedBridge.ps1)
    2.5   - Compatibility: pedBridge-like HTTP headers + OPTIONS
            Compatibility: publish disconnect/reconnect event frames (matches main.c semantics)
            Compatibility: populate legacy fields that were previously always 0
            Fix: tts_enabled boolean assignment
            Fix: clean shutdown - stop HttpListener to unblock GetContext() and free port 8181
            Fix: remove unsafe "fallback to joystick ID 0"
    2.4   - Fix: Background thread orphaned on CTRL+C (Server kept running).
            Refactored Start-HttpServer to return instance control.
    2.3   - Fix: Restored legacy telemetry fields (fullLoopTime_ms) for compatibility.
    2.2   - Fix: HTTP Frames Empty (SessionStateProxy injection).
    2.1   - Fix: Pipeline order.
    2.0   - Unified C logic and PowerShell Bridge.
#>

[CmdletBinding()]
param (
    # --- HARDWARE DEFAULTS ---
    [Alias("s")][int]$SleepTime = 1000,               # Interval between checks (ms)
    [Alias("m")][int]$Margin = 5,                     # Clutch noise tolerance (%)
    [Alias("clutch-repeat")][int]$ClutchRepeat = 4,   # Samples required to trigger Rudder alert
    [switch]$NoAxisNormalization,                     # Use raw values (do not invert)

    # --- GAS TUNING DEFAULTS ---
    [Alias("gas-deadzone-in")][int]$GasDeadzoneIn = 5,        # % Idle
    [Alias("gas-deadzone-out")][int]$GasDeadzoneOut = 93,     # % Full Throttle
    [Alias("gas-window")][int]$GasWindow = 30,                # Seconds to wait for full throttle
    [Alias("gas-cooldown")][int]$GasCooldown = 60,            # Seconds between alerts
    [Alias("gas-timeout")][int]$GasTimeout = 10,              # Seconds idle to assume menu/pause
    [Alias("gas-min-usage")][int]$GasMinUsage = 20,           # Minimum usage (%) for drift logic

    # --- AUTO-ADJUST SETTINGS ---
    [Alias("estimate-gas-deadzone-out")][switch]$EstimateGasDeadzone,
    [Alias("adjust-deadzone-out-with-minimum")][int]$AutoGasDeadzoneMin = -1, # -1 = Disabled

    # --- DEVICE SELECTION ---
    [Alias("j")][int]$JoystickID = 17,                # 17 is a sentinel meaning "use VID/PID scan"
    [Alias("v")][string]$VendorId,                    # Hex string (e.g. "0EB7")
    [Alias("p")][string]$ProductId,                   # Hex string (e.g. "1839")

    # --- FEATURE FLAGS ---
    [switch]$MonitorClutch,
    [switch]$MonitorGas,
    [switch]$Telemetry = $true,                       # Default true: required for PedDash
    [switch]$Tts = $true,                             # Default true
    [switch]$NoTts,                                   # Hard-disable TTS
    [switch]$NoConsoleBanner,
    [switch]$DebugRaw,
    [Alias("i")][int]$Iterations = 0,                 # 0 = infinite loop

    # --- HELP ---
    [switch]$Help
)

# -----------------------------------------------------------------------------
# SECTION 1: AUTO-HELP LOGIC
# -----------------------------------------------------------------------------
$ShowHelp = $Help.IsPresent -or ($PSBoundParameters.Count -eq 0)
if ($ShowHelp) {
    Write-Host @"
Usage: .\FanatecPedals.ps1 [options]

   Auto-Reconnect:
       -VendorId "HEX"      Vendor ID (e.g. 0EB7) for auto-reconnection.
       -ProductId "HEX"     Product ID (e.g. 1839) for auto-reconnection.
       -JoystickID N        If N >= 16, VID/PID scan mode is expected.

   Clutch & Gas:
       -MonitorClutch       Enable Clutch spike monitoring.
       -MonitorGas          Enable Gas drift monitoring.

   Telemetry & UI:
       -Telemetry           Enable HTTP JSON telemetry on port 8181 (Default: On).
       -Tts                 Enable Text-to-Speech alerts (Default: On).
       -NoTts               Disable Text-to-Speech alerts.
       -NoConsoleBanner     Suppress startup banners.

   General:
       -Help                Show this help message and exit.
       -Verbose             Enable verbose logging (prints axis values, config).
       -Iterations N        Number of loops (0 = Infinite).
       -SleepTime MS        Wait time (ms) between checks. Default=1000.
       -NoAxisNormalization Do NOT invert pedal axes (use raw values).
       -DebugRaw            Print raw vs normalized values in Verbose mode.

   Gas Tuning Options (-MonitorGas only):
       -GasDeadzoneIn N     % Idle Deadzone (0-100). Default=5.
       -GasDeadzoneOut N    % Full-throttle threshold (0-100). Default=93.
       -GasWindow Sec       Seconds to wait for Full Throttle. Default=30.
       -GasTimeout Sec      Seconds idle to assume Menu/Pause. Default=10.
       -GasCooldown Sec     Seconds between alerts. Default=60.
       -GasMinUsage %       Min gas usage before drift alert. Default=20.
       -EstimateGasDeadzone
                            Estimate suggested -GasDeadzoneOut from max travel.
       -AutoGasDeadzoneMin N
                            Auto-decrease deadzone-out, but never below N.

   Clutch Tuning Options (-MonitorClutch only):
       -ClutchRepeat N      Consecutive samples required for clutch noise alert.
"@
    exit
}

# -----------------------------------------------------------------------------
# SECTION 2: TEXT STRINGS
# -----------------------------------------------------------------------------
$Strings = @{
    Banner           = "Fanatec Pedals Monitor & Bridge v2.5.1 started."
    Connected        = "Controller connected."
    Disconnected     = "Controller disconnected. Waiting..."
    LookingForDevice = "Looking for Controller VID:{0} PID:{1}..."
    FoundDevice      = "Found at ID: {0}"
    ScanFailed       = "Scan failed. Retrying in {0}s..."

    AlertRudder      = "Rudder."
    AlertGasDrift    = "Gas {0} percent."
    AlertNewEstimate = "New deadzone estimation {0} percent."
    AlertAutoAdjust  = "Auto adjusted deadzone to {0} percent."
}

# -----------------------------------------------------------------------------
# SECTION 3: LOGIC SETUP
# -----------------------------------------------------------------------------

# Detect Verbose Mode from CmdletBinding
$Verbose = ($PSCmdlet.MyInvocation.BoundParameters["Verbose"] -eq $true) -or ($VerbosePreference -ne 'SilentlyContinue')

# Resolve feature flags to consistent booleans
if ($NoTts) { $Tts = $false }
$AxisNormalization = -not $NoAxisNormalization
$AutoGasAdjustEnabled = ($AutoGasDeadzoneMin -ge 0)
if ($AutoGasAdjustEnabled -and $AutoGasDeadzoneMin -eq -1) { $AutoGasDeadzoneMin = 0 }

# -----------------------------------------------------------------------------
# SECTION 4: C# INTEROP & HELPERS
# -----------------------------------------------------------------------------
$Source = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Concurrent;

namespace Fanatec {

    [Serializable]
    public class PedalMonState {
        // Config & Flags
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

        // UI Indicators
        public uint gas_physical_pct;
        public uint clutch_physical_pct;
        public uint gas_logical_pct;
        public uint clutch_logical_pct;

        // Runtime State
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

        // Estimation
        public uint best_estimate_percent;
        public uint last_printed_estimate;
        public uint estimate_window_peak_percent;
        public uint estimate_window_start_time;
        public uint last_estimate_print_time;

        // Samples
        public uint currentTime;
        public uint rawGas;
        public uint rawClutch;
        public uint gasValue;
        public uint clutchValue;
        public int  closure;
        public uint percentReached;
        public uint currentPercent;
        public uint iLoop;

        // Telemetry Metadata (C Legacy)
        public uint producer_loop_start_ms;
        public uint producer_notify_ms;
        public uint fullLoopTime_ms;
        public uint telemetry_sequence;

        // Telemetry Metadata (PS Bridge Extensions)
        public long receivedAtUnixMs;
        public double metricHttpProcessMs;
        public double metricTtsSpeakMs;
        public double metricLoopProcessMs;

        // Events
        public int gas_alert_triggered;
        public int clutch_alert_triggered;
        public int controller_disconnected;
        public int controller_reconnected;
        public int gas_estimate_decreased;
        public int gas_auto_adjust_applied;

        // Timestamps
        public uint last_disconnect_time_ms;
        public uint last_reconnect_time_ms;

        public PedalMonState Clone() {
            return (PedalMonState)this.MemberwiseClone();
        }
    }

    public static class Shared {
        public static ConcurrentQueue<PedalMonState> TelemetryQueue = new ConcurrentQueue<PedalMonState>();
        public static double LastHttpTimeMs = 0;
        public static double LastTtsTimeMs = 0;

        // StopSignal is polled by the HTTP runspace loop.
        // The main runspace will also stop the HttpListener to unblock GetContext().
        public static volatile bool StopSignal = false;

        // Exposes the active HttpListener so the main runspace can shut it down cleanly.
        public static System.Net.HttpListener GlobalListener = null;

        // pedBridge-compatible monotonically increasing HTTP batch counter.
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

        [DllImport("winmm.dll")]
        public static extern uint joyGetNumDevs();

        [DllImport("winmm.dll")]
        public static extern uint joyGetDevCaps(uint uJoyID, out JOYCAPS pjc, uint cbjc);

        [DllImport("winmm.dll")]
        public static extern uint joyGetPosEx(uint uJoyID, ref JOYINFOEX pji);

        public const uint JOY_RETURNALL = 255;
        public const uint JOYERR_NOERROR = 0;

        public static bool CheckDevice(uint id, int vid, int pid) {
            JOYCAPS caps = new JOYCAPS();
            if (joyGetDevCaps(id, out caps, (uint)Marshal.SizeOf(caps)) == JOYERR_NOERROR) {
                return (caps.wMid == vid && caps.wPid == pid);
            }
            return false;
        }

        public static int GetPosition(uint id, out uint gas, out uint clutch) {
            JOYINFOEX info = new JOYINFOEX();
            info.dwSize = (uint)Marshal.SizeOf(info);
            info.dwFlags = JOY_RETURNALL;

            uint res = joyGetPosEx(id, ref info);
            gas = info.dwYpos;
            clutch = info.dwRpos;
            return (int)res;
        }
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'Fanatec.Hardware').Type) {
    Add-Type -TypeDefinition $Source -Language CSharp
} else {
    Write-Warning "Using existing C# definition. If you modified the embedded C# code, restart PowerShell so Add-Type can load the new version."
}

# -----------------------------------------------------------------------------
# SECTION 5: HELPER FUNCTIONS
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
      Matches main.c ComputeLogicalPct() behavior:
        - <= idle => 0
        - >= full => 100
        - guard: if full <= idle => 0 (prevents divide-by-zero / negative ranges)
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

function Enqueue-TelemetryFrame {
    <#
      Normalizes the telemetry "publish" behavior so:
        - telemetry_sequence always increments
        - timestamps + perf metrics are consistent
        - the queued frame is a clone (immutable snapshot)
    #>
    param(
        [Parameter(Mandatory=$true)][Fanatec.PedalMonState]$State,
        [Parameter(Mandatory=$true)][int]$TelemetrySeq,
        [Parameter(Mandatory=$true)][double]$LoopStartMs,
        [Parameter(Mandatory=$true)][System.Diagnostics.Stopwatch]$Stopwatch
    )

    $TelemetrySeq++
    $State.telemetry_sequence = [uint32]$TelemetrySeq
    $State.receivedAtUnixMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $State.metricHttpProcessMs = [double][Fanatec.Shared]::LastHttpTimeMs
    $State.metricTtsSpeakMs = [double][Fanatec.Shared]::LastTtsTimeMs
    $State.metricLoopProcessMs = [double]($Stopwatch.Elapsed.TotalMilliseconds - $LoopStartMs)
    $State.producer_notify_ms = [uint32][Environment]::TickCount

    [Fanatec.Shared]::TelemetryQueue.Enqueue($State.Clone())
    return $TelemetrySeq
}

function Create-HttpServerInstance {
    param($Queue)

    # Run the HttpListener loop in a background runspace so the main loop can keep sampling hardware.
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"
    $rs.Open()

    # SessionStateProxy lets us inject live references (like the queue) into the background runspace scope.
    $rs.SessionStateProxy.SetVariable('Q', $Queue)

    # Background thread error logging path (best-effort; avoids silent failures).
    $logPath = "$PWD\http_debug.log"
    $rs.SessionStateProxy.SetVariable('LogPath', $logPath)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs

    $ps.AddScript({
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:8181/")
        $listener.Start()

        # Publish the listener handle to shared state so Ctrl+C can stop it (this unblocks GetContext()).
        try { [Fanatec.Shared]::GlobalListener = $listener } catch {}

        $sw = [System.Diagnostics.Stopwatch]::New()

        try {
            while ($listener.IsListening -and -not [Fanatec.Shared]::StopSignal) {
                try {
                    # GetContext blocks until a request arrives (listener.Stop() will unblock it).
                    $context = $listener.GetContext()
                    $sw.Restart()

                    $request  = $context.Request
                    $response = $context.Response

                    # Match pedBridge-style CORS + no-cache behavior for maximum UI compatibility.
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

                    # pedBridge-compatible monotonic batch id (thread-safe even if you later parallelize).
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

                    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 5))
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
        catch {
            Add-Content -Path $LogPath -Value ("[{0}] HTTP fatal error: {1}" -f [DateTime]::Now, $_)
        }
        finally {
            try {
                if ($listener) {
                    $listener.Stop()
                    $listener.Close()
                }
            } catch {}
            try { [Fanatec.Shared]::GlobalListener = $null } catch {}
        }
    }) | Out-Null

    return $ps
}

# -----------------------------------------------------------------------------
# SECTION 6: INITIALIZATION
# -----------------------------------------------------------------------------
try {
    # Reset shared state (important when re-running in the same PS session).
    [Fanatec.Shared]::StopSignal = $false
    [Fanatec.Shared]::LastHttpTimeMs = 0
    [Fanatec.Shared]::LastTtsTimeMs = 0
    try { [Fanatec.Shared]::BatchId = 0 } catch {}
    try { [Fanatec.Shared]::GlobalListener = $null } catch {}

    # Clear telemetry queue so a restart doesn't serve stale frames.
    try {
        [Fanatec.Shared]::TelemetryQueue = [System.Collections.Concurrent.ConcurrentQueue[Fanatec.PedalMonState]]::new()
    } catch {
        $tmp = $null
        while ([Fanatec.Shared]::TelemetryQueue.TryDequeue([ref]$tmp)) { }
    }

    # Process Priority (keeps sampling stable if the system is busy)
    $p = Get-Process -Id $PID
    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High

    # Setup TTS only if enabled
    $Synth = $null
    $TtsWatch = $null
    if ([bool]$Tts) {
        Add-Type -AssemblyName System.speech
        $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $Synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)
        $TtsWatch = [System.Diagnostics.Stopwatch]::New()
    }

    # Parse VID/PID
    $TargetVid = if ($VendorId) { [Convert]::ToInt32($VendorId, 16) } else { 0 }
    $TargetPid = if ($ProductId) { [Convert]::ToInt32($ProductId, 16) } else { 0 }

    if (($VendorId -and -not $ProductId) -or (-not $VendorId -and $ProductId)) {
        throw "Provide both -VendorId and -ProductId (HEX) for auto-reconnect."
    }
    if ($JoystickID -ge 16 -and $TargetVid -eq 0) {
        throw "JoystickID $JoystickID is an auto-detect sentinel. Provide -VendorId/-ProductId or set -JoystickID to a valid value (0-15)."
    }

    # --- HTTP SERVER STARTUP ---
    $HttpInstance = $null
    $HttpAsyncResult = $null

    if ([bool]$Telemetry) {
        $TelemetryQueue = [Fanatec.Shared]::TelemetryQueue
        $HttpInstance = Create-HttpServerInstance -Queue $TelemetryQueue
        $HttpAsyncResult = $HttpInstance.BeginInvoke()
        if ($Verbose) { Write-Host "Telemetry: HTTP server initialized on http://localhost:8181/" -ForegroundColor Cyan }
    } else {
        if ($Verbose) { Write-Host "Telemetry disabled (-Telemetry:$false). No HTTP server will be started." -ForegroundColor Yellow }
    }

    # Optional: try a one-time scan at startup if we're in VID/PID mode
    if ($JoystickID -ge 16 -and $TargetVid -ne 0 -and $TargetPid -ne 0) {
        if ($Verbose) { Write-Host ($Strings.LookingForDevice -f $VendorId, $ProductId) -ForegroundColor Cyan }
        $found = Find-FanatecDevice $TargetVid $TargetPid
        if ($found -ne -1) {
            $JoystickID = $found
            if ($Verbose) { Write-Host ($Strings.FoundDevice -f $JoystickID) -ForegroundColor Green }
        } else {
            Write-Warning "Device not found at startup. Will wait for it to appear..."
        }
    }

    $State = New-Object Fanatec.PedalMonState

    # Config / flags (populate ALL legacy fields for compatibility)
    $State.verbose_flag = [int][bool]$Verbose
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

    # Runtime/static fields
    $State.joy_ID = [uint32]$JoystickID
    $State.joy_Flags = [uint32][Fanatec.Hardware]::JOY_RETURNALL
    $State.iterations = [uint32]$Iterations
    $State.margin = [uint32]$Margin
    $State.sleep_Time = [uint32]$SleepTime

    # Runtime Logic Variables
    $AxisMax = 65535
    $GasIdleMax = [uint32]($AxisMax * $GasDeadzoneIn / 100)
    $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
    $AxisMargin = [uint32]($AxisMax * $Margin / 100)

    $GasTimeoutMs = [uint32]($GasTimeout * 1000)
    $GasWindowMs  = [uint32]($GasWindow * 1000)
    $GasCooldownMs = [uint32]($GasCooldown * 1000)

    $State.axisMax = [uint32]$AxisMax
    $State.axisMargin = [uint32]$AxisMargin
    $State.gasIdleMax = [uint32]$GasIdleMax
    $State.gasFullMin = [uint32]$GasFullMin
    $State.gas_timeout_ms = $GasTimeoutMs
    $State.gas_window_ms = $GasWindowMs
    $State.gas_cooldown_ms = $GasCooldownMs

    # main.c-like runtime state
    $LastFullThrottleTime = [uint32][Environment]::TickCount
    $LastGasActivityTime  = [uint32][Environment]::TickCount
    $LastGasAlertTime     = [uint32]0
    $EstimateWindowStartTime = [uint32][Environment]::TickCount
    $BestEstimatePercent = [uint32]100
    $LastPrintedEstimate = [uint32]100
    $EstimateWindowPeakPercent = [uint32]0
    $LastEstimatePrintTime = [uint32]0

    $PeakGasInWindow = [uint32]0
    $LastClutchValue = [uint32]0
    $RepeatingClutchCount = 0
    $IsRacing = $false

    $LoopCount = 0
    $TelemetrySeq = 0
    $PreviousLoopTimeMs = 0

    # Seed estimator fields (prevents “forever 0” dashboard values)
    $State.best_estimate_percent = $BestEstimatePercent
    $State.last_printed_estimate = $LastPrintedEstimate
    $State.estimate_window_peak_percent = $EstimateWindowPeakPercent
    $State.estimate_window_start_time = $EstimateWindowStartTime
    $State.last_estimate_print_time = $LastEstimatePrintTime

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($Verbose) {
        Write-Host ("Monitoring ID=[{0}]" -f $JoystickID) -ForegroundColor Cyan
        Write-Host ("Axis Max: [{0}]" -f $AxisMax) -ForegroundColor Cyan
        Write-Host ("Axis normalization: {0}" -f $(if ($AxisNormalization) { "enabled" } else { "disabled" })) -ForegroundColor Cyan
        if ($MonitorGas) {
            Write-Host ("Gas Config: DZ In:{0}% Out:{1}% Window:{2}s Timeout:{3}s Cooldown:{4}s MinUsage:{5}%" -f $GasDeadzoneIn, $GasDeadzoneOut, $GasWindow, $GasTimeout, $GasCooldown, $GasMinUsage) -ForegroundColor Cyan
            if ($EstimateGasDeadzone) { Write-Host "Gas Estimation: enabled." -ForegroundColor Cyan }
            if ($AutoGasAdjustEnabled) { Write-Host ("Gas Auto-Adjust: enabled (minimum={0})." -f $AutoGasDeadzoneMin) -ForegroundColor Cyan }
        }
    }

    if (-not $NoConsoleBanner) { Write-Host $Strings.Banner -ForegroundColor Green }

    # -----------------------------------------------------------------------------
    # SECTION 7: MAIN LOOP
    # -----------------------------------------------------------------------------
    while ($Iterations -eq 0 -or $LoopCount -lt $Iterations) {
        $LoopStart = $Stopwatch.Elapsed.TotalMilliseconds

        # Telemetry timing bookkeeping (matches main.c pattern)
        $TickStart = [uint32][Environment]::TickCount
        $State.producer_loop_start_ms = $TickStart
        $State.fullLoopTime_ms = [uint32]$PreviousLoopTimeMs

        $LoopCount++
        $State.iLoop = [uint32]$LoopCount

        # Reset per-frame one-shot event flags. controller_disconnected is a latched state.
        $State.gas_alert_triggered = 0
        $State.clutch_alert_triggered = 0
        $State.controller_reconnected = 0
        $State.gas_estimate_decreased = 0
        $State.gas_auto_adjust_applied = 0

        $rawGas = 0
        $rawClutch = 0
        $res = [Fanatec.Hardware]::GetPosition([uint32]$JoystickID, [ref]$rawGas, [ref]$rawClutch)

        # --- Disconnect handling (publish disconnect frame once; optionally enter reconnect scan mode) ---
        if ($res -ne 0) {
            if ($State.controller_disconnected -eq 0) {
                if ($Verbose) { Write-Host "Error Reading Joystick ($res). Disconnected." -ForegroundColor Red }
                if ($Synth) { $Synth.SpeakAsync($Strings.Disconnected) | Out-Null }

                $State.controller_disconnected = 1
                $State.last_disconnect_time_ms = [uint32][Environment]::TickCount
                $State.currentTime = $State.last_disconnect_time_ms

                if ([bool]$Telemetry) {
                    $TelemetrySeq = Enqueue-TelemetryFrame -State $State -TelemetrySeq $TelemetrySeq -LoopStartMs $LoopStart -Stopwatch $Stopwatch
                }
            }

            # If VID/PID are provided, match main.c behavior: enter a scan loop and only return when found (or stop requested).
            if ($TargetVid -ne 0 -and $TargetPid -ne 0) {
                if ($Verbose) { Write-Host "Entering Reconnection Mode..." -ForegroundColor Yellow }

                while (-not [Fanatec.Shared]::StopSignal) {
                    if ($Verbose) { Write-Host ($Strings.ScanFailed -f 60) -ForegroundColor Red }
                    Start-Sleep -Seconds 60

                    $newId = Find-FanatecDevice $TargetVid $TargetPid
                    if ($newId -ne -1) {
                        $JoystickID = $newId
                        $State.joy_ID = [uint32]$newId

                        if ($Verbose) { Write-Host ("Reconnected at ID {0}" -f $newId) -ForegroundColor Green }
                        if ($Synth) { $Synth.SpeakAsync($Strings.Connected) | Out-Null }

                        # Event: Controller Reconnected
                        $State.controller_disconnected = 0
                        $State.controller_reconnected  = 1
                        $State.last_reconnect_time_ms  = [uint32][Environment]::TickCount
                        $State.currentTime = $State.last_reconnect_time_ms

                        if ([bool]$Telemetry) {
                            $TelemetrySeq = Enqueue-TelemetryFrame -State $State -TelemetrySeq $TelemetrySeq -LoopStartMs $LoopStart -Stopwatch $Stopwatch
                        }

                        # Reset runtime state so we do not immediately alert after reconnect.
                        $LastFullThrottleTime = [uint32][Environment]::TickCount
                        $LastGasActivityTime  = $LastFullThrottleTime
                        $LastGasAlertTime     = 0
                        $IsRacing             = $false
                        $PeakGasInWindow      = 0
                        $LastClutchValue      = 0
                        $RepeatingClutchCount = 0
                        $BestEstimatePercent  = 100
                        $LastPrintedEstimate  = 100
                        $EstimateWindowPeakPercent = 0
                        $EstimateWindowStartTime = [uint32][Environment]::TickCount
                        $LastEstimatePrintTime = 0

                        break
                    }
                }

                continue
            }

            # Without VID/PID, we simply retry periodically on the same ID.
            Start-Sleep -Milliseconds 1000
            continue
        }

        # If we were previously disconnected and the device starts responding again (same ID), publish a reconnect event frame.
        if ($State.controller_disconnected -eq 1) {
            if ($Verbose) { Write-Host "Controller responding again (same ID). Marking reconnected." -ForegroundColor Green }
            if ($Synth) { $Synth.SpeakAsync($Strings.Connected) | Out-Null }

            $State.controller_disconnected = 0
            $State.controller_reconnected  = 1
            $State.last_reconnect_time_ms  = [uint32][Environment]::TickCount
            $State.currentTime = $State.last_reconnect_time_ms

            if ([bool]$Telemetry) {
                $TelemetrySeq = Enqueue-TelemetryFrame -State $State -TelemetrySeq $TelemetrySeq -LoopStartMs $LoopStart -Stopwatch $Stopwatch
            }

            # Reset runtime state (prevents immediate post-reconnect false positives)
            $LastFullThrottleTime = [uint32][Environment]::TickCount
            $LastGasActivityTime  = $LastFullThrottleTime
            $LastGasAlertTime     = 0
            $IsRacing             = $false
            $PeakGasInWindow      = 0
            $LastClutchValue      = 0
            $RepeatingClutchCount = 0
            $BestEstimatePercent  = 100
            $LastPrintedEstimate  = 100
            $EstimateWindowPeakPercent = 0
            $EstimateWindowStartTime = [uint32][Environment]::TickCount
            $LastEstimatePrintTime = 0

            Start-Sleep -Milliseconds 250
            continue
        }

        # --- Normalization & sample capture ---
        $State.currentTime = [uint32][Environment]::TickCount
        $State.rawGas = [uint32]$rawGas
        $State.rawClutch = [uint32]$rawClutch

        if ($AxisNormalization) {
            $State.gasValue = [uint32]($AxisMax - $rawGas)
            $State.clutchValue = [uint32]($AxisMax - $rawClutch)
        } else {
            $State.gasValue = [uint32]$rawGas
            $State.clutchValue = [uint32]$rawClutch
        }

        if ($Verbose) {
            if ($DebugRaw) {
                Write-Host ("{0}, gas_raw={1} gas_norm={2}, clutch_raw={3} clutch_norm={4}" -f $State.currentTime, $rawGas, $State.gasValue, $rawClutch, $State.clutchValue)
            } else {
                Write-Host ("{0}, gas={1}, clutch={2}" -f $State.currentTime, $State.gasValue, $State.clutchValue)
            }
        }

        # --- Percentages ---
        $State.gas_physical_pct = [uint32](100 * $State.gasValue / $AxisMax)
        $State.clutch_physical_pct = [uint32](100 * $State.clutchValue / $AxisMax)

        # Logical percentages (guarded to avoid divide-by-zero if thresholds are misconfigured)
        $State.gas_logical_pct = Convert-ToLogicalPct -Value $State.gasValue -IdleMax $GasIdleMax -FullMin $GasFullMin
        $State.clutch_logical_pct = Convert-ToLogicalPct -Value $State.clutchValue -IdleMax $GasIdleMax -FullMin $GasFullMin

        # --- Clutch Logic ---
        if ($MonitorClutch) {
            if ($State.gasValue -le $GasIdleMax -and $State.clutchValue -gt 0) {
                $diff = [Math]::Abs([int64]$State.clutchValue - [int64]$LastClutchValue)
                $State.closure = [int]$diff

                if ($diff -le $AxisMargin) { $RepeatingClutchCount++ }
                else { $RepeatingClutchCount = 0 }
            } else {
                $RepeatingClutchCount = 0
            }

            $LastClutchValue = $State.clutchValue

            if ($RepeatingClutchCount -ge $ClutchRepeat) {
                $State.clutch_alert_triggered = 1

                if ($Verbose) { Write-Host "Rudder Alert" -ForegroundColor Yellow }
                if ($Synth) {
                    $TtsWatch.Restart()
                    $Synth.SpeakAsync($Strings.AlertRudder) | Out-Null
                    $TtsWatch.Stop()
                    [Fanatec.Shared]::LastTtsTimeMs = $TtsWatch.Elapsed.TotalMilliseconds
                }

                $RepeatingClutchCount = 0
            }
        }

        # --- Gas Logic ---
        if ($MonitorGas) {
            if ($State.gasValue -gt $GasIdleMax) {
                if (-not $IsRacing) {
                    $LastFullThrottleTime = $State.currentTime
                    $PeakGasInWindow = 0

                    if ($EstimateGasDeadzone) {
                        $EstimateWindowStartTime = $State.currentTime
                        $EstimateWindowPeakPercent = 0
                    }

                    if ($Verbose) { Write-Host "Gas: Activity Resumed." -ForegroundColor Cyan }
                    $IsRacing = $true
                }

                $LastGasActivityTime = $State.currentTime
            }
            elseif ($IsRacing -and ([uint32]($State.currentTime - $LastGasActivityTime) -gt $GasTimeoutMs)) {
                if ($Verbose) { Write-Host ("Gas: Auto-Pause (Idle for {0} s)." -f $GasTimeout) -ForegroundColor Cyan }
                $IsRacing = $false
            }

            if ($IsRacing) {
                if ($State.gasValue -gt $PeakGasInWindow) { $PeakGasInWindow = $State.gasValue }

                if ($State.gasValue -ge $GasFullMin) {
                    $LastFullThrottleTime = $State.currentTime
                    $PeakGasInWindow = 0
                }
                elseif ([uint32]($State.currentTime - $LastFullThrottleTime) -gt $GasWindowMs) {
                    if ([uint32]($State.currentTime - $LastGasAlertTime) -gt $GasCooldownMs) {
                        $pctReached = [uint32]($PeakGasInWindow * 100 / $AxisMax)
                        $State.percentReached = $pctReached

                        if ($pctReached -gt $GasMinUsage) {
                            $State.gas_alert_triggered = 1
                            $msg = $Strings.AlertGasDrift -f $pctReached

                            if ($Verbose) { Write-Host $msg -ForegroundColor Yellow }
                            if ($Synth) {
                                $TtsWatch.Restart()
                                $Synth.SpeakAsync($msg) | Out-Null
                                $TtsWatch.Stop()
                                [Fanatec.Shared]::LastTtsTimeMs = $TtsWatch.Elapsed.TotalMilliseconds
                            }

                            $LastGasAlertTime = $State.currentTime
                        }
                    }
                }

                # Deadzone-out estimator
                if ($EstimateGasDeadzone) {
                    if ($State.gasValue -gt $GasIdleMax) {
                        $currPct = [uint32]($State.gasValue * 100 / $AxisMax)
                        $State.currentPercent = $currPct

                        if ($currPct -gt $EstimateWindowPeakPercent) { $EstimateWindowPeakPercent = $currPct }
                    }

                    if ([uint32]($State.currentTime - $EstimateWindowStartTime) -ge $GasCooldownMs) {
                        if ($EstimateWindowPeakPercent -ge $GasMinUsage) {
                            if ($EstimateWindowPeakPercent -lt $BestEstimatePercent) {
                                $BestEstimatePercent = $EstimateWindowPeakPercent

                                if ([uint32]($State.currentTime - $LastEstimatePrintTime) -ge $GasCooldownMs) {
                                    $msg = $Strings.AlertNewEstimate -f $BestEstimatePercent
                                    if ($Verbose) { Write-Host $msg -ForegroundColor Cyan }
                                    if ($Synth) { $Synth.SpeakAsync($msg) | Out-Null }

                                    $State.gas_estimate_decreased = 1
                                    $LastEstimatePrintTime = $State.currentTime
                                    $LastPrintedEstimate = $BestEstimatePercent
                                }

                                if ($AutoGasAdjustEnabled -and $BestEstimatePercent -lt $GasDeadzoneOut -and $BestEstimatePercent -ge $AutoGasDeadzoneMin) {
                                    $GasDeadzoneOut = $BestEstimatePercent
                                    $State.gas_deadzone_out = [int]$GasDeadzoneOut

                                    $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
                                    $State.gas_auto_adjust_applied = 1

                                    $msg = $Strings.AlertAutoAdjust -f $GasDeadzoneOut
                                    if ($Verbose) { Write-Host $msg -ForegroundColor Cyan }
                                    if ($Synth) { $Synth.SpeakAsync($msg) | Out-Null }
                                }
                            }
                        }

                        $EstimateWindowStartTime = $State.currentTime
                        $EstimateWindowPeakPercent = 0
                    }
                }
            }
        }

        # Keep legacy runtime fields accurate for PedDash/debug parity
        $State.isRacing = [int][bool]$IsRacing
        $State.peakGasInWindow = [uint32]$PeakGasInWindow
        $State.lastFullThrottleTime = [uint32]$LastFullThrottleTime
        $State.lastGasActivityTime = [uint32]$LastGasActivityTime
        $State.lastGasAlertTime = [uint32]$LastGasAlertTime
        $State.lastClutchValue = [uint32]$LastClutchValue
        $State.repeatingClutchCount = [int]$RepeatingClutchCount

        $State.axisMax = [uint32]$AxisMax
        $State.axisMargin = [uint32]$AxisMargin
        $State.gasIdleMax = [uint32]$GasIdleMax
        $State.gasFullMin = [uint32]$GasFullMin
        $State.gas_timeout_ms = $GasTimeoutMs
        $State.gas_window_ms = $GasWindowMs
        $State.gas_cooldown_ms = $GasCooldownMs

        $State.best_estimate_percent = [uint32]$BestEstimatePercent
        $State.last_printed_estimate = [uint32]$LastPrintedEstimate
        $State.estimate_window_peak_percent = [uint32]$EstimateWindowPeakPercent
        $State.estimate_window_start_time = [uint32]$EstimateWindowStartTime
        $State.last_estimate_print_time = [uint32]$LastEstimatePrintTime

        # --- Telemetry Publish ---
        if ([bool]$Telemetry) {
            $TelemetrySeq = Enqueue-TelemetryFrame -State $State -TelemetrySeq $TelemetrySeq -LoopStartMs $LoopStart -Stopwatch $Stopwatch
        }

        # Duration for the current iteration (stored into fullLoopTime_ms on the next iteration)
        $TickEnd = [uint32][Environment]::TickCount
        $PreviousLoopTimeMs = $TickEnd - $TickStart

        Start-Sleep -Milliseconds $SleepTime
    }
}
catch {
    Write-Error "CRITICAL ERROR: $_"
}
finally {
    Write-Host "Shutting down..." -ForegroundColor Yellow

    [Fanatec.Shared]::StopSignal = $true

    # Stop the HttpListener to unblock GetContext() immediately (releases port 8181 cleanly).
    try {
        if ([Fanatec.Shared]::GlobalListener) {
            [Fanatec.Shared]::GlobalListener.Stop()
            [Fanatec.Shared]::GlobalListener.Close()
            [Fanatec.Shared]::GlobalListener = $null
        }
    } catch {}

    # Stop and dispose the background runspace instance.
    try { if ($HttpInstance) { $HttpInstance.Stop() } } catch {}
    try { if ($HttpInstance) { $HttpInstance.Dispose() } } catch {}
    try { if ($HttpInstance -and $HttpInstance.Runspace) { $HttpInstance.Runspace.Close() } } catch {}

    if ($Synth) { try { $Synth.Dispose() } catch {} }

    $HttpInstance = $null
    $HttpAsyncResult = $null
    $Synth = $null

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-Host "Finalized." -ForegroundColor Yellow
}
