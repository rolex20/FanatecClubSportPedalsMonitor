<#
.SYNOPSIS
    FanatecPedals.ps1 v2.6.6
    The Unified Fanatec Pedals Monitor and Telemetry Bridge.
    
.DESCRIPTION
    Monitors Fanatec Pedals for clutch noise and gas drift.
    Provides Async TTS alerts and an HTTP JSON Telemetry server.
    
    Version History:
	2.6.6 - Added sampleAtUnixMs
	2.6.5 - Moved to SSE HTTP
    2.6.4 - Added support for config .ini files, brake and clutch deadzones
	2.6.3 - Added physical percents, removed interlocked batchId, other minor fixes

    2.6.2 - Patch for missing telemetry
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
    [Alias("brake-deadzone-in")][int]$BrakeDeadzoneIn = 5,   # % Idle (brake)
    [Alias("brake-deadzone-out")][int]$BrakeDeadzoneOut = 93,    # % Full Brake
    [Alias("clutch-deadzone-in")][int]$ClutchDeadzoneIn = 5, # % Idle (clutch)
    [Alias("clutch-deadzone-out")][int]$ClutchDeadzoneOut = 93,  # % Full Clutch
    [Alias("gas-window")][int]$GasWindow = 30,               # Time window to check for full throttle (sec)
    [Alias("gas-cooldown")][int]$GasCooldown = 60,           # Time between alerts (sec)
    [Alias("gas-timeout")][int]$GasTimeout = 10,             # Time before assuming "Pause/Menu" (sec)
    [Alias("gas-min-usage")][int]$GasMinUsage = 20,          # Min usage to trigger drift logic (%)
    
    # --- AUTO-ADJUST SETTINGS ---
    [Alias("estimate-gas-deadzone-out")][switch]$EstimateGasDeadzone,
    [Alias("adjust-deadzone-out-with-minimum")][int]$AutoGasDeadzoneMin = -1, # -1 = Disabled

    # --- DEVICE SELECTION ---
    [Alias("j")][int]$JoystickID = 17,        # Default 17 forces auto-detect search
    [Alias("v")][string]$VendorId,            # Hex String (queted string e.g. "0EB7")
    [Alias("p")][string]$ProductId,           # Hex String (quoted string e.g. "1839")
    [string]$ConfigFile,

    # --- FEATURE FLAGS ---
    [switch]$MonitorClutch,
    [switch]$MonitorGas,
    [switch]$Telemetry = $true,  # Default True for this script
    [switch]$Tts = $true,        # Default True
    [switch]$NoTts,              # Disables TTS
    [switch]$NoConsoleBanner,
    [switch]$DebugRaw,
    [Alias("i")][int]$Iterations = 0,  # 0 = Infinite loop
	[Alias("f","flags")][int]$JoyFlags = 255,   # default JOY_RETURNALL	

# --- PERFORMANCE & PRIORITY (main.c parity) ---
    [Alias("d")][switch]$Idle,                  # main.c: --idle
    [Alias("b")][switch]$BelowNormal,           # main.c: --belownormal
    [Alias("a")][string]$AffinityMask,           # main.c: --affinitymask N (decimal mask)
    
    # --- HELP ---
    [switch]$Help
)

# -----------------------------------------------------------------------------
# SECTION 0: CONFIGURATION FILE SUPPORT
# -----------------------------------------------------------------------------
$ConfigKeysApplied = [System.Collections.Generic.HashSet[string]]::new()

function ConvertTo-BooleanValue {
    param([object]$Value)
    if ($Value -is [string]) {
        $normalized = $Value.Trim().ToLower()
        return @('1', 'true', 'yes', 'y', 'on') -contains $normalized
    }
    return [bool]$Value
}

function Import-IniFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $result = @{}
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith(';')) { continue }
        if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) { continue }

        $pair = $trimmed.Split('=', 2)
        if ($pair.Count -lt 2) { continue }

        $key = $pair[0].Trim()
        $value = $pair[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $result[$key] = $value
        }
    }

    return $result
}

function Set-ConfigValue {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Type
    )

    if ($PSBoundParameters.ContainsKey($Name)) { return }

    switch ($Type) {
        'bool'   { $converted = ConvertTo-BooleanValue $Value }
        'string' { $converted = [string]$Value }
        default  { $converted = [int]$Value }
    }

    Set-Variable -Name $Name -Scope Script -Value $converted
    [void]$ConfigKeysApplied.Add($Name)
    Write-Verbose "Config: $Name set to $converted"
}

function Apply-ConfigFile {
    param([string]$Path)

    $config = Import-IniFile -Path $Path
    $mapping = @{
        'sleeptime'           = @{ Type = 'int';    Name = 'SleepTime' }
        'margin'              = @{ Type = 'int';    Name = 'Margin' }
        'clutchrepeat'        = @{ Type = 'int';    Name = 'ClutchRepeat' }
        'noaxisnormalization' = @{ Type = 'bool';   Name = 'NoAxisNormalization' }
        'gasdeadzonein'       = @{ Type = 'int';    Name = 'GasDeadzoneIn' }
        'gasdeadzoneout'      = @{ Type = 'int';    Name = 'GasDeadzoneOut' }
        'brakedeadzonein'     = @{ Type = 'int';    Name = 'BrakeDeadzoneIn' }
        'brakedeadzoneout'    = @{ Type = 'int';    Name = 'BrakeDeadzoneOut' }
        'clutchdeadzonein'    = @{ Type = 'int';    Name = 'ClutchDeadzoneIn' }
        'clutchdeadzoneout'   = @{ Type = 'int';    Name = 'ClutchDeadzoneOut' }
        'gaswindow'           = @{ Type = 'int';    Name = 'GasWindow' }
        'gascooldown'         = @{ Type = 'int';    Name = 'GasCooldown' }
        'gastimeout'          = @{ Type = 'int';    Name = 'GasTimeout' }
        'gasminusage'         = @{ Type = 'int';    Name = 'GasMinUsage' }
        'estimategasdeadzone' = @{ Type = 'bool';   Name = 'EstimateGasDeadzone' }
        'autogasdeadzonemin'  = @{ Type = 'int';    Name = 'AutoGasDeadzoneMin' }
        'joystickid'          = @{ Type = 'int';    Name = 'JoystickID' }
        'vendorid'            = @{ Type = 'string'; Name = 'VendorId' }
        'productid'           = @{ Type = 'string'; Name = 'ProductId' }
        'monitorclutch'       = @{ Type = 'bool';   Name = 'MonitorClutch' }
        'monitorgas'          = @{ Type = 'bool';   Name = 'MonitorGas' }
        'telemetry'           = @{ Type = 'bool';   Name = 'Telemetry' }
        'tts'                 = @{ Type = 'bool';   Name = 'Tts' }
        'notts'               = @{ Type = 'bool';   Name = 'NoTts' }
        'noconsolebanner'     = @{ Type = 'bool';   Name = 'NoConsoleBanner' }
        'debugraw'            = @{ Type = 'bool';   Name = 'DebugRaw' }
        'iterations'          = @{ Type = 'int';    Name = 'Iterations' }
        'joyflags'            = @{ Type = 'int';    Name = 'JoyFlags' }
        'idle'                = @{ Type = 'bool';   Name = 'Idle' }
        'belownormal'         = @{ Type = 'bool';   Name = 'BelowNormal' }
        'affinitymask'        = @{ Type = 'string'; Name = 'AffinityMask' }
        'verbose'             = @{ Type = 'bool';   Name = 'Verbose' }
    }

    foreach ($entry in $config.GetEnumerator()) {
        $key = $entry.Key
        $value = $entry.Value
        $normalizedKey = $key.Trim().ToLower()

        if ($mapping.ContainsKey($normalizedKey)) {
            $target = $mapping[$normalizedKey]
            $type = $target.Type
            $name = $target.Name

            if ($name -eq 'Verbose' -and -not $PSBoundParameters.ContainsKey('Verbose')) {
                if (ConvertTo-BooleanValue $value) { $Script:VerbosePreference = 'Continue' }
                continue
            }

            Set-ConfigValue -Name $name -Value $value -Type $type
        } else {
            Write-Verbose "Config: Ignoring unknown key '$key'"
        }
    }
}

