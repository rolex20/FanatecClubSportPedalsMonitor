<#
.SYNOPSIS
  Process monitor for "newly launched" processes. Samples CPU/mem/IO while running and reports when they stop.
  Designed to be run elevated (Administrator) on Windows 11.

.KEY FIXES
  - Never treat AccessDenied like "process ended" (prevents empty reports for SYSTEM/protected processes).
  - Uses Win32_PerfFormattedData_PerfProc_Process by PID (more reliable for SYSTEM processes).
  - IO totals: prefer Win32_Process transfer counts; if blocked, integrate bytes/sec over time.

.FLAGS ADDED TO REPORT
  - Owner / OwnerSid / SessionId
  - IsSystemAccount / IsServiceAccount / IsSession0
  - IsWindowsPath / IsTiWorker
  - Visibility (Full | WmiOnly | None)
  - MetricSource (WmiPerf | None)
  - IoTotalsSource (TransferCounts | IntegratedBps | None)
  - AccessDeniedCount, SampleCount

.USAGE
  PowerShell (Admin):
    .\ProcessMon.ps1
    # Stop with Ctrl+C

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

function Safe-ToBool($v) { return [bool]($v -eq $true) }

function Get-OwnerInfoByPid([int]$PidVal) {
  # Returns: @{ Owner="DOMAIN\User" or ""; OwnerSid="S-..." or ""; SessionId=int or -1; Path=""; CommandLine="" }
  $out = @{
    Owner      = ""
    OwnerSid   = ""
    SessionId  = -1
    Path       = ""
    CommandLine= ""
  }

  try {
    $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PidVal" -ErrorAction Stop

    # SessionId exists on Win32_Process
    if ($null -ne $p.SessionId) { $out.SessionId = [int]$p.SessionId }

    if ($null -ne $p.ExecutablePath) { $out.Path = [string]$p.ExecutablePath }
    if ($null -ne $p.CommandLine)    { $out.CommandLine = [string]$p.CommandLine }

    try {
      $sidRes = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
      if ($sidRes -and $sidRes.Sid) { $out.OwnerSid = [string]$sidRes.Sid }
    } catch { }

    try {
      $ownRes = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
      if ($ownRes -and $ownRes.User) {
        $dom = if ($ownRes.Domain) { $ownRes.Domain } else { "" }
        $out.Owner = if ($dom) { "$dom\$($ownRes.User)" } else { "$($ownRes.User)" }
      }
    } catch { }
  } catch {
    # Access denied or not found: leave blanks
  }

  return $out
}

function Get-ParentInfo([int]$ParentPid) {
  # Best effort parent name lookup
  try {
    $pp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ParentPid" -ErrorAction Stop
    return @{ ParentName = [string]$pp.Name }
  } catch {
    return @{ ParentName = "" }
  }
}

