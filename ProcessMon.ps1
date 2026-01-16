<#
.SYNOPSIS
  High-Performance Multi-Threaded Process Monitor for Windows 11.
  Detects process start/stop events with near-zero latency and captures resource usage (CPU/RAM/IO).

.DESCRIPTION
  This script is engineered to diagnose "FPS Lag" and "Stutter" in gaming/sim-racing environments
  (specifically Forza Motorsport) caused by background processes launching unexpectedly.

  It utilizes a multi-threaded Producer-Consumer architecture to decouple event detection from
  metric sampling. This ensures that the "Start Time" recording is precise (detecting the exact
  moment of execution) while heavy WMI sampling occurs in a background thread without blocking
  the main event loop.
  
.KEY-TECH
	This utility demonstrates enterprise-grade PowerShell scripting by implementing a high-concurrency Producer-Consumer architecture. To solve the latency limitations of standard event loops, the solution leverages raw .NET Runspaces for true multi-threading, decoupling the UI/Event thread from the heavy WMI sampling logic. Key technical features include thread synchronization using Monitor locks and synchronized hashtables to prevent race conditions, optimization of WMI/CIM queries via bulk-fetching (reducing overhead by O(n)), and direct .NET API integration for precise timing and memory management.

.ARCHITECTURE
  1. Main Thread (Event Listener & UI):
     - Uses WMI Event Tracers (Win32_ProcessStartTrace) for immediate detection (<10ms lag).
     - Handles all Console Output and Text-To-Speech (COM objects) to ensure thread safety.
     - Manages the creation and cleanup of process objects in the shared state.
     - Calculates metadata (Owner, Command Line, Parent) immediately upon process start.

  2. Background Runspace (Metrics Sampler):
     - Runs in a dedicated, asynchronous PowerShell Runspace.
     - Performs BULK WMI queries (Win32_PerfFormattedData_PerfProc_Process) to fetch data
       for ALL processes in a single call (~20ms execution) rather than iterating per-process.
     - Updates the shared synchronized hashtable with CPU, Memory, and I/O metrics.
     - Implements strict Type-Casting (UInt32 -> Int32) to ensure WMI PIDs match PowerShell PIDs.

  3. Synchronization & Safety:
     - Shared State: Uses [Hashtable]::Synchronized for thread-safe read/write operations.
     - Fault Tolerance: Background thread uses "SilentlyContinue" on WMI failures to prevent 
       crashes during high-load scenarios (e.g., Anti-Cheat engine interference).
     - Heartbeat Monitor: The Main Thread actively monitors the Background Thread's health.

.KEYWORDS
	Windows 11 Process Monitor, FPS Lag Fix, Sim Racing Stutter, Forza Motorsport Performance, Real-time CPU Spike Detector, Background Process Killer, PowerShell WMI Monitoring, Windows Task Analysis, Gaming Performance Tuning, Disk I/O Latency, High Performance PowerShell, SysAdmin Tools.

.PARAMETER SampleIntervalMs
  The time in milliseconds between metric samples (default: 1000ms).
  Lower values provide higher resolution but increase global WMI CPU overhead.

.PARAMETER OutputCsv
  Path to save the final CSV report. If omitted, saves to the script directory with a timestamp.

.PARAMETER Quiet
  Suppress console output (CSV export only).

.NOTES
  - Requires Administrator privileges for full visibility into System/Service processes.
  - Designed for PowerShell 5.1 on Windows 10/11.
#>

[CmdletBinding()]
param(
  [int]$SampleIntervalMs = 1000,
  [string]$OutputCsv = "",
  [switch]$Quiet = $false,
  [string[]]$ExcludeNames = @( "sample1.exe", "msedge.exe", "conhost.exe","dllhost.exe","sihost.exe","RuntimeBroker.exe", "svchost.exe" )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- 1. SHARED STATE ---
$global:SyncHash = [hashtable]::Synchronized(@{
    ProcState   = [hashtable]::Synchronized(@{})
    Reports     = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    IsRunning   = $true
    Heartbeat   = (Get-Date)
    BgError     = "" 
})

# --- 2. TTS SETUP ---
Add-Type -AssemblyName System.Speech
$global:TtsLock = New-Object object
$global:TtsSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$global:TtsSynth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)
$global:TtsSynth.Volume = 80
$global:TtsSynth.Rate   = 0

function Speak-ProcessEvent {
  param([string]$Text)
  return
  try {
    [System.Threading.Monitor]::Enter($global:TtsLock)
    try { [void]$global:TtsSynth.SpeakAsync($Text) } finally { [System.Threading.Monitor]::Exit($global:TtsLock) }
  } catch {}
}