# -----------------------------------------------------------------------------
# SECTION 1: AUTO-HELP LOGIC
# -----------------------------------------------------------------------------
$ShowHelp = $Help.IsPresent -or ($PSBoundParameters.Count -eq 0)

if ($ShowHelp) {
    Write-Host @"
Usage: .\FanatecPedals.ps1 [options]

   Auto-Reconnect:
       -VendorId "HEX"     Vendor ID (e.g. "0EB7") for auto-reconnection.
       -ProductId "HEX"    Product ID (e.g. "1839") for auto-reconnection.

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
       -ConfigFile PATH    Load options from an .ini file. Command line arguments override file values.
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

   Brake/Clutch Deadzones:
       -BrakeDeadzoneIn N  % Idle Deadzone for brake (0-100). Default matches -GasDeadzoneIn unless set.
       -BrakeDeadzoneOut N % Full-travel threshold for brake (0-100). Default matches -GasDeadzoneOut unless set.
       -ClutchDeadzoneIn N % Idle Deadzone for clutch (0-100). Default matches -GasDeadzoneIn unless set.
       -ClutchDeadzoneOut N % Full-travel threshold for clutch (0-100). Default matches -GasDeadzoneOut unless set.

   Performance & Priority:
       -Idle              Set process priority to IDLE.
       -BelowNormal       Set process priority to BELOW_NORMAL.
       -AffinityMask N    Decimal CPU affinity bitmask (bit0=CPU0, bit1=CPU1, ...).
                          Examples: 1=CPU0, 2=CPU1, 3=CPU0+CPU1, 4=CPU2

"@
    exit
}

# Apply configuration file (command line args still override)
if ($ConfigFile) {
    Apply-ConfigFile -Path $ConfigFile
}

# Align brake/clutch defaults to gas deadzones unless explicitly provided (preserves legacy behavior)
$hasBrakeInConfig = $ConfigKeysApplied.Contains('BrakeDeadzoneIn')
$hasBrakeOutConfig = $ConfigKeysApplied.Contains('BrakeDeadzoneOut')
$hasClutchInConfig = $ConfigKeysApplied.Contains('ClutchDeadzoneIn')
$hasClutchOutConfig = $ConfigKeysApplied.Contains('ClutchDeadzoneOut')

if ((-not $PSBoundParameters.ContainsKey('BrakeDeadzoneIn')) -and -not $hasBrakeInConfig) { $BrakeDeadzoneIn = $GasDeadzoneIn }
if ((-not $PSBoundParameters.ContainsKey('BrakeDeadzoneOut')) -and -not $hasBrakeOutConfig) { $BrakeDeadzoneOut = $GasDeadzoneOut }
if ((-not $PSBoundParameters.ContainsKey('ClutchDeadzoneIn')) -and -not $hasClutchInConfig) { $ClutchDeadzoneIn = $GasDeadzoneIn }
if ((-not $PSBoundParameters.ContainsKey('ClutchDeadzoneOut')) -and -not $hasClutchOutConfig) { $ClutchDeadzoneOut = $GasDeadzoneOut }

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
    AutoPause        = "Gas: Auto-Pause (Idle for {0} s)."
    ResumingActivity = "Gas: Activity Resumed."
	Duplicate        = "Error.  Another instance of Fanatec Monitor is already running."
}

# -----------------------------------------------------------------------------
# SECTION 3: LOGIC SETUP
# -----------------------------------------------------------------------------


# AXIS SELECTION (EDIT THESE AFTER RUNNING Discover-UsbControllerAxes.ps1)
# -----------------------------------------------------------------------------
# WinMM reports up to 6 joystick axes via JOYINFOEX: X, Y, Z, R, U, V.
# Use Discover-UsbControllerAxes.ps1 to see which axis moves when you press each pedal.

# Known Fanatec Pedals Axis
# $GAS_AXIS    = 'Y'
# $CLUTCH_AXIS = 'R'
# $BRAKE_AXIS  = 'X' # NEW: set this to the axis that moves when you press the brake pedal.

# WinMM joyGetPosEx dwFlags (matches main.c --flags). Default is JOY_RETURNALL (255).
# If you enable JOY_RETURNRAWDATA (256), Fanatec pedals often report 0..1023 instead of 0..65535.
$JOY_DWFLAGS = 255

# Other common values for dwFlags 
# flags = 266 = JOY_RETURNRAWDATA(Fanatec raw: 0–1023) | JOY_RETURNR | JOY_RETURNY
# flags = 267 = JOY_RETURNRAWDATA(Fanatec raw: 0–1023) | JOY_RETURNR | JOY_RETURNY | JOY_RETURNX
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
using System.Threading;

namespace Fanatec {

    [Serializable]
    public class PedalMonState {
                public long sampleAtUnixMs;    // wall-clock ms since epoch at device sample time
                public long enqueueAtUnixMs;   // wall-clock ms captured at enqueue (producer -> queue)
                public long sendAtUnixMs;      // wall-clock ms captured at SSE write time

        // Config & Flags
        public int verbose_flag;
        public int monitor_clutch;
        public int monitor_gas;
        public int gas_deadzone_in;
        public int gas_deadzone_out;
        public int brake_deadzone_in;
        public int brake_deadzone_out;
        public int clutch_deadzone_in;
        public int clutch_deadzone_out;
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
        public uint brakeIdleMax;
        public uint brakeFullMin;
        public uint clutchIdleMax;
        public uint clutchFullMin;
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

