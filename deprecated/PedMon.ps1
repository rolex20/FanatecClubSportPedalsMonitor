Set-StrictMode -Version Latest

#
# PedMon configuration defaults and user-facing messages
#
$script:PedMonDefaults = @{
    verbose_flag                = 0
    monitor_clutch              = 0
    monitor_gas                 = 0

    gas_deadzone_in             = 5
    gas_deadzone_out            = 93
    gas_window                  = 30
    gas_cooldown                = 60
    gas_timeout                 = 10
    gas_min_usage_percent       = 20

    axis_normalization_enabled  = 1
    debug_raw_mode              = 0
    clutch_repeat_required      = 4

    estimate_gas_deadzone_enabled = 0
    auto_gas_deadzone_enabled     = 0
    auto_gas_deadzone_minimum     = 0

    target_vendor_id            = 0
    target_product_id           = 0

    telemetry_enabled           = 0
    tts_enabled                 = 1
    ipc_enabled                 = 0
    no_console_banner           = 0

    joy_ID                      = [uint32]17
    joy_Flags                   = [uint32]0xFF
    iterations                  = [uint32]1
    margin                      = [uint32]5
    sleep_Time                  = [uint32]1000

    gas_timeout_ms              = [uint32]10000
    gas_window_ms               = [uint32]30000
    gas_cooldown_ms             = [uint32]60000

    no_buffer                   = 0
    process_priority            = 'Normal'
    affinity_mask               = $null
}

