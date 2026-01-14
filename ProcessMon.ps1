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
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
  return (Get-Date).ToString("yyyyMMdd_HHmmss")
}

function Format-OneLine([string]$Text, [int]$MaxLen = 220) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "<none>" }
  $s = $Text -replace "(`r`n|`n|`r)", " "
  $s = $s -replace "\s+", " "
  $s = $s.Trim()
  if ($s.Length -gt $MaxLen) { return $s.Substring(0, $MaxLen) + "..." }
  return $s
}

function Get-OwnerInfoByPid([int]$PidVal) {
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
    $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PidVal" -ErrorAction Stop
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
        $dom = if ($ownRes.Domain) { [string]$ownRes.Domain } else { "" }
        $usr = [string]$ownRes.User
        $out.Owner = if ($dom) { "$dom\$usr" } else { $usr }
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

function Get-ParentInfo([int]$ParentPid) {
  try {
    $pp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ParentPid" -ErrorAction Stop
    return @{ ParentName = [string]$pp.Name }
  } catch {
    return @{ ParentName = "" }
  }
}

function Test-ProcessStillRunning([int]$PidVal) {
  # Critical: treat AccessDenied as "still running" (prevents premature cleanup for SYSTEM/protected processes)
  try {
    Get-Process -Id $PidVal -ErrorAction Stop | Out-Null
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

function Get-WmiPerfSnapshot([int]$PidVal) {
  # Returns perf snapshot by PID or $null
  try {
    $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
                         -Filter "IDProcess=$PidVal" -ErrorAction Stop
    if (-not $p) { return $null }
    return [pscustomobject]@{
      CpuRawPct    = [double]$p.PercentProcessorTime
      WorkingSet   = [double]$p.WorkingSet
      PrivateBytes = [double]$p.PrivateBytes
      ReadBps      = [double]$p.IOReadBytesPerSec
      WriteBps     = [double]$p.IOWriteBytesPerSec
    }
  } catch {
    return $null
  }
}

function New-ProcState([int]$PidVal, [string]$NameVal, [int]$ParentPidVal) {
  $own = Get-OwnerInfoByPid -PidVal $PidVal
  $pp  = Get-ParentInfo -ParentPid $ParentPidVal

  $sid = [string]$own.OwnerSid
  $isSystem  = ($sid -eq "S-1-5-18") # LocalSystem
  $isLocalSv = ($sid -eq "S-1-5-19") # LocalService
  $isNetSv   = ($sid -eq "S-1-5-20") # NetworkService
  $isService = ($isSystem -or $isLocalSv -or $isNetSv)

  $path = [string]$own.Path
  $isWinPath = $false
  if ($path) {
    try {
      $win  = [IO.Path]::GetFullPath($env:WINDIR)
      $full = [IO.Path]::GetFullPath($path)
      $isWinPath = $full.StartsWith($win, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { $isWinPath = $false }
  }

  return [pscustomobject]@{
    Pid               = $PidVal
    Name              = $NameVal
    ParentPid         = $ParentPidVal
    ParentName        = [string]$pp.ParentName

    StartTime         = (Get-Date)
    StopTime          = $null

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
    MetaAccessDeniedCount = (if ($own.MetaAccessDenied) { 1 } else { 0 })

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
  $stop = if ($st.StopTime) { $st.StopTime } else { Get-Date }
  $dur  = ($stop - $st.StartTime).TotalSeconds
  if ($dur -lt 0) { $dur = 0 }

  $samples = [math]::Max(1, [int]$st.SampleCount)

  $cpuAvg = $st.CpuAvgSum / $samples
  $wsAvg  = $st.WsAvgSum  / $samples
  $pvAvg  = $st.PvAvgSum  / $samples
  $rbAvg  = $st.ReadBpsSum / $samples
  $wbAvg  = $st.WriteBpsSum / $samples

  # Determine MetricMode
  $metricMode = if ($st.WmiPerfSuccessCount -gt 0) { "WmiPerfByPid" } else { "None" }

  # Determine Visibility
  # "Full" means metrics + some metadata; "WmiOnly" means metrics but metadata effectively missing; "None" means no metrics.
  $hasMeta =
    (-not [string]::IsNullOrWhiteSpace($st.Owner)) -or
    (-not [string]::IsNullOrWhiteSpace($st.OwnerSid)) -or
    ($st.SessionId -ge 0) -or
    (-not [string]::IsNullOrWhiteSpace($st.Path)) -or
    (-not [string]::IsNullOrWhiteSpace($st.CommandLine)) -or
    (-not [string]::IsNullOrWhiteSpace($st.ParentName))

  $visibility = "None"
  if ($metricMode -ne "None") {
    $visibility = if ($hasMeta) { "Full" } else { "WmiOnly" }
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

  $toMB = { param($b) if ($b -le 0) { 0 } else { [math]::Round(($b / 1MB), 2) } }

  return [pscustomobject]@{
    Pid            = $st.Pid
    Name           = $st.Name
    ParentPid      = $st.ParentPid
    ParentName     = $st.ParentName

    StartTime      = $st.StartTime
    StopTime       = $stop
    DurationSec    = [math]::Round($dur, 3)

    Owner          = $st.Owner
    OwnerSid       = $st.OwnerSid
    SessionId      = $st.SessionId
    Path           = $st.Path
    CommandLine    = $st.CommandLine

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

    WorkingSetAvgMB   = & $toMB $wsAvg
    WorkingSetPeakMB  = & $toMB $st.WsPeak

    PrivateBytesAvgMB = & $toMB $pvAvg
    PrivateBytesPeakMB= & $toMB $st.PvPeak

    ReadBpsAvg        = [math]::Round($rbAvg, 3)
    ReadBpsPeak       = [math]::Round($st.ReadBpsPeak, 3)
    WriteBpsAvg       = [math]::Round($wbAvg, 3)
    WriteBpsPeak      = [math]::Round($st.WriteBpsPeak, 3)

    TotalReadMB       = & $toMB $st.TotalReadBytes
    TotalWriteMB      = & $toMB $st.TotalWriteBytes
  }
}

function Stop-And-Report([int]$PidVal) {
  if (-not $global:ProcState.ContainsKey($PidVal)) { return }

  $st = $global:ProcState[$PidVal]
  $st.StopTime = Get-Date

  $row = Finalize-ReportRow -st $st

  [void]$global:Reports.Add($row)
  $global:ProcState.Remove($PidVal) | Out-Null

  $cmdDisp = Format-OneLine -Text $row.CommandLine -MaxLen 220
  $pnDisp  = if ([string]::IsNullOrWhiteSpace($row.ParentName)) { "<unknown>" } else { $row.ParentName }

  Write-Info ("STOP  {0,6}  {1,-22}  Parent={2,-18}  Dur={3,6}s  CPUavg={4,6}%  WSpeak={5,8}MB  IO(R/W)={6,6}/{7,6}MB  Flags=[AR={8},Vis={9},Met={10},Tot={11}]  Cmd={12}" -f `
    $row.Pid, $row.Name, $pnDisp, $row.DurationSec, $row.CpuAvgPct, $row.WorkingSetPeakMB, $row.TotalReadMB, $row.TotalWriteMB, `
    $row.AccessRestricted, $row.Visibility, $row.MetricMode, $row.TotalsMode, $cmdDisp)
}

# -----------------------------
# Sampling Timer
# -----------------------------
$timer = New-Object System.Timers.Timer
$timer.Interval = [math]::Max(100, $SampleIntervalMs)
$timer.AutoReset = $true

$timerEvent = Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier "ProcSampleTimer" -Action {
  try {
    $pids = @($global:ProcState.Keys)

    foreach ($pidLocal in $pids) {

      if (-not (Test-ProcessStillRunning -PidVal $pidLocal)) {
        Stop-And-Report -PidVal $pidLocal
        continue
      }

      $st = $global:ProcState[$pidLocal]
      if (-not $st) { continue }

      $now = Get-Date
      $dt = [math]::Max(0.001, ($now - $st.LastSampleTime).TotalSeconds)
      $st.LastSampleTime = $now

      $st.SampleCount++

      # ---- Metrics via WMI Perf by PID ----
      $snap = Get-WmiPerfSnapshot -PidVal $pidLocal
      if ($snap) {
        $st.WmiPerfSuccessCount++

        # Normalize raw percent (can exceed 100 on multi-core)
        $cpu = [math]::Max(0.0, ($snap.CpuRawPct / [double]$script:LogicalProcessorCount))
        $ws  = [math]::Max(0.0, $snap.WorkingSet)
        $pv  = [math]::Max(0.0, $snap.PrivateBytes)
        $rb  = [math]::Max(0.0, $snap.ReadBps)
        $wb  = [math]::Max(0.0, $snap.WriteBps)

        $st.CpuAvgSum += $cpu; if ($cpu -gt $st.CpuPeak) { $st.CpuPeak = $cpu }
        $st.WsAvgSum  += $ws;  if ($ws  -gt $st.WsPeak)  { $st.WsPeak  = $ws }
        $st.PvAvgSum  += $pv;  if ($pv  -gt $st.PvPeak)  { $st.PvPeak  = $pv }
        $st.ReadBpsSum += $rb; if ($rb -gt $st.ReadBpsPeak) { $st.ReadBpsPeak = $rb }
        $st.WriteBpsSum += $wb; if ($wb -gt $st.WriteBpsPeak) { $st.WriteBpsPeak = $wb }

        $st.MetricMode = "WmiPerfByPid"

        # ---- IO totals: exact transfer counts if readable; else integrate Bps ----
        $gotTransfer = $false
        try {
          $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$pidLocal" -ErrorAction Stop
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

      $global:ProcState[$pidLocal] = $st
    }
  } catch {
    # Keep sampler alive even if one PID misbehaves
  }
}

# -----------------------------
# WMI Start/Stop Event Watchers
# -----------------------------
$startEvent = Register-WmiEvent -Namespace "root\cimv2" -Class "Win32_ProcessStartTrace" -SourceIdentifier "ProcStart" -Action {
  try {
    $pid  = [int]$Event.SourceEventArgs.NewEvent.ProcessID
    $ppid = [int]$Event.SourceEventArgs.NewEvent.ParentProcessID
    $name = [string]$Event.SourceEventArgs.NewEvent.ProcessName

    if (-not $global:ProcState.ContainsKey($pid)) {
      $st = New-ProcState -PidVal $pid -NameVal $name -ParentPidVal $ppid
      $global:ProcState[$pid] = $st

      $ownerDisp = if ([string]::IsNullOrWhiteSpace($st.Owner)) { "<unknown>" } else { $st.Owner }
      $pnDisp    = if ([string]::IsNullOrWhiteSpace($st.ParentName)) { "<unknown>" } else { $st.ParentName }
      $cmdDisp   = Format-OneLine -Text $st.CommandLine -MaxLen 220

      Write-Info ("START {0,6}  {1,-22}  Parent={2,6}({3,-18})  Owner={4,-25}  Sess={5,2}  Cmd={6}" -f `
        $pid, $name, $ppid, $pnDisp, $ownerDisp, $st.SessionId, $cmdDisp)
    }
  } catch { }
}

$stopEvent = Register-WmiEvent -Namespace "root\cimv2" -Class "Win32_ProcessStopTrace" -SourceIdentifier "ProcStop" -Action {
  try {
    $pid = [int]$Event.SourceEventArgs.NewEvent.ProcessID
    Stop-And-Report -PidVal $pid
  } catch { }
}

# -----------------------------
# Start
# -----------------------------
if (-not (Test-IsAdmin)) {
  Write-Warning "Not running as Administrator. SYSTEM/protected processes may have reduced visibility. Re-run elevated for best results."
}

if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
  $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
  $OutputCsv = Join-Path -Path $base -ChildPath ("ProcessMon_Report_{0}.csv" -f (Get-TimestampString))
}

Write-Info "Monitoring NEW process starts/stops..."
Write-Info ("SampleIntervalMs={0}  OutputCsv={1}" -f $SampleIntervalMs, $OutputCsv)
Write-Info "Press Ctrl+C to stop."

$timer.Start()

try {
  while ($true) { Start-Sleep -Seconds 1 }
}
finally {
  Write-Info "Stopping..."

  try { $timer.Stop() } catch {}
  try { Unregister-Event -SourceIdentifier "ProcSampleTimer" -ErrorAction SilentlyContinue } catch {}
  try { Unregister-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue } catch {}
  try { Unregister-Event -SourceIdentifier "ProcStop"  -ErrorAction SilentlyContinue } catch {}
  try { Remove-Event -SourceIdentifier "ProcSampleTimer" -ErrorAction SilentlyContinue } catch {}
  try { Remove-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue } catch {}
  try { Remove-Event -SourceIdentifier "ProcStop"  -ErrorAction SilentlyContinue } catch {}
  try { $timer.Dispose() } catch {}

  foreach ($pid in @($global:ProcState.Keys)) {
    Stop-And-Report -PidVal $pid
  }

  if ($global:Reports.Count -gt 0) {
    $global:Reports | Sort-Object StartTime | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutputCsv
    Write-Info ("Saved report: {0} (rows: {1})" -f $OutputCsv, $global:Reports.Count)
  } else {
    Write-Info "No processes captured."
  }
}
