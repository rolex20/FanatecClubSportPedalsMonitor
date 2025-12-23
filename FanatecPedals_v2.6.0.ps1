<#
.SYNOPSIS
    FanatecPedals.ps1 v2.6.0
    The Unified Fanatec Pedals Monitor and Telemetry Bridge.
    
.DESCRIPTION
    Monitors Fanatec Pedals for clutch noise and gas drift.
    Provides Async TTS alerts and an HTTP JSON Telemetry server.
    
    Version History:
    2.6.0 - Add brake axis selection + telemetry fields.
            Add configurable WinMM dwFlags constant (defaults to JOY_RETURNALL).
    2.5.1 - Hardening: Guard logical % math when fullMin <= idleMax (matches main.c ComputeLogicalPct)
            Compatibility: bridgeInfo.batchId uses Interlocked increment (matches pedBridge.ps1)
    2.5   - Compatibility: pedBridge-like HTTP headers + OPTIONS
            Compatibility: publish disconnect/reconnect event frames (matches main.c semantics)
            Compatibility: populate legacy fields that were previously always 0
            Fix: tts_enabled boolean assignment
            Fix: clean shutdown - stop HttpListener to unblock GetContext() and free port 8181
            Fix: remove unsafe "fallback to joystick ID 0"			
    2.4 - Fix: Background thread orphaned on CTRL+C (Server kept running).
          Refactored Start-HttpServer to return instance control.
    2.3 - Fix: Restored legacy telemetry fields (fullLoopTime_ms) for compatibility.
    2.2 - Fix: HTTP Frames Empty (SessionStateProxy injection).
    2.1 - Fix: Pipeline order.
    2.0 - Unified C logic and PowerShell Bridge.
#>