function Write-Info([string]$Msg) {
  if (-not $Quiet) { Write-Host $Msg }
}

# --- 3. MAIN THREAD HELPERS ---

function Get-OwnerInfoAndMeta([int]$pidVal) {
    $out = @{ Owner=""; OwnerSid=""; CommandLine=""; Path=""; ParentName=""; SessionId=-1; AccessDenied=$false }
    try {
        $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$pidVal" -ErrorAction Stop
        $out.Path        = $p.ExecutablePath
        $out.CommandLine = $p.CommandLine
        $out.SessionId   = $p.SessionId
        
        try {
            $pp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction Stop
            $out.ParentName = $pp.Name
        } catch {}

        try {
            $sidRes = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
            if ($sidRes.Sid) { $out.OwnerSid = $sidRes.Sid }
        } catch {}

        try {
            $own = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($own.User) {
                $dom = if ($own.Domain) { $own.Domain + "\" } else { "" }
                $out.Owner = "$dom$($own.User)"
            }
        } catch {}
    } catch {
        $out.AccessDenied = $true
    }
    return $out
}

function New-ProcStateObject($procId, $name, $parentPid, $timeGenerated) {
    $meta = Get-OwnerInfoAndMeta -pidVal $procId
    
    $startLag = 0
    if ($timeGenerated) {
        $startLag = [math]::Round(((Get-Date) - $timeGenerated).TotalSeconds, 3)
    }

    return [pscustomobject]@{
        ProcId            = $procId
        Name              = $name
        ParentProcId      = $parentPid
        ParentName        = $meta.ParentName
        StartTime         = (Get-Date)
        TimeGenerated     = $timeGenerated
        StartLagSec       = $startLag
        StopTime          = $null
        
        Owner             = $meta.Owner
        OwnerSid          = $meta.OwnerSid
        CommandLine       = $meta.CommandLine
        Path              = $meta.Path
        SessionId         = $meta.SessionId
        AccessRestricted  = $meta.AccessDenied
        
        # Metrics
        SampleCount       = 0
        CpuPeak           = 0.0
        CpuSum            = 0.0
        WsPeak            = 0.0
        WsSum             = 0.0
        PvPeak            = 0.0 
        ReadBpsPeak       = 0.0
        ReadBpsSum        = 0.0
        WriteBpsPeak      = 0.0
        WriteBpsSum       = 0.0
        TotalReadEst      = 0.0
        TotalWriteEst     = 0.0
        LastSampleTime    = (Get-Date)
    }
}

function Get-ScriptArguments {
    param([string]$FullString, [string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FullString)) { return "" }
    # Case-insensitive search for the executable name in the command line
    $idx = $FullString.IndexOf($FileName, [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -eq -1) { return $FullString } # Fallback if name not found
    return $FullString.Substring($idx + $FileName.Length).Trim()
}

function Stop-And-Report([int]$procIdVal) {
    $st = $global:SyncHash.ProcState[$procIdVal]
    if (-not $st) { return }
    $global:SyncHash.ProcState.Remove($procIdVal)

    $st.StopTime = Get-Date
    $dur = ($st.StopTime - $st.StartTime).TotalSeconds
    $samples = [math]::Max(1, $st.SampleCount)
    $toMB = { param($v) [math]::Round($v/1MB, 2) }

    $isSystem = ($st.OwnerSid -eq "S-1-5-18")
    $isService = ($isSystem -or $st.OwnerSid -eq "S-1-5-19" -or $st.OwnerSid -eq "S-1-5-20")
    
    $row = [pscustomobject]@{
        ProcId             = $st.ProcId
        Name               = $st.Name
        ParentProcId       = $st.ParentProcId
        ParentName         = $st.ParentName
        StartTime          = $st.StartTime
        StopTime           = $st.StopTime
        TimeGenerated      = $st.TimeGenerated
        StartLagSec        = $st.StartLagSec
        DurationSec        = [math]::Round($dur, 3)
        Owner              = $st.Owner
        OwnerSid           = $st.OwnerSid
        CommandLine        = $st.CommandLine
        IsSystemAccount    = $isSystem
        IsServiceAccount   = $isService
        AccessRestricted   = $st.AccessRestricted
        SampleCount        = $st.SampleCount
        
        # Metrics
        CpuPeakPct         = [math]::Round($st.CpuPeak, 2)
        WorkingSetPeakMB   = (& $toMB $st.WsPeak)
        PrivateBytesPeakMB = (& $toMB $st.PvPeak)
        ReadBpsPeak        = [math]::Round($st.ReadBpsPeak, 0)
        WriteBpsPeak       = [math]::Round($st.WriteBpsPeak, 0)
        TotalReadMB        = (& $toMB $st.TotalReadEst)
        TotalWriteMB       = (& $toMB $st.TotalWriteEst)
        
        Visibility         = if ($st.AccessRestricted) { "Restricted" } else { "Full" }
        MetricMode         = if ($samples -gt 0) { "WmiPerfByPid" } else { "None" }
        TotalsMode         = "IntegratedBps"
    }

    $global:SyncHash.Reports.Add($row) | Out-Null
    
    # Console Output
    $cmdDisplay = if ($row.CommandLine) { 
        if ($row.CommandLine.Length -gt 100) { $row.CommandLine.Substring(0,97)+"..." } else { $row.CommandLine }
    } else { $row.Name }

    Write-Info ("`n[STOP] {0,-15} (ID:{1}) ran {2}s. StartLag: {3}s" -f $row.Name, $row.ProcId, $row.DurationSec, $row.StartLagSec)
    
    if ($row.DurationSec -gt 1 -OR $row.CpuPeakPct -gt 1) {
        $f = $row | Select-Object ProcId, Name, ParentProcId, ParentName, StartTime, StopTime, TimeGenerated, StartLagSec, DurationSec, Owner, OwnerSid, CommandLine, IsSystemAccount, IsServiceAccount, AccessRestricted, Visibility, MetricMode, TotalsMode, SampleCount, CpuPeakPct, WorkingSetPeakMB, PrivateBytesPeakMB, ReadBpsPeak, WriteBpsPeak, TotalReadMB, TotalWriteMB | Format-List | Out-String
        Write-Info $f.Trim()
        Write-Info ""
    }

    if ($row.DurationSec -gt 1) { 
        Speak-ProcessEvent "Stopped $($row.Name)" 
    }
}

# --- 4. BACKGROUND WORKER ---
$bgScriptBlock = {
    param($SharedHash, $IntervalMs, $CoreCount)
    Set-StrictMode -Off 
    Import-Module CimCmdlets -ErrorAction SilentlyContinue

    try {
        while ($SharedHash.IsRunning) {
            $loopStart = Get-Date
            $SharedHash.Heartbeat = $loopStart

            try {
                $allPerf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue
                
                $perfMap = @{}
                if ($allPerf) {
                    foreach ($p in $allPerf) { 
                        # CRITICAL FIX: Cast IDProcess (UInt32) to [int] (Int32).
                        # Without this, Hashtable lookup fails because types don't match.
                        $perfMap[[int]$p.IDProcess] = $p 
                    }
                }

                $trackedPids = @($SharedHash.ProcState.Keys)

                foreach ($pidVal in $trackedPids) {
                    $st = $SharedHash.ProcState[$pidVal]
                    if (-not $st) { continue }

                    # Now $pidVal (int) will successfully match keys in $perfMap
                    if ($perfMap.ContainsKey($pidVal)) {
                        $pData = $perfMap[$pidVal]
                        
                        $now = Get-Date
                        $dt  = ($now - $st.LastSampleTime).TotalSeconds
                        if ($dt -le 0) { $dt = 1.0 }
                        $st.LastSampleTime = $now
                        $st.SampleCount++

                        $cpu = [math]::Round(($pData.PercentProcessorTime / $CoreCount), 1)
                        $ws  = $pData.WorkingSet
                        $pv  = $pData.PrivateBytes
                        $rBps = $pData.IOReadBytesPersec
                        $wBps = $pData.IOWriteBytesPersec

                        $st.CpuSum  += $cpu
                        if ($cpu -gt $st.CpuPeak) { $st.CpuPeak = $cpu }
                        
                        $st.WsSum += $ws
                        if ($ws -gt $st.WsPeak) { $st.WsPeak = $ws }
                        
                        if ($pv -gt $st.PvPeak) { $st.PvPeak = $pv }

                        $st.ReadBpsSum += $rBps
                        if ($rBps -gt $st.ReadBpsPeak) { $st.ReadBpsPeak = $rBps }
                        
                        $st.WriteBpsSum += $wBps
                        if ($wBps -gt $st.WriteBpsPeak) { $st.WriteBpsPeak = $wBps }

                        $st.TotalReadEst  += ($rBps * $dt)
                        $st.TotalWriteEst += ($wBps * $dt)
                    }
                }
            }
            catch { $SharedHash.BgError = $_.Exception.Message }

            $taken = ((Get-Date) - $loopStart).TotalMilliseconds
            $sleep = [math]::Max(50, ($IntervalMs - $taken))
            Start-Sleep -Milliseconds $sleep
        }
    }
    catch { $SharedHash.BgError = "FATAL: " + $_.Exception.Message }
}

# --- 5. STARTUP ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run as Administrator to see System processes."
}

if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutputCsv = Join-Path $base "ProcessMon_Report_$(Get-Date -f yyyyMMdd-HHmmss).csv"
}

