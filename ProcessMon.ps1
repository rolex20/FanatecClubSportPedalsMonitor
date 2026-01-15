<#
.SYNOPSIS
  Process monitor for newly launched processes. Samples CPU/mem/IO while running and reports when they stop.
  Designed for Windows 11 + Windows PowerShell 5.1. Run elevated for best visibility.

.ARCHITECTURE (components)
  1) Start/Stop event ingestion:
       - Win32_ProcessStartTrace -> creates per-PID state in $global:ProcState
       - Win32_ProcessStopTrace  -> finalizes report row and removes state
  2) Periodic sampler:
       - System.Timers.Timer -> samples each tracked PID every SampleIntervalMs
  3) Report builder:
       - Stop-And-Report() -> converts state to a single report row object
  4) Sinks:
       - Console (Write-Info)
       - CSV (Export-Csv at shutdown)
       - Per-process JSON files

.KEY FIXES FOR SYSTEM/RESTRICTED PROCESSES
  - Liveness check distinguishes "Access denied" from "process ended" so state isn't deleted prematurely.
  - Metrics gathered via Win32_PerfFormattedData_PerfProc_Process (by PID), which is often readable even for SYSTEM processes.
  - IO totals:
      * Prefer exact Win32_Process ReadTransferCount/WriteTransferCount deltas when readable
      * Otherwise estimate totals by integrating IOReadBytesPerSec/IOWriteBytesPerSec over time

.REPORT FLAGS (what they mean)
  Visibility (string): "Full" | "WmiOnly" | "None"
    - "Full"   : We captured at least one metrics sample AND we also captured some metadata (owner/path/cmdline/session/parent).
    - "WmiOnly": We captured metrics samples, but metadata was effectively unavailable (likely restricted/protected or blocked).
    - "None"   : We captured no metrics samples (often extremely short-lived process or perf visibility unavailable).

  MetricMode (string): "WmiPerfByPid" | "None"
    - "WmiPerfByPid": At least one successful sample came from Win32_PerfFormattedData_PerfProc_Process filtered by IDProcess.
    - "None"        : No successful metric samples were collected.

  TotalsMode (string): "TransferCounts" | "IntegratedBps" | "None"
    - "TransferCounts": Exact IO totals computed from Win32_Process ReadTransferCount/WriteTransferCount deltas.
    - "IntegratedBps" : Approx IO totals computed by integrating IOReadBytesPerSec/IOWriteBytesPerSec over time.
    - "None"          : No IO totals collected (usually when no samples were collected at all).

  AccessRestricted (bool):
    - True if we observed any access-denied while querying the process OR we had to degrade (missing metadata, missing metrics, or IO totals estimated).
    - In other words: "we could not fully observe this process with the standard, high-fidelity path."

.NOTES
  - This script intentionally does NOT attempt to fix the potential duplicate-report race (sampler vs stop event).
    It is rare, but still possible under heavy timing contention.

.USAGE
  powershell.exe (Admin):
    .\ProcessMon.ps1
  Optional:
    .\ProcessMon.ps1 -SampleIntervalMs 500 -OutputCsv "C:\temp\procmon_report.csv"
#>

[CmdletBinding()]
param(
  [int]$SampleIntervalMs = 1000,
  [string]$OutputCsv = "",
  [switch]$Quiet = $false,
  [string[]] $ExcludeNames = @( "sample1.exe", "msedge.exe",
    "conhost.exe","dllhost.exe","sihost.exe","RuntimeBroker.exe"
  )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- TTS SETUP ----------------------------------------------------
Add-Type -AssemblyName System.Speech
$global:TtsLock = New-Object object
$global:TtsSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$global:TtsSynth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)
$global:TtsSynth.Volume = 100
$global:TtsSynth.Rate   = 0