		// --- NEW PERFORMANCE METHOD (INLINED) ---
        public void UpdatePercentages() {
            // 1. Physical Percentages (Raw value vs Axis Max)
            if (axisMax > 0) {
                gas_physical_pct    = (uint)(100u * gasValue / axisMax);
                clutch_physical_pct = (uint)(100u * clutchValue / axisMax);
                brake_physical_pct  = (uint)(100u * brakeValue / axisMax);
            } else {
                gas_physical_pct = 0; 
				clutch_physical_pct = 0; 
				brake_physical_pct = 0;
            }

            // 2. Logical Percentages (Calculated vs Deadzones)
            // Optimization: Calculate the denominator once per frame.
            // If config is broken (Min >= Max), range is 0 to prevent divide-by-zero errors.
            // Each pedal uses its own idle/full pair so they can be tuned independently.
            uint gasRange = (gasFullMin > gasIdleMax) ? (gasFullMin - gasIdleMax) : 0;
            uint clutchRange = (clutchFullMin > clutchIdleMax) ? (clutchFullMin - clutchIdleMax) : 0;
            uint brakeRange = (brakeFullMin > brakeIdleMax) ? (brakeFullMin - brakeIdleMax) : 0;

            // --- GAS ---
            if (gasRange == 0 || gasValue <= gasIdleMax) {
                gas_logical_pct = 0;
            } else if (gasValue >= gasFullMin) {
                gas_logical_pct = 100;
            } else {
                // Inline math: (100 * (Value - Idle)) / Range
                gas_logical_pct = (uint)(100 * (gasValue - gasIdleMax) / gasRange);
            }

            // --- CLUTCH ---
            if (clutchRange == 0 || clutchValue <= clutchIdleMax) {
                clutch_logical_pct = 0;
            } else if (clutchValue >= clutchFullMin) {
                clutch_logical_pct = 100;
            } else {
                clutch_logical_pct = (uint)(100 * (clutchValue - clutchIdleMax) / clutchRange);
            }

            // --- BRAKE ---
            if (brakeRange == 0 || brakeValue <= brakeIdleMax) {
                brake_logical_pct = 0;
            } else if (brakeValue >= brakeFullMin) {
                brake_logical_pct = 100;
            } else {
                brake_logical_pct = (uint)(100 * (brakeValue - brakeIdleMax) / brakeRange);
            }
        }
    }

    public static class Shared {
        // Clean shutdown signal used by the background HTTP/SSE server
        public static volatile bool StopSignal = false;

        // Performance metrics written by the background server (read by producer loop)
        public static double LastHttpTimeMs = 0;
        public static double LastTtsTimeMs  = 0;

        // -------------------------------------------------------------------------
        // Telemetry buffer:
        // 1) Bounded backlog (capacity = 1024)
        // 2) Latest-wins policy by dropping oldest when full
        // 3) Producer guarantee: never blocks (TryAdd + drop-oldest)
        // -------------------------------------------------------------------------
        public const int TelemetryBufferCapacity = 1024;

        // Underlying ConcurrentQueue keeps TryAdd/TryTake efficient.
        public static readonly BlockingCollection<PedalMonState> TelemetryQueue =
            new BlockingCollection<PedalMonState>(
                new ConcurrentQueue<PedalMonState>(),
                TelemetryBufferCapacity
            );

        public static long DroppedTelemetryFrames = 0;

        /// <summary>
        /// Non-blocking enqueue with latest-wins behavior:
        /// - TryAdd fast-path
        /// - If full: drop-oldest (TryTake) until TryAdd succeeds
        /// - Never blocks the producer loop
        /// </summary>
        public static void EnqueueTelemetryNonBlocking(PedalMonState frame) {
            if (TelemetryQueue.IsAddingCompleted) return;

            // Fast path: room available.
            if (TelemetryQueue.TryAdd(frame)) return;

            // Full: drop oldest until we can add (still non-blocking).
            PedalMonState dropped;
            while (!TelemetryQueue.TryAdd(frame)) {
                if (TelemetryQueue.TryTake(out dropped)) {
                    Interlocked.Increment(ref DroppedTelemetryFrames);
                    if (TelemetryQueue.IsAddingCompleted) return;
                    continue;
                }

                // Nothing to drop (should be rare). Bail to avoid spinning.
                return;
            }
        }
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

