<#
.SYNOPSIS
    PedMon - Fanatec ClubSport Pedal Monitor bootstrapper.

.DESCRIPTION
    Provides default messages and configuration along with helper utilities.
    Intended to be dot-sourced or run directly to monitor pedal telemetry.

.USAGE
    powershell.exe -ExecutionPolicy Bypass -File .\PedMon.ps1 [switches]

.SWITCHES
    -Verbose            Enable verbose logging.
    -Silent             Suppress console output (TTS still allowed).
    -NoTts              Disable text-to-speech prompts.
    -ForceNormalization Normalize all pedal axes to the configured range.
    -NoNormalization    Disable axis normalization.
    -Affinity <mask>    Override default processor affinity mask.
    -Priority <level>   Override default process priority class.
    -Help               Display this help summary.
#>

# User-facing messages (console + TTS)
$Messages = @{
    Startup               = "Initializing PedMon; preparing pedal telemetry monitor.";
    AlreadyRunning        = "Another instance appears to be running.";
    Exiting               = "Shutting down PedMon.";
    HelpRequested         = "Displaying help for PedMon switches.";
    NormalizationEnabled  = "Axis normalization enabled.";
    NormalizationDisabled = "Axis normalization disabled.";
    AffinitySet           = "Processor affinity applied.";
    PrioritySet           = "Process priority applied.";
    MissingInterop        = "Interop initialization failed; check native dependencies.";
    ParsingArgs           = "Parsing command-line arguments.";
    Ready                 = "Pedal monitor ready.";
}

# Default configuration values
$Defaults = @{
    DeadzoneThresholds = @{
        Throttle = 0.015
        Brake    = 0.020
        Clutch   = 0.020
    }
    Cooldowns = @{
        AxisDeltaMs = 250
        TtsMs       = 750
    }
    Windows = @{
        SampleWindow      = 64
        SpikeSuppression  = 5
        RollingAverage    = 10
    }
    NormalizeAxes    = $true
    NormalizationMin = 0.0
    NormalizationMax = 1.0
    Priority         = "AboveNormal"
    AffinityMask     = 0x0
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warn','Error','Verbose')][string]$Level = 'Info'
    )

    $timestamp = (Get-Date).ToString('u')
    $prefix = "[$Level]"

    if ($Level -eq 'Verbose' -and -not $PSBoundParameters.ContainsKey('Verbose')) {
        return
    }

    if (-not $script:Silent) {
        Write-Host "$timestamp $prefix $Message"
    }
}

function Show-Help {
    Write-Log -Message $Messages.HelpRequested -Level Info
    Get-Content -Path $MyInvocation.MyCommand.Definition | Select-String -Pattern '^\.|^-', '^#>'
    exit 0
}

function Parse-Arguments {
    param([string[]]$Args)

    Write-Log -Message $Messages.ParsingArgs -Level Info

    $parsed = [ordered]@{
        Verbose       = $false
        Silent        = $false
        NoTts         = $false
        NormalizeAxes = $Defaults.NormalizeAxes
        AffinityMask  = $Defaults.AffinityMask
        Priority      = $Defaults.Priority
    }

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch -regex ($Args[$i]) {
            '^-Verbose$'            { $parsed.Verbose = $true; continue }
            '^-Silent$'             { $parsed.Silent = $true; $script:Silent = $true; continue }
            '^-NoTts$'              { $parsed.NoTts = $true; continue }
            '^-ForceNormalization$' { $parsed.NormalizeAxes = $true; continue }
            '^-NoNormalization$'    { $parsed.NormalizeAxes = $false; continue }
            '^-Affinity$' {
                if ($i + 1 -lt $Args.Count) { $parsed.AffinityMask = [int]$Args[$i + 1]; $i++; continue }
            }
            '^-Priority$' {
                if ($i + 1 -lt $Args.Count) { $parsed.Priority = $Args[$i + 1]; $i++; continue }
            }
            '^-Help$' { Show-Help }
        }
    }

    return $parsed
}

function Initialize-NativeInterop {
    Write-Log -Message "Initializing native interop assemblies." -Level Info

    try {
        # Placeholder for loading native DLLs or registering COM components
        # Example: Add-Type -Path "./bin/PedalInterop.dll"
        return $true
    }
    catch {
        Write-Log -Message $Messages.MissingInterop -Level Error
        return $false
    }
}