$script:PedMonMessages = @{
    HelpText              = @"
Usage: PedMon.ps1 [--monitor-clutch] [--monitor-gas] [options]

   Auto-Reconnect:
       --vendor-id HEX:    Vendor ID (e.g. 0EB7) for auto-reconnection.
       --product-id HEX:   Product ID (e.g. 1839) for auto-reconnection.

   Clutch & Gas:
       --monitor-clutch:   Enable Clutch spike monitoring.
       --monitor-gas:      Enable Gas drift monitoring.

   Telemetry & UI:
       --telemetry:        Enable shared-memory telemetry for external tools (PedBridge / PedDash).
       --tts:              Enable Text-to-Speech alerts (default).
       --no-tts:           Disable Text-to-Speech alerts, when telemetry is used instead.
       --ipc:              Enable dispatchig tts alerts via IPC SPEAK.
       --no-console-banner: Suppress startup/status banners in console.

   General:
       --verbose:          Enable verbose logging (prints axis values, config, etc.).
       --brief:            Disable verbose logging (default unless --verbose is used).
       --joystick ID:      Initial Joystick ID (0-15).
       --iterations N:     Number of iterations. Default=1. Use 0 for infinite loop.
       --sleep MS:         Wait time (ms) between iterations. Default=1000. Must be > 0.
       --flags N:          dwFlags. Default=JOY_RETURNALL.
                           Use 266 for JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY.
       --margin N:         Tolerance (0-100) for clutch stickiness. Default=5.
       --no_buffer:        Disable standard output buffering.
       --no-axis-normalization:
                           Do NOT invert pedal axes; use raw 0..axisMax values.
                           Default behavior is to normalize so 0=idle, max=full.
       --debug-raw:        In verbose mode, print raw and normalized axis values.

   Performance & Priority:
       --idle:             Set process priority to IDLE.
       --belownormal:      Set process priority to BELOW_NORMAL.
       --affinitymask N:   Decimal mask for CPU core affinity.

   Gas Tuning Options (monitor-gas only):
       --gas-deadzone-in:  % Idle Deadzone (0-100). Default=5.
       --gas-deadzone-out: % Full-throttle threshold (0-100). Default=93.
       --gas-window:       Seconds to wait for Full Throttle. Default=30.
       --gas-timeout:      Seconds idle to assume Menu/Pause. Default=10.
       --gas-cooldown:     Seconds between alerts. Default=60.
       --gas-min-usage:    % minimum gas usage in a window before drift alert.
                           Default=20. Increase if you race gently (no full-throttle).
       --estimate-gas-deadzone-out:
                           Estimate and print suggested --gas-deadzone-out from observed
                           maximum gas travel over time. Requires --monitor-gas.
       --adjust-deadzone-out-with-minimum N:
                           Auto-decrease gas-deadzone-out to match observed maximum,
                           but never below N (0-100). Requires --monitor-gas and
                           --estimate-gas-deadzone-out.

   Clutch Tuning Options (monitor-clutch only):
       --clutch-repeat N:  Consecutive samples required for clutch noise alert.
                           Default=4. Increase if you lower --sleep.
"@
    Errors = @{
        MissingValue              = "Missing value for {0}"
        UnknownArgument           = "Unknown argument '{0}'. Use --help for usage."
        InvalidJoystickId         = "Error: Invalid Joystick ID (0-15)."
        MarginRange               = "Error: margin must be 0-100."
        PercentRange              = "Error: {0} must be 0-100."
        PositiveValue             = "Error: {0} must be > 0."
        AdjustRange               = "Error: adjust-deadzone-out-with-minimum must be 0-100."
        EstimateRequiresGas       = "Error: --estimate-gas-deadzone-out requires --monitor-gas."
        AdjustRequiresGas         = "Error: --adjust-deadzone-out-with-minimum requires --monitor-gas."
        AdjustRequiresEstimate    = "Error: --adjust-deadzone-out-with-minimum also requires --estimate-gas-deadzone-out."
        AdjustMinimumTooHigh      = "Error: adjust-deadzone-out-with-minimum ({0}) must be <= gas-deadzone-out ({1})."
        SleepMustBePositive       = "Error: sleep must be > 0 ms."
        CriticalSecurity          = "Critical Error: Failed to create security descriptor ({0})."
        CriticalFileMapping       = "Critical Error: Failed to create file mapping ({0})."
        CriticalMappingView       = "Critical Error: Failed to map view of file ({0})."
        InvalidTelemetryHandle    = "Critical Error: Invalid telemetry mapping handle."
        TelemetryNotInitialized   = "Telemetry not initialized; skipping publish."
        TelemetryOpenFailed       = "Error opening existing telemetry mapping ({0})."
    }
    Status = @{
        ConfigHeader              = "PedMon configuration:"
        SingleInstanceBlocked     = "Error.  Another instance of Fanatec Monitor is already running."
        LookingForController      = "Looking for Controller VID:{0} PID:{1}..."
        FoundAtId                 = "Found at ID: {0}"
        NotFoundAtStartup         = "Not found at startup. Will use ID {0} until error."
        MonitoringBanner          = "Monitoring ID=[{0}] VID=[{1}] PID=[{2}]"
        AxisMaxBanner             = "Axis Max: [{0}]"
        AxisNormalizationEnabled  = "Axis normalization: enabled (normalize inverted -> 0..max)"
        AxisNormalizationDisabled = "Axis normalization: disabled (use raw 0..max)"
        GasConfig                 = "Gas Config: DZ In:{0}% Out:{1}% Window:{2}s Timeout:{3}s Cooldown:{4}s MinUsage:{5}%"
        GasEstimationEnabled      = "Gas Estimation: enabled (will print [Estimate] lines)."
        AutoAdjustEnabled         = "Auto-adjust: enabled (min={0}%)"
        EnteringReconnection      = "Entering Reconnection Mode..."
        ReconnectedAt             = "Reconnected at ID {0}"
        ScanRetry                 = "Scan failed. Retrying in 60s..."
        ErrorReadingJoystick      = "Error reading joystick (Code {0})"
        TelemetryInit             = "Telemetry enabled: creating shared memory..."
        TelemetryInitDone         = "Telemetry initialized."
        TelemetryShutdown         = "Telemetry shut down."
        PedBridgeInitializing     = "PedBridge v1.9c - Initializing..."
        PedBridgeShutdown         = "\nShutting down PedBridge..."
        UsingExistingDefinition   = "Using existing C# definition. If you modified the C# code, please restart PowerShell."
    }
    Alerts = @{
        ControllerDisconnected    = "Controller disconnected. Waiting 60 seconds."
        ControllerFound           = "Controller found. Resuming monitoring."
        ControllerNotFound        = "Controller not found. Retrying."
        Rudder                    = "Rudder"
        GasPercentTemplate        = "Gas {0} percent."
        NewDeadzoneEstimate       = "New deadzone estimation:{0} percent."
        AutoAdjustApplied         = "[AutoAdjust] gas-deadzone-out updated to {0} (min={1})"
    }
}

<#!
.SYNOPSIS
    PedMon - PowerShell host for Fanatec pedal monitoring helpers.
.DESCRIPTION
    Recreates the command-line surface area of main.c so PowerShell telemetry,
    HTTP, and TTS components can share identical defaults and semantics.
    Parsed arguments are stored in a state record ($script:PedMonState) for
    consumption by telemetry loops and HTTP/TTS handlers.
#>