        public static bool CheckDevice(uint id, int vendorId, int productId) {
            JOYCAPS caps = new JOYCAPS();
            if (joyGetDevCaps(id, out caps, (uint)Marshal.SizeOf(caps)) == JOYERR_NOERROR) {
                return (caps.wMid == vendorId && caps.wPid == productId);
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
	# Create the CompilerParameters object explicitly
    $Params = New-Object System.CodeDom.Compiler.CompilerParameters
    
    # Set the optimization flag here
    $Params.CompilerOptions = "/optimize"

	# PowerShell 5.1 + Add-Type -CompilerParameters does NOT reliably auto-reference
	# the same framework assemblies as the simple Add-Type path.
	# BlockingCollection<T> (and some concurrent primitives) require System.dll / System.Core.dll.
	$runtimeDir = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
	foreach ($dll in @("System.dll", "System.Core.dll")) {
	    $path = Join-Path $runtimeDir $dll
	    if (Test-Path $path) {
	        [void]$Params.ReferencedAssemblies.Add($path)
	    }
	}
	# Optional but recommended for a "release-like" compile (still JITs at runtime):
	$Params.GenerateInMemory = $true
	$Params.IncludeDebugInformation = $false	

    # Pass the OBJECT to the -CompilerParameters argument
    Add-Type -TypeDefinition $Source -CompilerParameters $Params	
#    Add-Type -TypeDefinition $Source -Language CSharp -CompilerOptions "/optimize"
} else {
    Write-Warning "Using existing C# definition. If you modified the C# code, please restart PowerShell."
}



# -----------------------------------------------------------------------------
# SECTION 5: HELPER FUNCTIONS

function Set-ThisProcessPriorityAndAffinity {
    param(
        [switch]$Idle,
        [switch]$BelowNormal,
        [string]$AffinityMask
    )

    $p = [System.Diagnostics.Process]::GetCurrentProcess()

    # Priority
    if ($Idle -and $BelowNormal) {
        Write-Warning "Both -Idle and -BelowNormal were specified; using -Idle."
        $BelowNormal = $false
    }

    try {
        if ($Idle)       { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle }
        elseif ($BelowNormal) { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    } catch {
        Write-Warning "Failed to set process priority: $($_.Exception.Message)"
    }

    # Affinity mask (accept decimal like main.c; also accepts 0x.. if provided)
    if ($AffinityMask) {
        try {
            $maskStr = $AffinityMask.Trim()
            $mask =
                if ($maskStr -match '^0x[0-9a-fA-F]+$') { [UInt64]::Parse($maskStr.Substring(2), [System.Globalization.NumberStyles]::HexNumber) }
                else { [UInt64]$maskStr }

            if ($mask -eq 0) { throw "AffinityMask cannot be 0." }

            # ProcessorAffinity is IntPtr; keep it in-range
            if ([IntPtr]::Size -eq 4 -and $mask -gt [UInt32]::MaxValue) {
                throw "AffinityMask too large for 32-bit PowerShell."
            }

            $p.ProcessorAffinity = [IntPtr]([Int64]$mask)
        } catch {
            Write-Warning "Failed to set affinity mask '$AffinityMask': $($_.Exception.Message)"
        }
    }

    Write-Verbose ("Proc Priority={0}, Affinity=0x{1:X}" -f $p.PriorityClass, $p.ProcessorAffinity.ToInt64())
}


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

function Compute-LogicalPct {
    param(
        [uint32]$Value,
        [uint32]$IdleMax,
        [uint32]$FullMin
    )

    if ($Value -le $IdleMax) { return [uint32]0 }
    if ($Value -ge $FullMin) { return [uint32]100 }
    if ($FullMin -le $IdleMax) { return [uint32]0 }  # guard matches main.c ComputeLogicalPct()

    return [uint32](100 * ($Value - $IdleMax) / ($FullMin - $IdleMax))
}

# -----------------------------------------------------------------------------

function Publish-TelemetryFrame {
    param(
        [Fanatec.PedalMonState]$State,
        [ref]$TelemetrySeq,
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [double]$LoopStartMs
    )

    if ($Telemetry) { 

        $TelemetrySeq.Value++
        $State.telemetry_sequence = [uint32]$TelemetrySeq.Value

        $State.receivedAtUnixMs       = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        $State.enqueueAtUnixMs        = $State.receivedAtUnixMs
        $State.metricHttpProcessMs    = [Fanatec.Shared]::LastHttpTimeMs
        $State.metricTtsSpeakMs       = [Fanatec.Shared]::LastTtsTimeMs
        $State.metricLoopProcessMs    = $Stopwatch.Elapsed.TotalMilliseconds - $LoopStartMs
        $State.producer_notify_ms     = [uint32][Environment]::TickCount

        # Non-blocking enqueue + bounded backlog + latest-wins (drop-oldest when full)
        [Fanatec.Shared]::EnqueueTelemetryNonBlocking($State.Clone())
    }
}

# -----------------------------------------------------------------------------

function Find-FanatecDevice {
    param([int]$Vid, [int]$Prid)
    $count = [Fanatec.Hardware]::joyGetNumDevs()
    for ($i = 0; $i -lt $count; $i++) {
        if ([Fanatec.Hardware]::CheckDevice($i, $Vid, $Prid)) {
            return $i
        }
    }
    return -1
}

function Create-HttpServerInstance {
    param(
        # Now a BlockingCollection[Fanatec.PedalMonState]
        $Queue
    )

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"
    $rs.ThreadOptions  = "ReuseThread"
    $rs.Open()

    # Inject queue into the server runspace as $Q
    $rs.SessionStateProxy.SetVariable("Q", $Queue)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs

    $ps.AddScript({
        # ---- Configuration ----
        $port = 8181

        # Accept both hostnames to avoid host/prefix mismatches.
        $prefixes = @(
            "http://127.0.0.1:$port/",
            "http://localhost:$port/"
        )

        # Single-dashboard gate:
        # Only ONE /events stream is allowed at a time.
        $streamGate = New-Object System.Threading.SemaphoreSlim(1, 1)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        function Write-JsonResponse {
            param(
                [System.Net.HttpListenerResponse]$Resp,
                [int]$StatusCode,
                [object]$Obj
            )
            try {
                $Resp.StatusCode = $StatusCode
                $Resp.AddHeader("Access-Control-Allow-Origin", "*")
                $Resp.AddHeader("Cache-Control", "no-store")
                $Resp.ContentType = "application/json; charset=utf-8"

                $json  = $Obj | ConvertTo-Json -Compress -Depth 6
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $Resp.ContentLength64 = $bytes.Length
                $Resp.OutputStream.Write($bytes, 0, $bytes.Length)
            } finally {
                $Resp.Close()
            }
        }

        function Send-SseBusyAndClose {
            param([System.Net.HttpListenerContext]$Ctx)

            $resp = $Ctx.Response
            try {
                $resp.StatusCode = 200
                $resp.AddHeader("Access-Control-Allow-Origin", "*")
                $resp.AddHeader("Cache-Control", "no-cache")
                $resp.ContentType = "text/event-stream"
                $resp.SendChunked = $true
                $resp.KeepAlive   = $false

                $writer = New-Object System.IO.StreamWriter($resp.OutputStream, $utf8NoBom)
                $writer.AutoFlush = $true

                $msg = @{
                    error  = "SSE busy"
                    detail = "Only one dashboard connection is allowed. Close the other dashboard tab/window and refresh."
                } | ConvertTo-Json -Compress

                # Custom SSE event the dashboard listens for:
                $writer.Write("event: busy`n")
                $writer.Write("data: $msg`n`n")
            } catch {
                # ignore
            } finally {
                try { if ($writer) { $writer.Dispose() } } catch {}
                $resp.Close()
            }
        }
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 905"
		function Start-SseStreamThread {
			param([System.Net.HttpListenerContext]$Ctx)
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 908"
			# -------------------------------------------------------------------------
			# Refresh-safe cleanup (prevents runspace/PS instance leaks across reconnects)
			# -------------------------------------------------------------------------
			if ($global:PedBridge_ActiveSseWorker) {
				$old = $global:PedBridge_ActiveSseWorker
				$global:PedBridge_ActiveSseWorker = $null

				try { if ($old.EventId) { Unregister-Event -SourceIdentifier $old.EventId -ErrorAction SilentlyContinue } } catch {}
				try { if ($old.EventId) { Remove-Event      -SourceIdentifier $old.EventId -ErrorAction SilentlyContinue } } catch {}
				try { if ($old.Ps)      { $old.Ps.Stop() } } catch {}
				try { if ($old.Ps)      { $old.Ps.Dispose() } } catch {}
				try { if ($old.Rs)      { $old.Rs.Close() } } catch {}
				try { if ($old.Rs)      { $old.Rs.Dispose() } } catch {}
			}

			# Bundle state for the worker runspace (avoid ScriptBlock TLS context issues)
			$state = @{
				Ctx      = $Ctx
				Q        = $Q
				Gate     = $streamGate
				Encoding = $utf8NoBom
			}

			$rs2   = $null
			$ps2   = $null
			$id    = $null
			$srcId = $null

			try {
				$rs2 = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
				$rs2.ApartmentState = "MTA"
				$rs2.ThreadOptions  = "ReuseThread"
				$rs2.Open()

				$ps2 = [PowerShell]::Create()
				$ps2.Runspace = $rs2

				$id    = [guid]::NewGuid().ToString("N")
				$srcId = "PedBridge_SseWorker_$id"

				# Keep references alive (and allow forced cleanup on refresh)
				$global:PedBridge_ActiveSseWorker = @{
					Id      = $id
					EventId = $srcId
					Ps      = $ps2
					Rs      = $rs2
				}

				# Auto-dispose once the async pipeline finishes (extra safety)
				Register-ObjectEvent -InputObject $ps2 -EventName InvocationStateChanged -SourceIdentifier $srcId -MessageData @{
					Id      = $id
					EventId = $srcId
					Ps      = $ps2
					Rs      = $rs2
				} -Action {
					try {
						$doneStates = @(
							[System.Management.Automation.PSInvocationState]::Completed,
							[System.Management.Automation.PSInvocationState]::Failed,
							[System.Management.Automation.PSInvocationState]::Stopped
						)
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 970"
						if ($EventArgs.InvocationStateInfo.State -in $doneStates) {
							$md = $Event.MessageData

							try { Unregister-Event -SourceIdentifier $md.EventId -ErrorAction SilentlyContinue } catch {}
							try { Remove-Event      -SourceIdentifier $md.EventId -ErrorAction SilentlyContinue } catch {}

							# Only clear if we're still the active worker (avoid races)
							if ($global:PedBridge_ActiveSseWorker -and $global:PedBridge_ActiveSseWorker.Id -eq $md.Id) {
								$global:PedBridge_ActiveSseWorker = $null
							}

							try { if ($md.Ps) { $md.Ps.Dispose() } } catch {}
							try { if ($md.Rs) { $md.Rs.Close() } } catch {}
							try { if ($md.Rs) { $md.Rs.Dispose() } } catch {}
						}
					} catch {}
				} | Out-Null

				# The actual SSE pump runs in the child runspace
				$ps2.AddScript({
					param($st)

					$ctx  = $st.Ctx
					$q    = $st.Q
					$gate = $st.Gate
					$enc  = $st.Encoding

					$resp    = $ctx.Response
					$writer  = $null
					$batchId = 0

					try {
						$resp.StatusCode = 200
						$resp.AddHeader("Access-Control-Allow-Origin", "*")
						$resp.AddHeader("Cache-Control", "no-cache")
						$resp.ContentType = "text/event-stream"
						$resp.SendChunked = $true
						$resp.KeepAlive   = $true
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1009"
						$writer = New-Object System.IO.StreamWriter($resp.OutputStream, $enc)
						$writer.AutoFlush = $true

						# Initial drain: send ALL frames currently queued (oldest -> newest)
						$frames = New-Object "System.Collections.Generic.List[object]"
						$tmp = $null
						while ($q.TryTake([ref]$tmp)) {
							[void]$frames.Add($tmp)
						}

                                                if ($frames.Count -gt 0) {
                                                        $batchId++
                                                        $payload = @{
                                                                schemaVersion = 1
                                                                bridgeInfo    = @{
                                                                        batchId           = $batchId
                                                                        servedAtUnixMs    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                                                        pendingFrameCount = $frames.Count
                                                                }
                                                                frames = $frames
                                                        }

                                                        $sendAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                                        foreach ($f in $frames) {
                                                                if (-not $f.enqueueAtUnixMs) { $f.enqueueAtUnixMs = $f.receivedAtUnixMs }
                                                                $f.sendAtUnixMs = $sendAt
                                                        }

                                                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                                                        $json = $payload | ConvertTo-Json -Compress -Depth 6
                                                        $writer.Write("data: $json`n`n")
                                                        $sw.Stop()
                                                        [Fanatec.Shared]::LastHttpTimeMs = $sw.Elapsed.TotalMilliseconds
						}

						# Heartbeat ping (keeps intermediaries from timing out idle streams)
						$pingEveryMs = 15000
						$pingSw = [System.Diagnostics.Stopwatch]::StartNew()

						while (-not [Fanatec.Shared]::StopSignal) {
							$first = $null
							$gotOne = $q.TryTake([ref]$first, 250)

							if ($gotOne) {
								# Drain everything available right now and send it all
								$frames = New-Object "System.Collections.Generic.List[object]"
								[void]$frames.Add($first)

								$next = $null
								while ($q.TryTake([ref]$next)) {
									[void]$frames.Add($next)
								}

                                                                $batchId++
                                                                $payload = @{
                                                                        schemaVersion = 1
                                                                        bridgeInfo    = @{
                                                                                batchId           = $batchId
                                                                                servedAtUnixMs    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                                                                pendingFrameCount = $frames.Count
                                                                        }
                                                                        frames = $frames.ToArray()
                                                                }

                                                                $sendAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                                                foreach ($f in $frames) {
                                                                        if (-not $f.enqueueAtUnixMs) { $f.enqueueAtUnixMs = $f.receivedAtUnixMs }
                                                                        $f.sendAtUnixMs = $sendAt
                                                                }

                                                                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                                                                $json = $payload | ConvertTo-Json -Compress -Depth 6
                                                                $writer.Write("data: $json`n`n")
                                                                $sw.Stop()

								# Expose for producer-side metrics (next frame will pick it up)
								[Fanatec.Shared]::LastHttpTimeMs = $sw.Elapsed.TotalMilliseconds

								$pingSw.Restart()
							}
							else {
								if ($pingSw.ElapsedMilliseconds -ge $pingEveryMs) {
									# SSE comment ping (ignored by client, but keeps the pipe alive)
									$writer.Write(": ping`n`n")
									$pingSw.Restart()
								}
							}
						}
					}
					catch {
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1088"						# Most common cause: client disconnected (broken pipe) — just exit.
					}
					finally {
						try { if ($writer) { $writer.Dispose() } } catch {}
						try { $resp.Close() } catch {}
						try { $gate.Release() | Out-Null } catch {}
					}
				}).AddArgument($state) | Out-Null
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1096"
				$null = $ps2.BeginInvoke()
			}
			catch {
				# If we fail before the worker begins, the worker won't release/close for us.
				try { if ($srcId) { Unregister-Event -SourceIdentifier $srcId -ErrorAction SilentlyContinue } } catch {}
				try { if ($srcId) { Remove-Event      -SourceIdentifier $srcId -ErrorAction SilentlyContinue } } catch {}
				try { if ($ps2)   { $ps2.Dispose() } } catch {}
				try { if ($rs2)   { $rs2.Close() } } catch {}
				try { if ($rs2)   { $rs2.Dispose() } } catch {}
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1106"
				$global:PedBridge_ActiveSseWorker = $null

				try { $Ctx.Response.Close() } catch {}
				try { $streamGate.Release() | Out-Null } catch {}
				return
			}
		}


        $listener = New-Object System.Net.HttpListener
        foreach ($p in $prefixes) { $listener.Prefixes.Add($p) }

        try {
            $listener.Start()
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1121"
            while ($listener.IsListening -and -not [Fanatec.Shared]::StopSignal) {
                $ctx = $null
                try {
                    $ctx = $listener.GetContext()
                } catch {
                    break
                }

                $req  = $ctx.Request
                $resp = $ctx.Response
                $path = $req.Url.AbsolutePath
				

                # Basic CORS/preflight support
                if ($req.HttpMethod -eq "OPTIONS") {
                    $resp.StatusCode = 204
                    $resp.AddHeader("Access-Control-Allow-Origin", "*")
                    $resp.AddHeader("Access-Control-Allow-Methods", "GET, OPTIONS")
                    $resp.AddHeader("Access-Control-Allow-Headers", "*")
                    $resp.Close()
                    continue
                }

                if ($path -eq "/QUIT") {
                    [Fanatec.Shared]::StopSignal = $true
                    Write-JsonResponse -Resp $resp -StatusCode 200 -Obj @{ ok = $true; msg = "Shutting down." }
                    break
                }

                if ($path -eq "/events") {
                    # Enforce single dashboard
										
					if (-not $streamGate.Wait(0)) {

						# Optional takeover: stop old SSE worker to avoid false "busy" on refresh
						if ($global:PedBridge_ActiveSseWorker -and $global:PedBridge_ActiveSseWorker.Ps) {
							try { $global:PedBridge_ActiveSseWorker.Ps.Stop() } catch {}

							# give the worker a moment to hit its finally{} and release the gate
							if ($streamGate.Wait(1000)) {
								Start-SseStreamThread -Ctx $ctx
								continue
							}
						}

						Send-SseBusyAndClose -Ctx $ctx
						continue
					}

Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1171"
					Start-SseStreamThread -Ctx $ctx
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1173"
					continue
										
                }

                # Hard-disable old polling endpoint so you never accidentally use it again
                Write-JsonResponse -Resp $resp -StatusCode 410 -Obj @{
                    error = "Polling disabled"
                    use   = "/events (Server-Sent Events)"
                }
            }
        } catch {
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1185"
		}
        finally {
Write-EventLog -LogName Application -Source "MyScriptSource" -EventId 1001 -EntryType Warning -Message "line 1188"
            try { if ($listener.IsListening) { $listener.Stop() } } catch {}
            try { $listener.Close() } catch {}
            try { $streamGate.Dispose() } catch {}
        }
    }) | Out-Null

    return $ps
}
# PRIORITY AND AFFINITY
Set-ThisProcessPriorityAndAffinity -Idle:$Idle -BelowNormal:$BelowNormal -AffinityMask $AffinityMask


# -----------------------------------------------------------------------------
# SECTION 6: INITIALIZATION
# -----------------------------------------------------------------------------


try {

    # Process Priority
    # $p = Get-Process -Id $PID
    # $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High

    # Setup TTS
    Add-Type -AssemblyName System.speech
    $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $Synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)
	

	$mutexName = "fanatec_monitor_single_instance_mutex"
	$createdNew = $false
	$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew) # arguments: (initiallyOwned, name, out createdNew)
	if (-not $createdNew) {
		$Synth.Speak($Strings.Duplicate) | Out-Null 
		Start-Sleep 1
		Throw $Strings.Duplicate
	}
	

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
            Throw "Device Vendor-Id=$VendorId, ProductId=$ProductId not found at startup."
        }
    }