[CmdletBinding()]
param (
    # --- HARDWARE DEFAULTS ---
    [Alias("s")][int]$SleepTime = 1000,       # Interval between checks (ms)
    [Alias("m")][int]$Margin = 5,             # Clutch noise tolerance (%)
    [Alias("clutch-repeat")][int]$ClutchRepeat = 4, # Samples required to trigger Rudder alert
    [switch]$NoAxisNormalization,             # Use raw values (don't invert)
    
    # --- GAS TUNING DEFAULTS ---
    [Alias("gas-deadzone-in")][int]$GasDeadzoneIn = 5,      # % Idle
    [Alias("gas-deadzone-out")][int]$GasDeadzoneOut = 93,    # % Full Throttle
    [Alias("gas-window")][int]$GasWindow = 30,               # Time window to check for full throttle (sec)
    [Alias("gas-cooldown")][int]$GasCooldown = 60,           # Time between alerts (sec)
    [Alias("gas-timeout")][int]$GasTimeout = 10,             # Time before assuming "Pause/Menu" (sec)
    [Alias("gas-min-usage")][int]$GasMinUsage = 20,          # Min usage to trigger drift logic (%)
    
    # --- AUTO-ADJUST SETTINGS ---
    [Alias("estimate-gas-deadzone-out")][switch]$EstimateGasDeadzone,
    [Alias("adjust-deadzone-out-with-minimum")][int]$AutoGasDeadzoneMin = -1, # -1 = Disabled

    # --- DEVICE SELECTION ---
    [Alias("j")][int]$JoystickID = 17,        # Default 17 forces auto-detect search
    [Alias("v")][string]$VendorId,            # Hex String (e.g. "0EB7")
    [Alias("p")][string]$ProductId,           # Hex String (e.g. "1839")

    # --- FEATURE FLAGS ---
    [switch]$MonitorClutch,
    [switch]$MonitorGas,
    [switch]$Telemetry = $true,  # Default True for this script
    [switch]$Tts = $true,        # Default True
    [switch]$NoTts,              # Disables TTS
    [switch]$NoConsoleBanner,
    [switch]$DebugRaw,
    [Alias("i")][int]$Iterations = 0,  # 0 = Infinite loop
	[Alias("f","flags")][uint32]$JoyFlags = 255   # default JOY_RETURNALL	
    
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
       -VendorId "HEX"     Vendor ID (e.g. 0EB7) for auto-reconnection.
       -ProductId "HEX"    Product ID (e.g. 1839) for auto-reconnection.

   Clutch & Gas:
       -MonitorClutch      Enable Clutch spike monitoring.
       -MonitorGas         Enable Gas drift monitoring.

   Telemetry & UI:
       -Telemetry          Enable HTTP JSON telemetry on port 8181 (Default: On).
       -Tts                Enable Text-to-Speech alerts (Default: On).
       -NoTts              Disable Text-to-Speech alerts.
       -NoConsoleBanner    Suppress startup banners.

   General:
       -Help               Show this help message and exit.
       -Verbose            Enable verbose logging (prints axis values, config).
       -JoystickID N       Initial Joystick ID (0-15).
       -Iterations N       Number of loops (0 = Infinite).
       -SleepTime MS       Wait time (ms) between checks. Default=1000.
       -NoAxisNormalization Do NOT invert pedal axes (use raw values).
       -DebugRaw           Print raw vs normalized values in Verbose mode.
       -JoyFlags N         WinMM JOYINFOEX.dwFlags (main.c --flags). Examples:
                           255 = JOY_RETURNALL
                           266 = JOY_RETURNRAWDATA|JOY_RETURNR|JOY_RETURNY (gas and clutch)
                           270 = 266 + JOY_RETURNZ (adds Z axis for brake)

   Gas Tuning Options (-MonitorGas only):
       -GasDeadzoneIn N    % Idle Deadzone (0-100). Default=5.
       -GasDeadzoneOut N   % Full-throttle threshold (0-100). Default=93.
       -GasWindow Sec      Seconds to wait for Full Throttle. Default=30.
       -GasTimeout Sec     Seconds idle to assume Menu/Pause. Default=10.
       -GasCooldown Sec    Seconds between alerts. Default=60.
       -GasMinUsage %      Min gas usage before drift alert. Default=20.
       -EstimateGasDeadzone
                           Estimate suggested -GasDeadzoneOut from max travel.
       -AutoGasDeadzoneMin N
                           Auto-decrease deadzone-out, but never below N.

   Clutch Tuning Options (-MonitorClutch only):
       -ClutchRepeat N     Consecutive samples required for clutch noise alert.

"@
    exit
}