param(
    [string[]]$Args = $args
)

class PedMonState {
    [int]$verbose_flag
    [int]$monitor_clutch
    [int]$monitor_gas

    [int]$gas_deadzone_in
    [int]$gas_deadzone_out
    [int]$gas_window
    [int]$gas_cooldown
    [int]$gas_timeout
    [int]$gas_min_usage_percent

    [int]$axis_normalization_enabled
    [int]$debug_raw_mode
    [int]$clutch_repeat_required

    [int]$estimate_gas_deadzone_enabled
    [int]$auto_gas_deadzone_enabled
    [int]$auto_gas_deadzone_minimum

    [int]$target_vendor_id
    [int]$target_product_id

    [int]$telemetry_enabled
    [int]$tts_enabled
    [int]$ipc_enabled
    [int]$no_console_banner

    [uint32]$joy_ID
    [uint32]$joy_Flags
    [uint32]$iterations
    [uint32]$margin
    [uint32]$sleep_Time

    [uint32]$gas_timeout_ms
    [uint32]$gas_window_ms
    [uint32]$gas_cooldown_ms

    [int]$no_buffer
    [string]$process_priority
    [Nullable[long]]$affinity_mask

    [void]UpdateDerivedFields() {
        $this.gas_timeout_ms = [uint32]($this.gas_timeout * 1000)
        $this.gas_window_ms = [uint32]($this.gas_window * 1000)
        $this.gas_cooldown_ms = [uint32]($this.gas_cooldown * 1000)
    }
}

function New-PedMonState {
    $state = [PedMonState]::new()
    foreach ($entry in $script:PedMonDefaults.GetEnumerator()) {
        $state.$($entry.Key) = $entry.Value
    }
    $state.UpdateDerivedFields()
    return $state
}

function Show-Help {
    $script:PedMonMessages.HelpText | Write-Host
}

function Resolve-Value {
    param(
        [string]$Argument,
        [string[]]$Args,
        [ref]$Index
    )

    if ($Argument -match '^--[^=]+=') {
        return $Argument.Split('=', 2)[1]
    }

    $Index.Value++
    if ($Index.Value -ge $Args.Count) {
        throw ($script:PedMonMessages.Errors.MissingValue -f $Argument)
    }

    return $Args[$Index.Value]
}

function Validate-State {
    param([PedMonState]$State)

    if ($State.joy_ID -gt 15 -and $State.target_vendor_id -eq 0) {
        throw $script:PedMonMessages.Errors.InvalidJoystickId
    }

    if ($State.margin -gt 100) {
        throw $script:PedMonMessages.Errors.MarginRange
    }

    foreach ($pair in @(
        @{Name = 'gas-deadzone-in'; Value = $State.gas_deadzone_in},
        @{Name = 'gas-deadzone-out'; Value = $State.gas_deadzone_out},
        @{Name = 'gas-min-usage'; Value = $State.gas_min_usage_percent}
    )) {
        if ($pair.Value -lt 0 -or $pair.Value -gt 100) {
            throw ($script:PedMonMessages.Errors.PercentRange -f $pair.Name)
        }
    }

    foreach ($pair in @(
        @{Name = 'gas-window'; Value = $State.gas_window},
        @{Name = 'gas-timeout'; Value = $State.gas_timeout},
        @{Name = 'gas-cooldown'; Value = $State.gas_cooldown},
        @{Name = 'clutch-repeat'; Value = $State.clutch_repeat_required}
    )) {
        if ($pair.Value -le 0) {
            throw ($script:PedMonMessages.Errors.PositiveValue -f $pair.Name)
        }
    }

    if ($State.auto_gas_deadzone_enabled -and ($State.auto_gas_deadzone_minimum -lt 0 -or $State.auto_gas_deadzone_minimum -gt 100)) {
        throw $script:PedMonMessages.Errors.AdjustRange
    }

    if ($State.estimate_gas_deadzone_enabled -and -not $State.monitor_gas) {
        throw $script:PedMonMessages.Errors.EstimateRequiresGas
    }

    if ($State.auto_gas_deadzone_enabled -and -not $State.monitor_gas) {
        throw $script:PedMonMessages.Errors.AdjustRequiresGas
    }

    if ($State.auto_gas_deadzone_enabled -and -not $State.estimate_gas_deadzone_enabled) {
        throw $script:PedMonMessages.Errors.AdjustRequiresEstimate
    }

    if ($State.auto_gas_deadzone_enabled -and $State.auto_gas_deadzone_minimum -gt $State.gas_deadzone_out) {
        throw ($script:PedMonMessages.Errors.AdjustMinimumTooHigh -f $State.auto_gas_deadzone_minimum, $State.gas_deadzone_out)
    }

    if ($State.sleep_Time -eq 0) {
        throw $script:PedMonMessages.Errors.SleepMustBePositive
    }
}