    # State Variables
    $State = New-Object Fanatec.PedalMonState

    # Joystick dwFlags / axis resolution
	# Now $JoyFlags is read from command-line
    # $JoyFlags = [uint32]$JOY_DWFLAGS

    # WinMM returns 0..65535 by default. If [Fanatec.Hardware]::JOY_RETURNRAWDATA (256) is set, Fanatec pedals often report 0..1023.
    $AxisMax = if (($JoyFlags -band 256) -ne 0) { 1023 } else { 65535 }

    
    # Cast flags safely to int for the C# Struct
    $State.verbose_flag = [int][bool]$Verbose
    $State.monitor_clutch = [int][bool]$MonitorClutch.IsPresent
    $State.monitor_gas = [int][bool]$MonitorGas.IsPresent
    $State.gas_deadzone_in = $GasDeadzoneIn
    $State.gas_deadzone_out = $GasDeadzoneOut
    $State.brake_deadzone_in = $BrakeDeadzoneIn
    $State.brake_deadzone_out = $BrakeDeadzoneOut
    $State.clutch_deadzone_in = $ClutchDeadzoneIn
    $State.clutch_deadzone_out = $ClutchDeadzoneOut
    $State.gas_window = $GasWindow
    $State.gas_cooldown = $GasCooldown
    $State.gas_timeout = $GasTimeout
    $State.gas_min_usage_percent = $GasMinUsage
    $State.axis_normalization_enabled = [int][bool]$AxisNormalization