function Get-ScriptArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$FullString,

        [Parameter(Mandatory=$true)]
        [string]$FileName
    )

    try {
        # Perform a case-insensitive search for the filename
        $Index = $FullString.IndexOf($FileName, 0, [System.StringComparison]::OrdinalIgnoreCase)

        # If Index is -1, the filename wasn't found in the string
        if ($Index -eq -1) {
            #throw "The filename '$FileName' was not found within the provided path string."
			return $FullString
        }

        # Calculate where the arguments start (End of filename)
        $Cutoff = $Index + $FileName.Length
        
        # Substring from cutoff to the end, then Trim leading/trailing whitespace
        $Arguments = $FullString.Substring($Cutoff).Trim()

        return $Arguments
    }
    catch {
        # Capture the error details
        $Line = $_.InvocationInfo.ScriptLineNumber
        $Msg  = $_.Exception.Message
        
        Write-Error "Error in Get-ScriptArguments at line $Line $Msg"
        return $null
    }
}

function Speak-ProcessEvent {
  param(
    [Parameter(Mandatory=$true)]
    [string] $EventType,
    [Parameter(Mandatory=$true)]
    [string] $ProcessName
  )
  $cleanName = $ProcessName -replace '\.exe$', ''  # Remove .exe suffix
  try {
    [System.Threading.Monitor]::Enter($global:TtsLock)
    try {
      [void]$global:TtsSynth.SpeakAsync("$EventType $cleanName")
    } finally {
      [System.Threading.Monitor]::Exit($global:TtsLock)
    }
  } catch {}
}

function Safe-Name([string]$s) {
  return ($s -replace '[\\/:*?"<>|]', '_')
}

# -----------------------------
# Globals (thread-safe)
# -----------------------------
$global:ProcState = [hashtable]::Synchronized(@{})
$global:Reports   = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$global:StartTime = Get-Date

$script:LogicalProcessorCount = [Environment]::ProcessorCount

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Write-Info([string]$Msg) {
  if (-not $Quiet) { Write-Host $Msg }
}

function Get-TimestampString {
  return (Get-Date).ToString("yyyyMMdd-HHmmss")
}

function Format-OneLine([string]$Text, [int]$MaxLen = 220) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "<none>" }
  $s = $Text -replace "(`r`n|`n|`r)", " "
  $s = $s -replace "\s+", " "
  $s = $s.Trim()
  if ($s.Length -gt $MaxLen) { return $s.Substring(0, $MaxLen) + "..." }
  return $s
}

function Get-OwnerInfoByPid([int]$procIdVal) {
  # Returns:
  #   Owner, OwnerSid, SessionId, Path, CommandLine
  #   MetaReadOk: Win32_Process object was readable
  #   MetaAccessDenied: we believe failure was access-related (best effort)
  $out = @{
    Owner          = ""
    OwnerSid       = ""
    SessionId      = -1
    Path           = ""
    CommandLine    = ""
    MetaReadOk     = $false
    MetaAccessDenied = $false
  }

  try {
    $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$procIdVal" -ErrorAction Stop
    $out.MetaReadOk = $true

    if ($null -ne $p.SessionId)      { $out.SessionId   = [int]$p.SessionId }
    if ($null -ne $p.ExecutablePath) { $out.Path        = [string]$p.ExecutablePath }
    if ($null -ne $p.CommandLine)    { $out.CommandLine = [string]$p.CommandLine }

    try {
      $sidRes = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
      if ($sidRes -and $sidRes.Sid) { $out.OwnerSid = [string]$sidRes.Sid }
    } catch { }

    try {
      $ownRes = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
      if ($ownRes -and $ownRes.User) {
        $dom = ""
        if ($ownRes.Domain) { $dom = [string]$ownRes.Domain }
        $usr = [string]$ownRes.User
        if ($dom) {
          $out.Owner = "$dom\$usr"
        } else {
          $out.Owner = $usr
        }
      }
    } catch { }

  } catch {
    $ex = $_.Exception
    if ($ex -is [System.UnauthorizedAccessException]) {
      $out.MetaAccessDenied = $true
    } elseif ($ex -is [System.ComponentModel.Win32Exception]) {
      # 5 = Access denied
      if ($ex.NativeErrorCode -eq 5) { $out.MetaAccessDenied = $true }
    }
  }

  return $out
}