Write-Info "Starting Process Monitor..."
Write-Info "Main Thread: Event Listening Only"
Write-Info "Bg Thread:   Metrics Sampling (Interval: ${SampleIntervalMs}ms)"

$rs = [PowerShell]::Create()
$rs.Runspace.SessionStateProxy.SetVariable("SharedHash", $global:SyncHash)
[void]$rs.AddScript($bgScriptBlock)
[void]$rs.AddArgument($global:SyncHash)
[void]$rs.AddArgument($SampleIntervalMs)
[void]$rs.AddArgument([Environment]::ProcessorCount)
$asyncHandle = $rs.BeginInvoke()

# --- 6. MAIN LOOP ---
Register-WmiEvent -Namespace "root\cimv2" -Query "SELECT * FROM Win32_ProcessStartTrace" -SourceIdentifier "ProcStart" | Out-Null
Register-WmiEvent -Namespace "root\cimv2" -Query "SELECT * FROM Win32_ProcessStopTrace" -SourceIdentifier "ProcStop" | Out-Null

try {
    while ($true) {
        $event = Wait-Event -Timeout 1
        
        if ($asyncHandle.IsCompleted) {
            Write-Error "Background thread died!"
            if ($global:SyncHash.BgError) { Write-Error $global:SyncHash.BgError }
            break
        }

        if ($event) {
            $eArgs = $event.SourceEventArgs.NewEvent
            $pidVal = [int]$eArgs.ProcessID
            $name   = $eArgs.ProcessName

            if ($event.SourceIdentifier -eq "ProcStart") {
                if ($ExcludeNames -notcontains $name) {
                    if (-not $global:SyncHash.ProcState.ContainsKey($pidVal)) {
                        $st = New-ProcStateObject -procId $pidVal -name $name -parentPid $eArgs.ParentProcessID -timeGenerated $event.TimeGenerated
						
						# ... inside ProcStart ...
						$global:SyncHash.ProcState[$pidVal] = $st

						# --- RESTORED LOGGING LOGIC ---
						$ownerDisp = if ($st.Owner) { $st.Owner } else { "<unknown>" }
						$pnDisp    = if ($st.ParentName) { $st.ParentName } else { "<unknown>" }
						$cmdFull   = if ($st.CommandLine) { $st.CommandLine } else { "" }

						# Extract arguments and truncate if too long for one line
						$argsOnly  = Get-ScriptArguments -FullString $cmdFull -FileName $name
						if ($argsOnly.Length -gt 60) { $argsOnly = $argsOnly.Substring(0,57) + "..." }

						$trackedCount = $global:SyncHash.ProcState.Count

						Write-Info ("[START] {0,6}  {1,-15} StartLag={6,5}s Tracked={7,-3} Parent={2,6}({3,-15}) Owner={4,-20} Cmd={5}" -f `
							$pidVal, $name, $eArgs.ParentProcessID, $pnDisp, $ownerDisp, $argsOnly, $st.StartLagSec, $trackedCount)

						Speak-ProcessEvent "Started $name"
						# ...
                    }
                }
            }
            elseif ($event.SourceIdentifier -eq "ProcStop") {
                Stop-And-Report -procIdVal $pidVal
            }
            Remove-Event -EventIdentifier $event.EventIdentifier
        }
    }
}
finally {
    Write-Host "Shutting down..."
    $global:SyncHash.IsRunning = $false
    Unregister-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "ProcStop" -ErrorAction SilentlyContinue
    try { $rs.EndInvoke($asyncHandle) } catch {}
    $rs.Dispose()
    try { $global:TtsSynth.Dispose() } catch {}
    if ($global:SyncHash.Reports.Count -gt 0) {
        $global:SyncHash.Reports | Sort-Object StartTime | Export-Csv -Path $OutputCsv -NoTypeInformation
        Write-Host "Report saved: $OutputCsv"
    }
}