    #$State.tts_enabled = [int][bool]$Tts.IsPresent
    # main.c semantics: 1 == enabled, 0 == disabled
    $State.tts_enabled = [int][bool]$Tts

    $State.joy_ID = $JoystickID
    $State.joy_Flags = [uint32]$JoyFlags
    $State.axisMax = [uint32]$AxisMax
    $State.sleep_Time = $SleepTime
    $State.estimate_gas_deadzone_enabled = [int][bool]$EstimateGasDeadzone.IsPresent
    $State.auto_gas_deadzone_enabled = [int][bool]$AutoGasAdjustEnabled
    $State.auto_gas_deadzone_minimum = $AutoGasDeadzoneMin
    $State.clutch_repeat_required = $ClutchRepeat

    # --- Legacy fields that must be present (main.c compatible) ---
    $State.debug_raw_mode    = [int][bool]$DebugRaw.IsPresent
    $State.no_console_banner = [int][bool]$NoConsoleBanner.IsPresent
    $State.telemetry_enabled = [int][bool]$Telemetry

    # main.c supports IPC speak paths; PS version uses SpeechSynth directly
    $State.ipc_enabled       = 0

    $State.margin            = [uint32]$Margin
    $State.iterations        = [uint32]$Iterations

    $State.target_vendor_id  = [int]$TargetVid
    $State.target_product_id = [int]$TargetPid


    # Runtime Logic Variables
    $GasIdleMax = [uint32]($AxisMax * $GasDeadzoneIn / 100)
    $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
    $BrakeIdleMax = [uint32]($AxisMax * $BrakeDeadzoneIn / 100)
    $BrakeFullMin = [uint32]($AxisMax * $BrakeDeadzoneOut / 100)
    $ClutchIdleMax = [uint32]($AxisMax * $ClutchDeadzoneIn / 100)
    $ClutchFullMin = [uint32]($AxisMax * $ClutchDeadzoneOut / 100)
    $AxisMargin = [uint32]($AxisMax * $Margin / 100)

    # Precompute ms versions once (main.c does this to keep hot path clean)
    $GasTimeoutMs  = [uint32]($GasTimeout  * 1000)
    $GasWindowMs   = [uint32]($GasWindow   * 1000)
    $GasCooldownMs = [uint32]($GasCooldown * 1000)

    $State.axisMargin     = $AxisMargin
    $State.gasIdleMax      = $GasIdleMax
    $State.gasFullMin      = $GasFullMin
    $State.brakeIdleMax    = $BrakeIdleMax
    $State.brakeFullMin    = $BrakeFullMin
    $State.clutchIdleMax   = $ClutchIdleMax
    $State.clutchFullMin   = $ClutchFullMin
    $State.gas_timeout_ms  = $GasTimeoutMs
    $State.gas_window_ms   = $GasWindowMs
    $State.gas_cooldown_ms = $GasCooldownMs

    $LastFullThrottleTime = [Environment]::TickCount
    $LastGasActivityTime = [Environment]::TickCount
    $LastGasAlertTime = 0
    $LastEstimatePrintTime = 0
    $EstimateWindowStartTime = [Environment]::TickCount
    $BestEstimatePercent = 100
    $LastPrintedEstimate = 100 # <-- MISSING today
    $EstimateWindowPeakPercent = 0
    $PeakGasInWindow = 0
    $LastClutchValue = 0
    $RepeatingClutchCount = 0
    $IsRacing = $false
    $LoopCount = 0
    $TelemetrySeq = 0
    $PreviousLoopTimeMs = 0 # For calculation logic
    $CurrentPercent = 0 # <-- MISSING today

    # Seed telemetry-visible estimator/runtime fields
    $State.best_estimate_percent        = [uint32]$BestEstimatePercent
    $State.last_printed_estimate        = [uint32]$LastPrintedEstimate
    $State.estimate_window_peak_percent = [uint32]$EstimateWindowPeakPercent
    $State.estimate_window_start_time   = [uint32]$EstimateWindowStartTime
    $State.last_estimate_print_time     = [uint32]$LastEstimatePrintTime
    $State.currentPercent               = [uint32]$CurrentPercent