function Apply-SystemTuning {
    param([PedMonState]$State)

    $process = [System.Diagnostics.Process]::GetCurrentProcess()

    switch ($State.process_priority) {
        'Idle' { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle }
        'BelowNormal' { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        default { }
    }

    if ($State.affinity_mask -ne $null) {
        $process.ProcessorAffinity = [intptr]::new($State.affinity_mask)
    }
}

function Parse-Arguments {
    param(
        [string[]]$Args,
        [PedMonState]$State
    )

    $iRef = [ref]0
    while ($iRef.Value -lt $Args.Count) {
        $arg = $Args[$iRef.Value]
        switch -Regex ($arg.ToLowerInvariant()) {
            '^--help$' { Show-Help; exit 0 }
            '^-(h|\?)$' { Show-Help; exit 0 }

            '^--monitor-clutch$' { $State.monitor_clutch = 1; break }
            '^--monitor-gas$' { $State.monitor_gas = 1; break }
            '^--no-axis-normalization$' { $State.axis_normalization_enabled = 0; break }
            '^--debug-raw$' { $State.debug_raw_mode = 1; break }
            '^--estimate-gas-deadzone-out$' { $State.estimate_gas_deadzone_enabled = 1; break }
            '^--verbose$' { $State.verbose_flag = 1; break }
            '^--brief$' { $State.verbose_flag = 0; break }
            '^--telemetry$' { $State.telemetry_enabled = 1; break }
            '^--tts$' { $State.tts_enabled = 1; break }
            '^--no-tts$' { $State.tts_enabled = 0; break }
            '^--ipc$' { $State.ipc_enabled = 1; break }
            '^--no-console-banner$' { $State.no_console_banner = 1; break }
            '^--no_buffer$' { $State.no_buffer = 1; break }
            '^--idle$' { $State.process_priority = 'Idle'; break }
            '^--belownormal$' { $State.process_priority = 'BelowNormal'; break }

            '^--iterations$' { $State.iterations = [uint32](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--margin$' { $State.margin = [uint32](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--flags$' { $State.joy_Flags = [uint32](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--sleep$' { $State.sleep_Time = [uint32](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--joystick$' { $State.joy_ID = [uint32](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--affinitymask$' { $State.affinity_mask = [int64](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }

            '^--gas-deadzone-in$' { $State.gas_deadzone_in = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--gas-deadzone-out$' { $State.gas_deadzone_out = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--gas-window$' { $State.gas_window = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--gas-cooldown$' { $State.gas_cooldown = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--gas-timeout$' { $State.gas_timeout = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--gas-min-usage$' { $State.gas_min_usage_percent = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }
            '^--adjust-deadzone-out-with-minimum$' {
                $State.auto_gas_deadzone_minimum = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef)
                $State.auto_gas_deadzone_enabled = 1
                break
            }

            '^--clutch-repeat$' { $State.clutch_repeat_required = [int](Resolve-Value -Argument $arg -Args $Args -Index $iRef); break }

            '^--vendor-id$' {
                $val = Resolve-Value -Argument $arg -Args $Args -Index $iRef
                $State.target_vendor_id = [Convert]::ToInt32($val, 16)
                break
            }
            '^--product-id$' {
                $val = Resolve-Value -Argument $arg -Args $Args -Index $iRef
                $State.target_product_id = [Convert]::ToInt32($val, 16)
                break
            }

            default {
                throw ($script:PedMonMessages.Errors.UnknownArgument -f $arg)
            }
        }
        $iRef.Value++
    }

    Validate-State -State $State
    $State.UpdateDerivedFields()
    Apply-SystemTuning -State $State

    return $State
}

if (-not $script:PedMonState) {
    $script:PedMonState = New-PedMonState
}

try {
    $script:PedMonState = Parse-Arguments -Args $Args -State $script:PedMonState
}
catch {
    Write-Error $_
    exit 1
}

if ($script:PedMonState.verbose_flag) {
    Write-Host $script:PedMonMessages.Status.ConfigHeader -ForegroundColor Cyan
    $script:PedMonState | Format-List | Out-String | Write-Host
}