# -----------------------------------------------------------------------------
# SECTION 2: TEXT STRINGS
# -----------------------------------------------------------------------------
$Strings = @{
    Banner           = "Fanatec Pedals Monitor & Bridge v2.6.0 started."
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
# AXIS SELECTION (EDIT THESE AFTER RUNNING Discover-UsbControllerAxes.ps1)
# -----------------------------------------------------------------------------
# WinMM reports up to 6 joystick axes via JOYINFOEX: X, Y, Z, R, U, V.
# Use Discover-UsbControllerAxes.ps1 to see which axis moves when you press each pedal.

# Known Fanatec Pedals Axis
$GAS_AXIS    = 'Y'
$CLUTCH_AXIS = 'R'
$BRAKE_AXIS  = 'Z' # NEW: set this to the axis that moves when you press the brake pedal.

# WinMM joyGetPosEx dwFlags (matches main.c --flags). Default is JOY_RETURNALL (255).
# If you enable JOY_RETURNRAWDATA (256), Fanatec pedals often report 0..1023 instead of 0..65535.
$JOY_DWFLAGS = 255

# Other common values for dwFlags 
# flags = 266 = JOY_RETURNRAWDATA(Fanatec raw: 0–1023) | JOY_RETURNR | JOY_RETURNY
# flags = 270 = JOY_RETURNRAWDATA(Fanatec raw: 0–1023) | JOY_RETURNR | JOY_RETURNY | JOY_RETURNZ 
# -----------------------------------------------------------------------------

# Detect Verbose Mode from CmdletBinding
$Verbose = ($PSCmdlet.MyInvocation.BoundParameters["Verbose"] -eq $true) -or ($VerbosePreference -ne 'SilentlyContinue')

# Handle Feature Logic
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
        public uint brake_physical_pct;
        public uint gas_logical_pct;
        public uint clutch_logical_pct;
        public uint brake_logical_pct;

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
        public uint rawBrake;
        public uint gasValue;
        public uint clutchValue;
        public uint brakeValue;
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

        // Public Clone Method
        public PedalMonState Clone() {
            return (PedalMonState)this.MemberwiseClone();
        }
    }

    public static class Shared {
        public static ConcurrentQueue<PedalMonState> TelemetryQueue = new ConcurrentQueue<PedalMonState>();
        public static double LastHttpTimeMs = 0;
        public static double LastTtsTimeMs = 0;
        public static volatile bool StopSignal = false; // New: Clean Shutdown Signal
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

        public const uint JOY_RETURNX       = 0x00000001;
        public const uint JOY_RETURNY       = 0x00000002;
        public const uint JOY_RETURNZ       = 0x00000004;
        public const uint JOY_RETURNR       = 0x00000008;
        public const uint JOY_RETURNU       = 0x00000010;
        public const uint JOY_RETURNV       = 0x00000020;
        public const uint JOY_RETURNPOV     = 0x00000040;
        public const uint JOY_RETURNBUTTONS = 0x00000080;
        public const uint JOY_RETURNRAWDATA = 0x00000100;

        public const uint JOY_RETURNALL = 0x000000FF;
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
            info.dwSize = (uint)Marshal.SizeOf(info);
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
    Write-Warning "Using existing C# definition. If you modified the C# code, please restart PowerShell."
}

# -----------------------------------------------------------------------------
# SECTION 5: HELPER FUNCTIONS

function Get-AxisValue {
    <#
    .SYNOPSIS
        Returns the selected WinMM axis value from a JOYINFOEX snapshot.

    .DESCRIPTION
        Fanatec pedal sets can map Gas/Clutch/Brake to different axes depending on firmware/mode.
        Use Discover-UsbControllerAxes.ps1, then set $GAS_AXIS / $CLUTCH_AXIS / $BRAKE_AXIS at the top.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('X','Y','Z','R','U','V')][string]$Axis,
        [Parameter(Mandatory)][uint32]$X,
        [Parameter(Mandatory)][uint32]$Y,
        [Parameter(Mandatory)][uint32]$Z,
        [Parameter(Mandatory)][uint32]$R,
        [Parameter(Mandatory)][uint32]$U,
        [Parameter(Mandatory)][uint32]$V
    )

    switch ($Axis.ToUpperInvariant()) {
        'X' { return $X }
        'Y' { return $Y }
        'Z' { return $Z }
        'R' { return $R }
        'U' { return $U }
        'V' { return $V }
    }
}

# -----------------------------------------------------------------------------

function Find-FanatecDevice {
    param([int]$Vid, [int]$Pid)
    $count = [Fanatec.Hardware]::joyGetNumDevs()
    for ($i = 0; $i -lt $count; $i++) {
        if ([Fanatec.Hardware]::CheckDevice($i, $Vid, $Pid)) {
            return $i
        }
    }
    return -1
}