function Get-ParentInfo([int]$parentProcId) {
  try {
    $pp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$parentProcId" -ErrorAction Stop
    return @{ ParentName = [string]$pp.Name }
  } catch {
    return @{ ParentName = "" }
  }
}

function Test-ProcessStillRunning([int]$procIdVal) {
  # Critical: treat AccessDenied as "still running" (prevents premature cleanup for SYSTEM/protected processes)
  try {
    Get-Process -Id $procIdVal -ErrorAction Stop | Out-Null
    return $true
  } catch {
    $ex = $_.Exception
    if ($ex -is [System.ComponentModel.Win32Exception] -and $ex.NativeErrorCode -eq 5) {
      return $true
    }
    if ($ex -is [System.UnauthorizedAccessException]) {
      return $true
    }
    return $false
  }
}

function Get-WmiPerfSnapshot([int]$procIdVal) {
  # Returns perf snapshot by PID or $null
  try {
    $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
                         -Filter "IDProcess=$procIdVal" -ErrorAction Stop
    if (-not $p) { return $null }
    return [pscustomobject]@{
      CpuRawPct    = [double]$p.PercentProcessorTime
      WorkingSet   = [double]$p.WorkingSet
      PrivateBytes = [double]$p.PrivateBytes
      ReadBps      = [double]$p.IOReadBytesPersec
      WriteBps     = [double]$p.IOWriteBytesPersec
    }
  } catch {
    return $null
  }
}