    $State.isRacing             = 0
    $State.peakGasInWindow      = [uint32]$PeakGasInWindow
    $State.lastFullThrottleTime = [uint32]$LastFullThrottleTime
    $State.lastGasActivityTime  = [uint32]$LastGasActivityTime
    $State.lastGasAlertTime     = [uint32]$LastGasAlertTime
    $State.lastClutchValue      = [uint32]$LastClutchValue
    $State.repeatingClutchCount = [int]$RepeatingClutchCount

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
        Write-Host ("JoyFlags: {0} (0x{1})" -f $JoyFlags, ('{0:X}' -f $JoyFlags)) -ForegroundColor Cyan
    }

    if (-not $NoConsoleBanner) { Write-Host $Strings.Banner -ForegroundColor Green }


    # --- HTTP SERVER STARTUP ---
    if ($Telemetry) {
    
	    $TelemetryQueue = [Fanatec.Shared]::TelemetryQueue
	
        # Reset Stop Signal
        [Fanatec.Shared]::StopSignal = $false

        # 1. Create the Instance (Controller)
        $HttpInstance = Create-HttpServerInstance -Queue $TelemetryQueue
    
        # 2. Start it Async (Keep handle to check status if needed)
        $HttpAsyncResult = $HttpInstance.BeginInvoke()

        if ($Verbose) { Write-Host "Telemetry: Queue and HTTP Server initialized." -ForegroundColor Cyan }
    }

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

        # Reset per-frame one-shot flags (matches main.c)
        # NOTE: controller_disconnected is latched and is NOT cleared here.
        $State.gas_alert_triggered     = 0
        $State.clutch_alert_triggered  = 0
        $State.gas_estimate_decreased  = 0
        $State.gas_auto_adjust_applied = 0
        $State.controller_reconnected  = 0
        
        $LoopCount++
        $State.iLoop = $LoopCount
        # Snapshot all 6 axes then select which ones represent each pedal.
        #$x = 0; $y = 0; $z = 0; $r = 0; $u = 0; $v = 0
        

        # Nice but slow
        #$res = [Fanatec.Hardware]::GetPosition([uint32]$JoystickID, [uint32]$JoyFlags, [ref]$x, [ref]$y, [ref]$z, [ref]$r, [ref]$u, [ref]$v)
        #$rawGas    = [uint32](Get-AxisValue -Axis $GAS_AXIS    -X $x -Y $y -Z $z -R $r -U $u -V $v)
        #$rawClutch = [uint32](Get-AxisValue -Axis $CLUTCH_AXIS -X $x -Y $y -Z $z -R $r -U $u -V $v)
        #$rawBrake  = [uint32](Get-AxisValue -Axis $BRAKE_AXIS  -X $x -Y $y -Z $z -R $r -U $u -V $v)


        # Known Fanatec Pedals Axis
        # $GAS_AXIS    = 'Y'
        # $CLUTCH_AXIS = 'R'
        # $BRAKE_AXIS  = 'X' 

        # Static/Fixed now
        [uint32]$z=$u=$v=$rawGas=$rawBrake=$rawClutch=0
        $res = [Fanatec.Hardware]::GetPosition([uint32]$JoystickID, [uint32]$JoyFlags, [ref]$rawBrake, [ref]$rawGas, [ref]$z, [ref]$rawClutch, [ref]$u, [ref]$v)                
		$state.sampleAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		
        # --- Handle Disconnect (main.c-compatible: publish disconnect/reconnect frames) ---
        if ($res -ne [Fanatec.Hardware]::JOYERR_NOERROR) {

            if ($TargetVid -ne 0 -and $TargetPid -ne 0) {

                # Transition: Connected -> Disconnected (publish once)
                if ($State.controller_disconnected -eq 0) {
                    if ($Verbose) { Write-Host "Error Reading Joystick ($res). Disconnected." -ForegroundColor Red }
                    if ($Tts)     { $Synth.SpeakAsync($Strings.Disconnected) | Out-Null }

                    $State.controller_disconnected = 1
                    $State.last_disconnect_time_ms = [uint32][Environment]::TickCount

                    Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -Stopwatch $Stopwatch -LoopStartMs $LoopStart
                }

                if ($Verbose) { Write-Host ($Strings.ScanFailed -f 60) -ForegroundColor Red }
                Start-Sleep -Seconds 60

                $newId = Find-FanatecDevice $TargetVid $TargetPid
                if ($newId -ne -1) {
                    $JoystickID      = $newId
                    $State.joy_ID    = [uint32]$newId

                    if ($Tts) { $Synth.SpeakAsync($Strings.Connected) | Out-Null }

                    # Transition: Disconnected -> Connected (one-shot + publish)
                    $State.controller_disconnected = 0
                    $State.controller_reconnected  = 1
                    $State.last_reconnect_time_ms  = [uint32][Environment]::TickCount

                    # main.c recomputes these on reconnect (in case resolution/flags differ)
                    $AxisMax    = if (($JoyFlags -band 256) -ne 0) { 1023 } else { 65535 }
                    $State.axisMax = [uint32]$AxisMax

                    $GasIdleMax = [uint32]($AxisMax * $State.gas_deadzone_in  / 100)
                    $GasFullMin = [uint32]($AxisMax * $State.gas_deadzone_out / 100)
                    $BrakeIdleMax = [uint32]($AxisMax * $State.brake_deadzone_in  / 100)
                    $BrakeFullMin = [uint32]($AxisMax * $State.brake_deadzone_out / 100)
                    $ClutchIdleMax = [uint32]($AxisMax * $State.clutch_deadzone_in  / 100)
                    $ClutchFullMin = [uint32]($AxisMax * $State.clutch_deadzone_out / 100)
                    $AxisMargin = [uint32]($AxisMax * $State.margin / 100)

                    $State.gasIdleMax   = $GasIdleMax
                    $State.gasFullMin   = $GasFullMin
                    $State.brakeIdleMax = $BrakeIdleMax
                    $State.brakeFullMin = $BrakeFullMin
                    $State.clutchIdleMax = $ClutchIdleMax
                    $State.clutchFullMin = $ClutchFullMin
                    $State.axisMargin   = $AxisMargin

                    # Reset runtime/estimator state (main.c does this to avoid instant alerts)
                    $LastFullThrottleTime      = [uint32][Environment]::TickCount
                    $LastGasActivityTime       = [uint32][Environment]::TickCount
                    $LastGasAlertTime          = 0
                    $IsRacing                  = $false
                    $PeakGasInWindow           = 0
                    $LastClutchValue           = 0
                    $RepeatingClutchCount      = 0
                    $BestEstimatePercent       = 100
                    $LastPrintedEstimate       = 100
                    $EstimateWindowPeakPercent = 0
                    $EstimateWindowStartTime   = [uint32][Environment]::TickCount
                    $LastEstimatePrintTime     = 0
                    $CurrentPercent            = 0

                    # Mirror resets into telemetry fields
                    $State.isRacing                  = 0
                    $State.peakGasInWindow           = [uint32]$PeakGasInWindow
                    $State.lastFullThrottleTime      = [uint32]$LastFullThrottleTime
                    $State.lastGasActivityTime       = [uint32]$LastGasActivityTime
                    $State.lastGasAlertTime          = [uint32]$LastGasAlertTime
                    $State.lastClutchValue           = [uint32]$LastClutchValue
                    $State.repeatingClutchCount      = [int]$RepeatingClutchCount
                    $State.best_estimate_percent     = [uint32]$BestEstimatePercent
                    $State.last_printed_estimate     = [uint32]$LastPrintedEstimate
                    $State.estimate_window_peak_percent = [uint32]$EstimateWindowPeakPercent
                    $State.estimate_window_start_time   = [uint32]$EstimateWindowStartTime
                    $State.last_estimate_print_time     = [uint32]$LastEstimatePrintTime
                    $State.currentPercent               = [uint32]$CurrentPercent

                    Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -Stopwatch $Stopwatch -LoopStartMs $LoopStart
                }

                continue
            }

            # No VID/PID specified: main.c does not enter reconnect mode; just wait a bit and retry
            Start-Sleep -Milliseconds 1000
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

        $State.UpdatePercentages() # --- Percentages (Moved to C# for performance) ---

<#
        # --- Percentages ---
        $State.gas_physical_pct = [uint32](100 * $State.gasValue / $AxisMax)
        $State.clutch_physical_pct = [uint32](100 * $State.clutchValue / $AxisMax)
        $State.brake_physical_pct = [uint32](100 * $State.brakeValue / $AxisMax)

        
        # --- Percentages ---
        $State.gas_logical_pct    = Compute-LogicalPct -Value $State.gasValue    -IdleMax $GasIdleMax -FullMin $GasFullMin
        $State.clutch_logical_pct = Compute-LogicalPct -Value $State.clutchValue -IdleMax $GasIdleMax -FullMin $GasFullMin
        $State.brake_logical_pct  = Compute-LogicalPct -Value $State.brakeValue  -IdleMax $GasIdleMax -FullMin $GasFullMin
        


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
#>
        
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
                    if ($Verbose) { Write-Host $Strings.ResumingActivity -ForegroundColor Cyan }
                    $IsRacing = $true
                }
                $LastGasActivityTime = $State.currentTime
            } elseif ($IsRacing -and ($State.currentTime - $LastGasActivityTime) -gt $GasTimeoutMs) {
                if ($Verbose) { Write-Host ("Gas: Auto-Pause (Idle for {0} s)." -f $GasTimeout) -ForegroundColor Cyan }
                $IsRacing = $false

                if ($EstimateGasDeadzone) {
                    $EstimateWindowStartTime   = $State.currentTime
                    $EstimateWindowPeakPercent = 0
                }
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
                
                # Gas deadzone-out estimation and optional auto-adjust 
                # Estimator (main.c semantics)
                if ($EstimateGasDeadzone) {

                    # Update peak usage within current estimation window
                    if ($State.gasValue -gt $GasIdleMax) {
                        $CurrentPercent = [uint32]($State.gasValue * 100 / $AxisMax)
                        $State.currentPercent = [uint32]$CurrentPercent

                        if ($CurrentPercent -gt $EstimateWindowPeakPercent) {
                            $EstimateWindowPeakPercent = $CurrentPercent
                        }
                    }

                    # Window elapsed?
                    if (($State.currentTime - $EstimateWindowStartTime) -ge $GasCooldownMs) {

                        if ($EstimateWindowPeakPercent -ge $GasMinUsage) {
                            $candidate = $EstimateWindowPeakPercent

                            if ($candidate -lt $BestEstimatePercent) {
                                $BestEstimatePercent = $candidate
                            }

                            # Speak only if best estimate decreased and cooldown satisfied (last_printed_estimate logic)
                            if (($BestEstimatePercent -lt $LastPrintedEstimate) -and
                                (($State.currentTime - $LastEstimatePrintTime) -ge $GasCooldownMs)) {

                                $msg = $Strings.AlertNewEstimate -f $BestEstimatePercent
                                if ($Verbose) { Write-Host $msg -ForegroundColor Cyan }
                                if ($Tts) { $Synth.SpeakAsync($msg) | Out-Null }

                                $State.gas_estimate_decreased = 1
                                $LastPrintedEstimate       = $BestEstimatePercent
                                $LastEstimatePrintTime     = $State.currentTime
                            }

                            # Optional auto adjust (main.c rules)
                            if ($AutoGasAdjustEnabled -and
                                ($BestEstimatePercent -lt $GasDeadzoneOut) -and
                                ($BestEstimatePercent -ge $AutoGasDeadzoneMin)) {

                                $GasDeadzoneOut = $BestEstimatePercent
                                $State.gas_deadzone_out = $GasDeadzoneOut

                                # Recompute full-min and mirror into telemetry
                                $GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
                                $State.gasFullMin = $GasFullMin

                                $msg = $Strings.AlertAutoAdjust -f $GasDeadzoneOut
                                if ($Verbose) { Write-Host $msg -ForegroundColor Cyan }
                                if ($Tts) { $Synth.SpeakAsync($msg) | Out-Null }

                                $State.gas_auto_adjust_applied = 1
                            }
                        }

                        # Reset the window
                        $EstimateWindowStartTime   = $State.currentTime
                        $EstimateWindowPeakPercent = 0
                    }

                    # Mirror window fields for telemetry
                    $State.estimate_window_start_time   = [uint32]$EstimateWindowStartTime
                    $State.estimate_window_peak_percent = [uint32]$EstimateWindowPeakPercent
                    $State.best_estimate_percent        = [uint32]$BestEstimatePercent
                    $State.last_printed_estimate        = [uint32]$LastPrintedEstimate
                    $State.last_estimate_print_time     = [uint32]$LastEstimatePrintTime
                }
            }
        }
        


        # --- Telemetry Publish ---

        # --- Mirror runtime locals into telemetry fields (fixes the “always 0” values in PedDash) ---
        $State.isRacing             = [int][bool]$IsRacing
        $State.peakGasInWindow      = [uint32]$PeakGasInWindow
        $State.lastFullThrottleTime = [uint32]$LastFullThrottleTime
        $State.lastGasActivityTime  = [uint32]$LastGasActivityTime
        $State.lastGasAlertTime     = [uint32]$LastGasAlertTime

        $State.lastClutchValue      = [uint32]$LastClutchValue
        $State.repeatingClutchCount = [int]$RepeatingClutchCount


        Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -Stopwatch $Stopwatch -LoopStartMs $LoopStart

        # --- FIX: Calculate Duration BEFORE Sleep (Execution Time Only) ---
        # Important: Calculate loop duration for the *current* iteration. This value will be available in the Telemetry state during the *next* Enqueue().
        $TickEnd = [uint32][Environment]::TickCount
        $PreviousLoopTimeMs = $TickEnd - $TickStart        
        
        Start-Sleep -Milliseconds $SleepTime
        
    }
}
finally {
    Write-Host "Initiating Shutting down ..." -ForegroundColor Yellow

    # --- CLEAN SHUTDOWN ---
    # 1. Signal background thread loop to stop
    [Fanatec.Shared]::StopSignal = $true

	# GET request to force the web server to quit
	if ($HttpInstance) { 
		Write-Host "Sending HTTP/QUIT ..."
		try {
			Invoke-RestMethod -Uri "http://127.0.0.1:8181/QUIT" -Method GET  -ErrorAction SilentlyContinue | Out-Null
		} catch 
		{
			# Silently 
			Write-Host ("[{0}] ERROR: {1}" -f [DateTime]::Now, $_)
		}
		Start-Sleep 1
	}

    if ($Synth) { 
		Write-Host "Synth.Dispose() ..."
		$Synth.Dispose() 
		Write-Host "Nulling Synth ..."
		$Synth = $null		
	}
    
    
    # 2. Force kill the background runspace
    if ($HttpInstance) {
		Write-Host "HttpInstance.Stop() ..."
        $HttpInstance.Stop()
        Write-Host "HttpInstance.Dispose() ..."
		$HttpInstance.Dispose()
		Write-Host "Nulling HttpInstance ..."
		$HttpInstance = $null
    }


    # Force Garbage Collection (The "Nuclear" Cleanup)
    # This forces .NET to reclaim the memory NOW, rather than waiting.
	Write-Host "Nuclear Cleanup ..."
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    
    Write-Host "Finalized." -ForegroundColor Yellow
	
	if ($mutex) { $mutex.Dispose() }
}