function Create-HttpServerInstance {
    param($Queue) 
    
    # Create the Runspace explicitly to inject variables via Proxy
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"
    $rs.Open()
    
    # INJECTION: Pass the Live Queue Reference directly to the background scope
    $rs.SessionStateProxy.SetVariable('Q', $Queue)
    
    # DEBUG: Pass a log path so the background thread can scream if it hurts
    $logPath = "$PWD\http_debug.log"
    $rs.SessionStateProxy.SetVariable('LogPath', $logPath)
    
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    
    $ps.AddScript({
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:8181/")
        $listener.Start()
        $sw = [System.Diagnostics.Stopwatch]::New()
        $localBatchId = 0
        
        try {
            # Loop check: Listening AND StopSignal is FALSE
            while ($listener.IsListening -and -not [Fanatec.Shared]::StopSignal) {
                try {
                    $context = $listener.GetContext()
                    $sw.Restart()
                    $response = $context.Response
                    $response.AddHeader("Access-Control-Allow-Origin", "*")
                    $response.AddHeader("Cache-Control", "no-store")
                    
                    # Generic List for JSON serialization
                    $frames = [System.Collections.Generic.List[Object]]::new()
                    $f = $null
                    
                    # DIRECT REFERENCE ACCESS: $Q is injected via SessionStateProxy
                    while ($Q.TryDequeue([ref]$f)) { $frames.Add($f) }
                    
                    $localBatchId++
                    
                    $payload = @{
                        schemaVersion = 1
                        bridgeInfo = @{
                            batchId = $localBatchId
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
                    # Best effort metric write-back
                    try { [Fanatec.Shared]::LastHttpTimeMs = $sw.Elapsed.TotalMilliseconds } catch {}
                    
                } catch {
                     # Log inner loop errors
                     Add-Content -Path $LogPath -Value ("[{0}] Frame Error: {1}" -f [DateTime]::Now, $_)
                }
            }
        } 
        catch {
             # Log fatal crash
             Add-Content -Path $LogPath -Value ("[{0}] FATAL: {1}" -f [DateTime]::Now, $_)
        }
        finally { 
            if ($listener) { $listener.Stop() } 
        }
    }) | Out-Null
    
    return $ps # Return control instance
}

# -----------------------------------------------------------------------------
# SECTION 6: INITIALIZATION
# -----------------------------------------------------------------------------
try {
    # Reset Stop Signal
    [Fanatec.Shared]::StopSignal = $false

    # Process Priority
    $p = Get-Process -Id $PID
    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High

    # Setup TTS
    Add-Type -AssemblyName System.speech
    $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $Synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)

    # --- HTTP SERVER STARTUP ---
    $TelemetryQueue = [Fanatec.Shared]::TelemetryQueue
    
    # 1. Create the Instance (Controller)
    $HttpInstance = Create-HttpServerInstance -Queue $TelemetryQueue
    
    # 2. Start it Async (Keep handle to check status if needed)
    $HttpAsyncResult = $HttpInstance.BeginInvoke()

    if ($Verbose) { Write-Host "Telemetry: Queue and HTTP Server initialized." -ForegroundColor Cyan }

    # Device Detection
    $TargetVid = if ($VendorId) { [Convert]::ToInt32($VendorId, 16) } else { 0 }
    $TargetPid = if ($ProductId) { [Convert]::ToInt32($ProductId, 16) } else { 0 }

    if ($JoystickID -ge 16 -and $TargetVid -ne 0) {
        if ($Verbose) { Write-Host ($Strings.LookingForDevice -f $VendorId, $ProductId) }
        $found = Find-FanatecDevice $TargetVid $TargetPid
        if ($found -ne -1) {
            $JoystickID = $found
            if ($Verbose) { Write-Host ($Strings.FoundDevice -f $JoystickID) -ForegroundColor Green }
        } else {
            Write-Warning "Device not found at startup. Using ID 0."
            $JoystickID = 0
        }
    }

    # State Variables
    $State = New-Object Fanatec.PedalMonState

    # Joystick dwFlags / axis resolution
	# Now $JoyFlags is read from command-line
    # $JoyFlags = [uint32]$JOY_DWFLAGS

    # WinMM returns 0..65535 by default. If JOY_RETURNRAWDATA is set, Fanatec pedals often report 0..1023.
    $AxisMax = if (($JoyFlags -band [Fanatec.Hardware]::JOY_RETURNRAWDATA) -ne 0) { 1023 } else { 65535 }

    
    # Cast flags safely to int for the C# Struct
    $State.verbose_flag = [int][bool]$Verbose
    $State.monitor_clutch = [int][bool]$MonitorClutch.IsPresent
    $State.monitor_gas = [int][bool]$MonitorGas.IsPresent
    $State.gas_deadzone_in = $GasDeadzoneIn
    $State.gas_deadzone_out = $GasDeadzoneOut
    $State.gas_window = $GasWindow
    $State.gas_cooldown = $GasCooldown
    $State.gas_timeout = $GasTimeout
    $State.gas_min_usage_percent = $GasMinUsage
    $State.axis_normalization_enabled = [int][bool]$AxisNormalization
    $State.tts_enabled = [int][bool]$Tts.IsPresent
    $State.joy_ID = $JoystickID
    $State.joy_Flags = [uint32]$JoyFlags
    $State.axisMax = [uint32]$AxisMax
    $State.sleep_Time = $SleepTime
    $State.estimate_gas_deadzone_enabled = [int][bool]$EstimateGasDeadzone.IsPresent
    $State.auto_gas_deadzone_enabled = [int][bool]$AutoGasAdjustEnabled
    $State.auto_gas_deadzone_minimum = $AutoGasDeadzoneMin
    $State.clutch_repeat_required = $ClutchRepeat
    # Runtime Logic Variables
    $GasIdleMax = [uint32]($AxisMax * $GasDeadzoneIn / 100)
    $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
    $AxisMargin = [uint32]($AxisMax * $Margin / 100)

    $LastFullThrottleTime = [Environment]::TickCount
    $LastGasActivityTime = [Environment]::TickCount
    $LastGasAlertTime = 0
    $LastEstimatePrintTime = 0
    $EstimateWindowStartTime = [Environment]::TickCount
    $BestEstimatePercent = 100
    $EstimateWindowPeakPercent = 0
    $PeakGasInWindow = 0
    $LastClutchValue = 0
    $RepeatingClutchCount = 0
    $IsRacing = $false
    $LoopCount = 0
    $TelemetrySeq = 0
    $PreviousLoopTimeMs = 0 # For calculation logic

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $TtsWatch = [System.Diagnostics.Stopwatch]::New()

    # --- STARTUP SUMMARY (Mirrors C output) ---
    if ($Verbose) {
        Write-Host ("Monitoring ID=[{0}]" -f $JoystickID) -ForegroundColor Cyan
        Write-Host ("Axis Max: [{0}]" -f $AxisMax) -ForegroundColor Cyan
        Write-Host ("Axis normalization: {0}" -f $(if ($AxisNormalization) { "enabled" } else { "disabled" })) -ForegroundColor Cyan
        if ($MonitorGas) {
            Write-Host ("Gas Config: DZ In:{0}% Out:{1}% Window:{2}s Timeout:{3}s Cooldown:{4}s MinUsage:{5}%" -f $GasDeadzoneIn, $GasDeadzoneOut, $GasWindow, $GasTimeout, $GasCooldown, $GasMinUsage) -ForegroundColor Cyan
            if ($EstimateGasDeadzone) { Write-Host "Gas Estimation: enabled." -ForegroundColor Cyan }
            if ($AutoGasAdjustEnabled) { Write-Host ("Gas Auto-Adjust: enabled (minimum={0})." -f $AutoGasDeadzoneMin) -ForegroundColor Cyan }
        }
        { Write-Host ("JoyFlags: {0} (0x{1})" -f $JoyFlags, ('{0:X}' -f $JoyFlags)) -ForegroundColor Cyan }		
    }

    if (-not $NoConsoleBanner) { Write-Host $Strings.Banner -ForegroundColor Green }

    # -----------------------------------------------------------------------------
    # SECTION 7: MAIN LOOP
    # -----------------------------------------------------------------------------
    while ($Iterations -eq 0 -or $LoopCount -lt $Iterations) {
        $LoopStart = $Stopwatch.Elapsed.TotalMilliseconds
        
        # TIMING: Capture start tick
        $TickStart = [uint32][Environment]::TickCount
        $State.producer_loop_start_ms = $TickStart
        
        # TIMING: Populate fullLoopTime with the PREVIOUS iteration's duration (Lagged)
        $State.fullLoopTime_ms = [uint32]$PreviousLoopTimeMs
        
        $LoopCount++
        $State.iLoop = $LoopCount
        # Snapshot all 6 axes then select which ones represent each pedal.
        $x = 0; $y = 0; $z = 0; $r = 0; $u = 0; $v = 0
        $res = [Fanatec.Hardware]::GetPosition([uint32]$JoystickID, [uint32]$JoyFlags, [ref]$x, [ref]$y, [ref]$z, [ref]$r, [ref]$u, [ref]$v)

        $rawGas    = [uint32](Get-AxisValue -Axis $GAS_AXIS    -X $x -Y $y -Z $z -R $r -U $u -V $v)
        $rawClutch = [uint32](Get-AxisValue -Axis $CLUTCH_AXIS -X $x -Y $y -Z $z -R $r -U $u -V $v)
        $rawBrake  = [uint32](Get-AxisValue -Axis $BRAKE_AXIS  -X $x -Y $y -Z $z -R $r -U $u -V $v)
        # --- Handle Disconnect ---
        if ($res -ne 0) {
            if ($State.controller_disconnected -eq 0) {
                 if ($Verbose) { Write-Host "Error Reading Joystick ($res). Disconnected." -ForegroundColor Red }
                 if ($Tts) { $Synth.SpeakAsync($Strings.Disconnected) | Out-Null }
                 $State.controller_disconnected = 1
                 $State.last_disconnect_time_ms = [uint32][Environment]::TickCount
            }
            
            # Reconnection Search
            if ($TargetVid -ne 0) {
                if ($Verbose) { Write-Host ($Strings.ScanFailed -f 60) -ForegroundColor Red }
                Start-Sleep -Seconds 60
                $newId = Find-FanatecDevice $TargetVid $TargetPid
                if ($newId -ne -1) {
                    $JoystickID = $newId
                    $State.joy_ID = $newId
                    $State.controller_disconnected = 0
                    $State.controller_reconnected = 1
                    if ($Tts) { $Synth.SpeakAsync($Strings.Connected) | Out-Null }
                }
            } else {
                # If no VID provided, just wait and retry same ID
                Start-Sleep -Milliseconds 1000
            }
            continue
        }
        
        # --- Normalization ---
        $State.currentTime = [uint32][Environment]::TickCount
        $State.rawGas = $rawGas
        $State.rawClutch = $rawClutch
        $State.rawBrake = $rawBrake
        
        if ($AxisNormalization) {
            $State.gasValue = $AxisMax - $rawGas
            $State.clutchValue = $AxisMax - $rawClutch
            $State.brakeValue = $AxisMax - $rawBrake
        } else {
            $State.gasValue = $rawGas
            $State.clutchValue = $rawClutch
            $State.brakeValue = $rawBrake
        }

        # --- PER FRAME VERBOSE OUTPUT (MATCHES C) ---
        if ($Verbose) {
             if ($DebugRaw) {
                 Write-Host ("{0}, gas_raw={1} gas_norm={2}, clutch_raw={3} clutch_norm={4} brake_raw={5} brake_norm={6}" -f $State.currentTime, $rawGas, $State.gasValue, $rawClutch, $State.clutchValue, $rawBrake, $State.brakeValue)
             } else {
                 Write-Host ("{0}, gas={1}, clutch={2}, brake={3}" -f $State.currentTime, $State.gasValue, $State.clutchValue, $State.brakeValue)
             }
        }
        
        # --- Percentages ---
        $State.gas_physical_pct = [uint32](100 * $State.gasValue / $AxisMax)
        $State.clutch_physical_pct = [uint32](100 * $State.clutchValue / $AxisMax)
        $State.brake_physical_pct = [uint32](100 * $State.brakeValue / $AxisMax)
        
        # Logical Pct Calc (What the GAME will report if deadzones are equally configured)
        if ($State.gasValue -le $GasIdleMax) { $State.gas_logical_pct = 0 }
        elseif ($State.gasValue -ge $GasFullMin) { $State.gas_logical_pct = 100 }
        else { $State.gas_logical_pct = [uint32](100 * ($State.gasValue - $GasIdleMax) / ($GasFullMin - $GasIdleMax)) }
        
        if ($State.clutchValue -le $GasIdleMax) { $State.clutch_logical_pct = 0 }
        elseif ($State.clutchValue -ge $GasFullMin) { $State.clutch_logical_pct = 100 }
        else { $State.clutch_logical_pct = [uint32](100 * ($State.clutchValue - $GasIdleMax) / ($GasFullMin - $GasIdleMax)) }

        if ($State.brakeValue -le $GasIdleMax) { $State.brake_logical_pct = 0 }
        elseif ($State.brakeValue -ge $GasFullMin) { $State.brake_logical_pct = 100 }
        else { $State.brake_logical_pct = [uint32](100 * ($State.brakeValue - $GasIdleMax) / ($GasFullMin - $GasIdleMax)) }


        # Reset One-Shots
        $State.gas_alert_triggered = 0
        $State.clutch_alert_triggered = 0
        $State.gas_estimate_decreased = 0
        $State.gas_auto_adjust_applied = 0
        $State.controller_reconnected = 0
        
        # --- Clutch Logic ---
        if ($MonitorClutch) {
            if ($State.gasValue -le $GasIdleMax -and $State.clutchValue -gt 0) {
                $diff = [Math]::Abs($State.clutchValue - $LastClutchValue)
                $State.closure = $diff
                if ($diff -le $AxisMargin) {
                    $RepeatingClutchCount++
                } else {
                    $RepeatingClutchCount = 0
                }
            } else {
                $RepeatingClutchCount = 0
            }
            $LastClutchValue = $State.clutchValue
            
            if ($RepeatingClutchCount -ge $ClutchRepeat) {
                $State.clutch_alert_triggered = 1
                if ($Verbose) { Write-Host "Rudder Alert" -ForegroundColor Yellow }
                if ($Tts) { 
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
            # Activity Check
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
            } elseif ($IsRacing -and ($State.currentTime - $LastGasActivityTime) -gt ($GasTimeout * 1000)) {
                if ($Verbose) { Write-Host ("Gas: Auto-Pause (Idle for {0} s)." -f $GasTimeout) -ForegroundColor Cyan }
                $IsRacing = $false
            }
            
            if ($IsRacing) {
                if ($State.gasValue -gt $PeakGasInWindow) { $PeakGasInWindow = $State.gasValue }
                
                # Full Throttle Check
                if ($State.gasValue -ge $GasFullMin) {
                    $LastFullThrottleTime = $State.currentTime
                    $PeakGasInWindow = 0
                } elseif (($State.currentTime - $LastFullThrottleTime) -gt ($GasWindow * 1000)) {
                    if (($State.currentTime - $LastGasAlertTime) -gt ($GasCooldown * 1000)) {
                        $pctReached = [uint32]($PeakGasInWindow * 100 / $AxisMax)
                        $State.percentReached = $pctReached
                        
                        if ($pctReached -gt $GasMinUsage) {
                            $State.gas_alert_triggered = 1
                            $msg = $Strings.AlertGasDrift -f $pctReached
                            if ($Verbose) { Write-Host $msg -ForegroundColor Yellow }
                            if ($Tts) { 
                                $TtsWatch.Restart()
                                $Synth.SpeakAsync($msg) | Out-Null 
                                $TtsWatch.Stop()
                                [Fanatec.Shared]::LastTtsTimeMs = $TtsWatch.Elapsed.TotalMilliseconds
                            }
                            $LastGasAlertTime = $State.currentTime
                        }
                    }
                }
                
                # Estimator
                if ($EstimateGasDeadzone) {
                    if ($State.gasValue -gt $GasIdleMax) {
                        $currPct = [uint32]($State.gasValue * 100 / $AxisMax)
                        if ($currPct -gt $EstimateWindowPeakPercent) { $EstimateWindowPeakPercent = $currPct }
                    }
                    
                    if (($State.currentTime - $EstimateWindowStartTime) -ge ($GasCooldown * 1000)) {
                        if ($EstimateWindowPeakPercent -ge $GasMinUsage) {
                            if ($EstimateWindowPeakPercent -lt $BestEstimatePercent) {
                                $BestEstimatePercent = $EstimateWindowPeakPercent
                                $State.best_estimate_percent = $BestEstimatePercent
                                
                                # Notify
                                if (($State.currentTime - $LastEstimatePrintTime) -ge ($GasCooldown * 1000)) {
                                     $msg = $Strings.AlertNewEstimate -f $BestEstimatePercent
                                     if ($Verbose) { Write-Host $msg -ForegroundColor Cyan }
                                     if ($Tts) { $Synth.SpeakAsync($msg) | Out-Null }
                                     $State.gas_estimate_decreased = 1
                                     $LastEstimatePrintTime = $State.currentTime
                                }
                                
                                # Auto Adjust
                                if ($AutoGasAdjustEnabled -and $BestEstimatePercent -lt $GasDeadzoneOut -and $BestEstimatePercent -ge $AutoGasDeadzoneMin) {
                                    $GasDeadzoneOut = $BestEstimatePercent
                                    $State.gas_deadzone_out = $GasDeadzoneOut
                                    $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
                                    
                                    $msg = $Strings.AlertAutoAdjust -f $GasDeadzoneOut
                                    if ($Verbose) { Write-Host $msg -ForegroundColor Cyan }
                                    if ($Tts) { $Synth.SpeakAsync($msg) | Out-Null }
                                    $State.gas_auto_adjust_applied = 1
                                }
                            }
                        }
                        $EstimateWindowStartTime = $State.currentTime
                        $EstimateWindowPeakPercent = 0
                    }
                }
            }
        }
        
        # --- Telemetry Publish ---
        $TelemetrySeq++
        $State.telemetry_sequence = $TelemetrySeq
        $State.receivedAtUnixMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        $State.metricHttpProcessMs = [Fanatec.Shared]::LastHttpTimeMs
        $State.metricTtsSpeakMs = [Fanatec.Shared]::LastTtsTimeMs
        $State.metricLoopProcessMs = $Stopwatch.Elapsed.TotalMilliseconds - $LoopStart
        
        # TIMING: Set notify timestamp
        $State.producer_notify_ms = [uint32][Environment]::TickCount
        
        $Clone = $State.Clone()
        [Fanatec.Shared]::TelemetryQueue.Enqueue($Clone)


        # --- FIX: Calculate Duration BEFORE Sleep (Execution Time Only) ---
        # Important: Calculate loop duration for the *current* iteration. This value will be available in the Telemetry state during the *next* Enqueue().
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

    if ($Synth) { $Synth.Dispose() }
    
    # --- CLEAN SHUTDOWN ---
    # 1. Signal background thread loop to stop
    [Fanatec.Shared]::StopSignal = $true
    
    # 2. Force kill the background runspace
#    if ($HttpInstance) {
#        $HttpInstance.Stop()
#        $HttpInstance.Dispose()
#    }

	$HttpInstance = $null

    # Force Garbage Collection (The "Nuclear" Cleanup)
    # This forces .NET to reclaim the memory NOW, rather than waiting.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    
    Write-Host "Finalized." -ForegroundColor Yellow
}