function New-ProcState([int]$procIdVal, [string]$NameVal, [int]$parentProcId) {
  $own = Get-OwnerInfoByPid -procIdVal $procIdVal
  $pp  = Get-ParentInfo -parentProcId $parentProcId

  $sid = [string]$own.OwnerSid
  $isSystem = $false
  if ($sid -eq "S-1-5-18") { $isSystem = $true } # LocalSystem
  $isLocalSv = $false
  if ($sid -eq "S-1-5-19") { $isLocalSv = $true } # LocalService
  $isNetSv = $false
  if ($sid -eq "S-1-5-20") { $isNetSv = $true } # NetworkService
  $isService = $false
  if ($isSystem -or $isLocalSv -or $isNetSv) { $isService = $true }

  $path = [string]$own.Path
  $isWinPath = $false
  if ($path) {
    try {
      $win  = [IO.Path]::GetFullPath($env:WINDIR)
      $full = [IO.Path]::GetFullPath($path)
      $isWinPath = $full.StartsWith($win, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
      $isWinPath = $false
    }
  }

  $metaAccessDeniedCount = 0
  if ($own.MetaAccessDenied) { $metaAccessDeniedCount = 1 }

  return [pscustomobject]@{
    ProcId            = $procIdVal
    Name              = $NameVal
    ParentProcId      = $parentProcId
    ParentName        = [string]$pp.ParentName

    StartTime         = (Get-Date)
    StopTime          = $null
	TimeGenerated     = $null

    Owner             = [string]$own.Owner
    OwnerSid          = [string]$own.OwnerSid
    SessionId         = [int]$own.SessionId
    Path              = [string]$own.Path
    CommandLine       = [string]$own.CommandLine

    IsSystemAccount   = $isSystem
    IsServiceAccount  = $isService
    IsSession0        = ([int]$own.SessionId -eq 0)
    IsWindowsPath     = $isWinPath

    # Metadata visibility bookkeeping
    MetaReadOk            = [bool]$own.MetaReadOk
    MetaAccessDeniedCount = $metaAccessDeniedCount

    # Sampling stats
    SampleCount       = 0
    AccessDeniedCount = 0

    WmiPerfSuccessCount = 0
    WmiPerfFailCount    = 0

    CpuAvgSum         = 0.0
    CpuPeak           = 0.0
    WsAvgSum          = 0.0
    WsPeak            = 0.0
    PvAvgSum          = 0.0
    PvPeak            = 0.0
    ReadBpsSum        = 0.0
    ReadBpsPeak       = 0.0
    WriteBpsSum       = 0.0
    WriteBpsPeak      = 0.0

    TotalReadBytes    = 0.0
    TotalWriteBytes   = 0.0
    LastReadBytes     = -1.0
    LastWriteBytes    = -1.0

    LastSampleTime    = (Get-Date)

    # Report flags (computed/updated during sampling + finalize)
    AccessRestricted  = $false
    Visibility        = "None"      # Full | WmiOnly | None
    MetricMode        = "None"      # WmiPerfByPid | None
    TotalsMode        = "None"      # TransferCounts | IntegratedBps | None
  }
}

function Finalize-ReportRow($st) {
  $stop = $null
  if ($st.StopTime) {
    $stop = $st.StopTime
  } else {
    $stop = Get-Date
  }
  $dur  = ($stop - $st.StartTime).TotalSeconds
  if ($dur -lt 0) { $dur = 0 }

  $samples = [math]::Max(1, [int]$st.SampleCount)

  $cpuAvg = $st.CpuAvgSum / $samples
  $wsAvg  = $st.WsAvgSum  / $samples
  $pvAvg  = $st.PvAvgSum  / $samples
  $rbAvg  = $st.ReadBpsSum / $samples
  $wbAvg  = $st.WriteBpsSum / $samples

  # Determine MetricMode
  $metricMode = "None"
  if ($st.WmiPerfSuccessCount -gt 0) { $metricMode = "WmiPerfByPid" }

  # Determine Visibility
  # "Full" means metrics + some metadata; "WmiOnly" means metrics but metadata effectively missing; "None" means no metrics.
  $hasMeta = $false
  if (-not [string]::IsNullOrWhiteSpace($st.Owner)) { $hasMeta = $true }
  if (-not [string]::IsNullOrWhiteSpace($st.OwnerSid)) { $hasMeta = $true }
  if ($st.SessionId -ge 0) { $hasMeta = $true }
  if (-not [string]::IsNullOrWhiteSpace($st.Path)) { $hasMeta = $true }
  if (-not [string]::IsNullOrWhiteSpace($st.CommandLine)) { $hasMeta = $true }
  if (-not [string]::IsNullOrWhiteSpace($st.ParentName)) { $hasMeta = $true }

  $visibility = "None"
  if ($metricMode -ne "None") {
    if ($hasMeta) {
      $visibility = "Full"
    } else {
      $visibility = "WmiOnly"
    }
  }

  # Determine AccessRestricted
  # True if we hit access denied, or if we had to degrade/estimate, or if we couldn't fully observe the process.
  $accessRestricted = $false
  if (($st.AccessDeniedCount -gt 0) -or ($st.MetaAccessDeniedCount -gt 0)) { $accessRestricted = $true }
  if ($visibility -ne "Full") { $accessRestricted = $true }
  if ($st.TotalsMode -eq "IntegratedBps") { $accessRestricted = $true }
  if ($metricMode -eq "None") { $accessRestricted = $true }

  # Update state for consistency (not required, but useful if inspected)
  $st.MetricMode       = $metricMode
  $st.Visibility       = $visibility
  $st.AccessRestricted = $accessRestricted

  $toMB = {
    param($b)
    if ($b -le 0) {
      0
    } else {
      [math]::Round(($b / 1MB), 2)
    }
  }

  $report = [pscustomobject]@{
    ProcId            = $st.ProcId
    Name              = $st.Name
    ParentProcId      = $st.ParentProcId
    ParentName        = $st.ParentName

    StartTime         = $st.StartTime
    StopTime          = $stop
	TimeGenerated     = $st.TimeGenerated
    DurationSec       = [math]::Round($dur, 3)

    Owner             = $st.Owner
    OwnerSid          = $st.OwnerSid
    SessionId         = $st.SessionId
    Path              = $st.Path
    CommandLine       = $st.CommandLine

    # Classification helpers
    IsSystemAccount   = $st.IsSystemAccount
    IsServiceAccount  = $st.IsServiceAccount
    IsSession0        = $st.IsSession0
    IsWindowsPath     = $st.IsWindowsPath

    # REQUIRED flags
    AccessRestricted  = $st.AccessRestricted
    Visibility        = $st.Visibility
    MetricMode        = $st.MetricMode
    TotalsMode        = $st.TotalsMode

    # Debug counters (why something was "restricted"/degraded)
    SampleCount       = $st.SampleCount
    AccessDeniedCount = $st.AccessDeniedCount
    MetaAccessDeniedCount = $st.MetaAccessDeniedCount
    WmiPerfSuccess    = $st.WmiPerfSuccessCount
    WmiPerfFail       = $st.WmiPerfFailCount

    # Metrics
    CpuAvgPct         = [math]::Round($cpuAvg, 3)
    CpuPeakPct        = [math]::Round($st.CpuPeak, 3)

    WorkingSetAvgMB   = (& $toMB $wsAvg)
    WorkingSetPeakMB  = (& $toMB $st.WsPeak)

    PrivateBytesAvgMB = (& $toMB $pvAvg)
    PrivateBytesPeakMB= (& $toMB $st.PvPeak)

    ReadBpsAvg        = [math]::Round($rbAvg, 3)
    ReadBpsPeak       = [math]::Round($st.ReadBpsPeak, 3)
    WriteBpsAvg       = [math]::Round($wbAvg, 3)
    WriteBpsPeak      = [math]::Round($st.WriteBpsPeak, 3)

    TotalReadMB       = (& $toMB $st.TotalReadBytes)
    TotalWriteMB      = (& $toMB $st.TotalWriteBytes)
  }

  return $report
}

function Stop-And-Report([int]$procIdVal) {
  if (-not $global:ProcState.ContainsKey($procIdVal)) { return }

  $st = $global:ProcState[$procIdVal]
  $st.StopTime = Get-Date

  $row = Finalize-ReportRow -st $st


  # Per-process JSON
  $safe = Safe-Name $st.Name
  $stamp = $st.StartTime.ToString("yyyyMMdd-HHmmss")
  $jsonBase = Join-Path -Path (Split-Path $OutputCsv -Parent) -ChildPath "$safe-PID$($st.ProcId)-$stamp"
  $jsonFile = "$jsonBase.json"
  ($row | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $jsonFile -Encoding UTF8

  # Add JsonFile to report for printing
  Add-Member -InputObject $row -MemberType NoteProperty -Name JsonFile -Value $jsonFile

  [void]$global:Reports.Add($row)
  $global:ProcState.Remove($procIdVal) | Out-Null

  $cmdDisp = Format-OneLine -Text $row.CommandLine -MaxLen 220

  $pnDisp = "<unknown>"
  if (-not [string]::IsNullOrWhiteSpace($row.ParentName)) { $pnDisp = $row.ParentName }
  	
	$ArgumentsOnly = Get-ScriptArguments -FullString $cmdDisp -FileName $row.Name

  # Print full details with blank lines
  Write-Info ""
  Write-Info ("[STOP]  {0,6}  {1,-15}  Parent={2,-15}  Ran {3,6}s Owner={4,-15} CmdLine={5,-20}" -f `
  $row.ProcId, $row.Name, $pnDisp, $row.DurationSec, $row.Owner, $ArgumentsOnly)

  $f = $row | Format-List | Out-String
  Write-Info $f.Trim()
  Write-Info ""
  
  # Speak if tracked (not untracked)
  Speak-ProcessEvent -EventType "Stopped:" -ProcessName $st.Name  
}

# -----------------------------
# Sampling Timer
# -----------------------------
$timer = New-Object System.Timers.Timer
$timer.Interval = [math]::Max(100, $SampleIntervalMs)
$timer.AutoReset = $true

Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier "ProcSampleTimer" | Out-Null

# -----------------------------
# WMI Start/Stop Event Watchers
# -----------------------------
Register-WmiEvent -Namespace "root\cimv2" -Query "SELECT * FROM Win32_ProcessStartTrace" -SourceIdentifier "ProcStart" | Out-Null
Register-WmiEvent -Namespace "root\cimv2" -Query "SELECT * FROM Win32_ProcessStopTrace" -SourceIdentifier "ProcStop" | Out-Null

# -----------------------------
# Start
# -----------------------------
if (-not (Test-IsAdmin)) {
  Write-Warning "Not running as Administrator. SYSTEM/protected processes may have reduced visibility. Re-run elevated for best results."
}

if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
  $base = ""
  if ($PSScriptRoot) {
    $base = $PSScriptRoot
  } else {
    $base = (Get-Location).Path
  }
  $OutputCsv = Join-Path -Path $base -ChildPath ("ProcessMon_Report_{0}.csv" -f (Get-TimestampString))
}

Write-Info "Monitoring NEW process starts/stops..."
Write-Info ("SampleIntervalMs={0}  OutputCsv={1}" -f $SampleIntervalMs, $OutputCsv)
Write-Info "Press Ctrl+C to stop."

$timer.Start()

try {
  while ($true) { 
    $event = Wait-Event -Timeout 1

    if ($event) {
			#Write-Host "Members: "
			#$event | Format-List | Out-string		
			#Write-Host "---"
      try {
        if ($event.SourceIdentifier -eq "ProcStart") {

          $procId  = [int]$event.SourceEventArgs.NewEvent.ProcessID
          $parentProcId = [int]$event.SourceEventArgs.NewEvent.ParentProcessID
          $name = [string]$event.SourceEventArgs.NewEvent.ProcessName

          if ($ExcludeNames -contains $name) {
            Write-Info ("[START][excluded] {0} PID={1}" -f $name, $procId)
          } else {
            if (-not $global:ProcState.ContainsKey($procId)) {
              $st = New-ProcState -procIdVal $procId -NameVal $name -parentProcId $parentProcId
			  $st.TimeGenerated = $event.TimeGenerated
              $global:ProcState[$procId] = $st

              $ownerDisp = "<unknown>"
              if (-not [string]::IsNullOrWhiteSpace($st.Owner)) { $ownerDisp = $st.Owner }

              $pnDisp = "<unknown>"
              if (-not [string]::IsNullOrWhiteSpace($st.ParentName)) { $pnDisp = $st.ParentName }

              $cmdDisp   = Format-OneLine -Text $st.CommandLine -MaxLen 220
				
			  $ArgumentsOnly = Get-ScriptArguments -FullString $cmdDisp -FileName $name

              Write-Info ("[START] {0,6}  {1,-15}  Parent={2,6}({3,-15})  Owner={4,-25}  Cmd={5}" -f `
                $procId, $name, $parentProcId, $pnDisp, $ownerDisp, $ArgumentsOnly)

              Speak-ProcessEvent -EventType "Started:" -ProcessName $name
            }
          }
        } elseif ($event.SourceIdentifier -eq "ProcStop") {
          $procId = [int]$event.SourceEventArgs.NewEvent.ProcessID
          Stop-And-Report -procIdVal $procId
        } elseif ($event.SourceIdentifier -eq "ProcSampleTimer") {
          $procIds = @($global:ProcState.Keys)

          foreach ($procIdLocal in $procIds) {

            if (-not (Test-ProcessStillRunning -procIdVal $procIdLocal)) {
              Stop-And-Report -procIdVal $procIdLocal
              continue
            }

            $st = $global:ProcState[$procIdLocal]
            if (-not $st) { continue }

            $now = Get-Date
            $dt = [math]::Max(0.001, ($now - $st.LastSampleTime).TotalSeconds)
            $st.LastSampleTime = $now

            $st.SampleCount++

            # ---- Metrics via WMI Perf by PID ----
            $snap = Get-WmiPerfSnapshot -procIdVal $procIdLocal
            if ($snap) {
              $st.WmiPerfSuccessCount++

              # Normalize raw percent (can exceed 100 on multi-core)
              $cpu = [math]::Max(0.0, ($snap.CpuRawPct / [double]$script:LogicalProcessorCount))
              $ws  = [math]::Max(0.0, $snap.WorkingSet)
              $pv  = [math]::Max(0.0, $snap.PrivateBytes)
              $rb  = [math]::Max(0.0, $snap.ReadBps)
              $wb  = [math]::Max(0.0, $snap.WriteBps)

              $st.CpuAvgSum += $cpu
              if ($cpu -gt $st.CpuPeak) { $st.CpuPeak = $cpu }
              $st.WsAvgSum  += $ws
              if ($ws  -gt $st.WsPeak)  { $st.WsPeak  = $ws }
              $st.PvAvgSum  += $pv
              if ($pv  -gt $st.PvPeak)  { $st.PvPeak  = $pv }
              $st.ReadBpsSum += $rb
              if ($rb -gt $st.ReadBpsPeak) { $st.ReadBpsPeak = $rb }
              $st.WriteBpsSum += $wb
              if ($wb -gt $st.WriteBpsPeak) { $st.WriteBpsPeak = $wb }

              $st.MetricMode = "WmiPerfByPid"

              # ---- IO totals: exact transfer counts if readable; else integrate Bps ----
              $gotTransfer = $false
              try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$procIdLocal" -ErrorAction Stop
                if ($cim) {
                  $readBytes  = [double]$cim.ReadTransferCount
                  $writeBytes = [double]$cim.WriteTransferCount

                  if ($st.LastReadBytes -ge 0) {
                    $dR = $readBytes  - $st.LastReadBytes
                    $dW = $writeBytes - $st.LastWriteBytes
                    if ($dR -gt 0) { $st.TotalReadBytes  += $dR }
                    if ($dW -gt 0) { $st.TotalWriteBytes += $dW }
                  }
                  $st.LastReadBytes  = $readBytes
                  $st.LastWriteBytes = $writeBytes

                  $gotTransfer = $true
                  $st.TotalsMode = "TransferCounts"
                }
              } catch {
                $ex = $_.Exception
                if ($ex -is [System.UnauthorizedAccessException]) {
                  $st.AccessDeniedCount++
                } elseif ($ex -is [System.ComponentModel.Win32Exception]) {
                  if ($ex.NativeErrorCode -eq 5) { $st.AccessDeniedCount++ }
                }
              }

              if (-not $gotTransfer) {
                if ($rb -gt 0) { $st.TotalReadBytes  += ($rb * $dt) }
                if ($wb -gt 0) { $st.TotalWriteBytes += ($wb * $dt) }
                if ($st.TotalsMode -ne "TransferCounts") { $st.TotalsMode = "IntegratedBps" }
              }

            } else {
              $st.WmiPerfFailCount++
            }

            $global:ProcState[$procIdLocal] = $st
          }
        }
      } catch {
        Write-Info ("[EVENT][error] {0} on line number {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
      }

      if ($event.EventIdentifier) {
        Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
      }
    }
  }
}
finally {
  Write-Info "Stopping..."

  try { $timer.Stop() } catch {}
  try { $timer.Dispose() } catch {}
  Unregister-Event -SourceIdentifier "ProcSampleTimer" -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier "ProcStop"  -ErrorAction SilentlyContinue
  Remove-Event -SourceIdentifier "ProcSampleTimer" -ErrorAction SilentlyContinue
  Remove-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue
  Remove-Event -SourceIdentifier "ProcStop"  -ErrorAction SilentlyContinue
  try { $global:TtsSynth.Dispose() } catch {}

  foreach ($procId in @($global:ProcState.Keys)) {
    Stop-And-Report -procIdVal $procId
  }

  if ($global:Reports.Count -gt 0) {
    $global:Reports | Sort-Object StartTime | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutputCsv
    Write-Info ("Saved report: {0} (rows: {1})" -f $OutputCsv, $global:Reports.Count)
  } else {
    Write-Info "No processes captured."
  }
}