function Test-ProcessStillRunning([int]$PidVal) {
  # Critical: treat AccessDenied as "still running" (prevents premature cleanup)
  try {
    Get-Process -Id $PidVal -ErrorAction Stop | Out-Null
    return $true
  } catch {
    $ex = $_.Exception
    if ($ex -is [System.ComponentModel.Win32Exception] -and $ex.NativeErrorCode -eq 5) {
      return $true # Access denied => process likely still there
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

  $sid = $own.OwnerSid
  $isSystem  = ($sid -eq "S-1-5-18") # LocalSystem
  $isLocalSv = ($sid -eq "S-1-5-19") # LocalService
  $isNetSv   = ($sid -eq "S-1-5-20") # NetworkService
  $isService = ($isSystem -or $isLocalSv -or $isNetSv)

  $path = $own.Path
  $isWinPath = $false
  if ($path) {
    try {
      $win = [IO.Path]::GetFullPath($env:WINDIR)
      $full = [IO.Path]::GetFullPath($path)
      $isWinPath = $full.StartsWith($win, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { $isWinPath = $false }
  }

  $isTiWorker = ($NameVal -ieq "tiworker.exe")

  # State object
  return [pscustomobject]@{
    Pid              = $PidVal
    Name             = $NameVal
    ParentPid        = $ParentPidVal
    ParentName       = $pp.ParentName

    StartTime        = (Get-Date)
    StopTime         = $null

    Owner            = $own.Owner
    OwnerSid         = $own.OwnerSid
    SessionId        = $own.SessionId
    Path             = $own.Path
    CommandLine      = $own.CommandLine

    IsSystemAccount  = $isSystem
    IsServiceAccount = $isService
    IsSession0       = ($own.SessionId -eq 0)
    IsWindowsPath    = $isWinPath
    IsTiWorker       = $isTiWorker

    # Sampling stats
    SampleCount      = 0
    AccessDeniedCount= 0

    WmiPerfSuccessCount = 0
    WmiPerfFailCount    = 0

    CpuAvgSum        = 0.0
    CpuPeak          = 0.0
    WsAvgSum         = 0.0
    WsPeak           = 0.0
    PvAvgSum         = 0.0
    PvPeak           = 0.0
    ReadBpsSum       = 0.0
    ReadBpsPeak      = 0.0
    WriteBpsSum      = 0.0
    WriteBpsPeak     = 0.0

    TotalReadBytes   = 0.0
    TotalWriteBytes  = 0.0
    LastReadBytes    = -1.0
    LastWriteBytes   = -1.0

    LastSampleTime   = (Get-Date)

    # Data quality flags
    MetricSource     = "None"   # WmiPerf | None
    IoTotalsSource   = "None"   # TransferCounts | IntegratedBps | None
    Visibility       = "None"   # Full | WmiOnly | None
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

  # Determine visibility
  $metricSource = if ($st.WmiPerfSuccessCount -gt 0) { "WmiPerf" } else { "None" }
  $vis = "None"
  if ($metricSource -eq "WmiPerf") {
    # "Full" if we also got owner/path/cmdline etc.
    if ($st.Owner -or $st.Path -or $st.CommandLine) { $vis = "Full" } else { $vis = "WmiOnly" }
  }

  $st.MetricSource = $metricSource
  $st.Visibility   = $vis

  # Friendly sizes
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

    # Classification flags
    IsSystemAccount   = $st.IsSystemAccount
    IsServiceAccount  = $st.IsServiceAccount
    IsSession0        = $st.IsSession0
    IsWindowsPath     = $st.IsWindowsPath
    IsTiWorker        = $st.IsTiWorker

    # Data quality flags
    Visibility        = $st.Visibility
    MetricSource      = $st.MetricSource
    IoTotalsSource    = $st.IoTotalsSource
    SampleCount       = $st.SampleCount
    AccessDeniedCount = $st.AccessDeniedCount
    WmiPerfSuccess    = $st.WmiPerfSuccessCount
    WmiPerfFail       = $st.WmiPerfFailCount

    # Metrics
    CpuAvgPct      = [math]::Round($cpuAvg, 3)
    CpuPeakPct     = [math]::Round($st.CpuPeak, 3)

    WorkingSetAvgMB= & $toMB $wsAvg
    WorkingSetPeakMB= & $toMB $st.WsPeak

    PrivateBytesAvgMB= & $toMB $pvAvg
    PrivateBytesPeakMB= & $toMB $st.PvPeak

    ReadBpsAvg     = [math]::Round($rbAvg, 3)
    ReadBpsPeak    = [math]::Round($st.ReadBpsPeak, 3)
    WriteBpsAvg    = [math]::Round($wbAvg, 3)
    WriteBpsPeak   = [math]::Round($st.WriteBpsPeak, 3)

    TotalReadMB    = & $toMB $st.TotalReadBytes
    TotalWriteMB   = & $toMB $st.TotalWriteBytes
  }
}

function Stop-And-Report([int]$PidVal) {
  if (-not $global:ProcState.ContainsKey($PidVal)) { return }

  $st = $global:ProcState[$PidVal]
  $st.StopTime = Get-Date
  $row = Finalize-ReportRow -st $st

  [void]$global:Reports.Add($row)
  $global:ProcState.Remove($PidVal) | Out-Null

  # Console output
  Write-Info ("STOP  {0,6}  {1,-22}  Dur={2,6}s  CPUavg={3,6}%  WSpeak={4,8}MB  IO(R/W)={5,6}/{6,6}MB  Flags=[{7},{8},{9}]" -f `
    $row.Pid, $row.Name, $row.DurationSec, $row.CpuAvgPct, $row.WorkingSetPeakMB, $row.TotalReadMB, $row.TotalWriteMB, `
    $row.Visibility, $row.MetricSource, $row.IoTotalsSource)
}

# -----------------------------
# Sampling Timer
# -----------------------------
$logical = [Environment]::ProcessorCount

$timer = New-Object System.Timers.Timer
$timer.Interval = [math]::Max(100, $SampleIntervalMs)
$timer.AutoReset = $true

$timerEvent = Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier "ProcSampleTimer" -Action {
  try {
    # Snapshot keys to avoid iterator issues on synchronized hashtable
    $pids = @($global:ProcState.Keys)

    foreach ($pidLocal in $pids) {

      # If not running AND we somehow missed the stop event, report it here.
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

        # PercentProcessorTime can exceed 100 on multi-core; normalize like Task Manager "per process %"
        $cpu = [math]::Max(0.0, ($snap.CpuRawPct / [double]$logical))
        $ws  = [math]::Max(0.0, $snap.WorkingSet)
        $pv  = [math]::Max(0.0, $snap.PrivateBytes)
        $rb  = [math]::Max(0.0, $snap.ReadBps)
        $wb  = [math]::Max(0.0, $snap.WriteBps)

        $st.CpuAvgSum += $cpu; if ($cpu -gt $st.CpuPeak) { $st.CpuPeak = $cpu }
        $st.WsAvgSum  += $ws;  if ($ws  -gt $st.WsPeak)  { $st.WsPeak  = $ws }
        $st.PvAvgSum  += $pv;  if ($pv  -gt $st.PvPeak)  { $st.PvPeak  = $pv }
        $st.ReadBpsSum += $rb; if ($rb -gt $st.ReadBpsPeak) { $st.ReadBpsPeak = $rb }
        $st.WriteBpsSum += $wb; if ($wb -gt $st.WriteBpsPeak) { $st.WriteBpsPeak = $wb }

        # ---- IO totals: prefer Win32_Process transfer counts; else integrate Bps ----
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
            $st.IoTotalsSource = "TransferCounts"
          }
        } catch {
          # If access denied, count it (but DON'T treat as exited)
          $ex = $_.Exception
          if ($ex -is [System.UnauthorizedAccessException] -or
              ($ex -is [System.ComponentModel.Win32Exception] -and $ex.NativeErrorCode -eq 5)) {
            $st.AccessDeniedCount++
          }
        }

        if (-not $gotTransfer) {
          # Integrate IO Bps into totals
          if ($rb -gt 0) { $st.TotalReadBytes  += ($rb * $dt) }
          if ($wb -gt 0) { $st.TotalWriteBytes += ($wb * $dt) }
          if ($st.IoTotalsSource -ne "TransferCounts") { $st.IoTotalsSource = "IntegratedBps" }
        }

        # Update visibility hints
        if ($st.MetricSource -eq "None") { $st.MetricSource = "WmiPerf" }

      } else {
        $st.WmiPerfFailCount++
      }

      $global:ProcState[$pidLocal] = $st
    }
  } catch {
    # Keep sampler alive
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

    # Track only if not already tracked
    if (-not $global:ProcState.ContainsKey($pid)) {
      $st = New-ProcState -PidVal $pid -NameVal $name -ParentPidVal $ppid
      $global:ProcState[$pid] = $st

      $ownerDisp = if ([string]::IsNullOrWhiteSpace($st.Owner)) { "<unknown>" } else { $st.Owner }
      
      Write-Info ("START {0,6}  {1,-22}  Parent={2,6}  Owner={3}  Sess={4}  Flags=[Sys={5},Svc={6},S0={7},Win={8},TiW={9}]" -f `
        $pid, $name, $ppid, $ownerDisp, $st.SessionId, `
        $st.IsSystemAccount, $st.IsServiceAccount, $st.IsSession0, $st.IsWindowsPath, $st.IsTiWorker)

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
  Write-Warning "Not running as Administrator. SYSTEM processes may have reduced visibility. Re-run elevated for best results."
}

if (-not $OutputCsv) {
  $OutputCsv = Join-Path -Path $PSScriptRoot -ChildPath ("ProcessMon_Report_{0}.csv" -f (Get-TimestampString))
}

Write-Info "Monitoring NEW process starts/stops…"
Write-Info ("SampleIntervalMs={0}  OutputCsv={1}" -f $SampleIntervalMs, $OutputCsv)
Write-Info "Press Ctrl+C to stop."

$timer.Start()

try {
  while ($true) { Start-Sleep -Seconds 1 }
}
finally {
  Write-Info "Stopping…"

  try { $timer.Stop() } catch {}
  try { Unregister-Event -SourceIdentifier "ProcSampleTimer" -ErrorAction SilentlyContinue } catch {}
  try { Unregister-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue } catch {}
  try { Unregister-Event -SourceIdentifier "ProcStop"  -ErrorAction SilentlyContinue } catch {}
  try { Remove-Event -SourceIdentifier "ProcSampleTimer" -ErrorAction SilentlyContinue } catch {}
  try { Remove-Event -SourceIdentifier "ProcStart" -ErrorAction SilentlyContinue } catch {}
  try { Remove-Event -SourceIdentifier "ProcStop"  -ErrorAction SilentlyContinue } catch {}
  try { $timer.Dispose() } catch {}

  # Flush any remaining tracked processes (best-effort)
  foreach ($pid in @($global:ProcState.Keys)) {
    Stop-And-Report -PidVal $pid
  }

  # Export report
  if ($global:Reports.Count -gt 0) {
    $global:Reports | Sort-Object StartTime | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutputCsv
    Write-Info ("Saved report: {0} (rows: {1})" -f $OutputCsv, $global:Reports.Count)
  } else {
    Write-Info "No processes captured."
  }
}
