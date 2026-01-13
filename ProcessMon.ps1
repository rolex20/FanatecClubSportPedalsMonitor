[CmdletBinding()]
param(
  [int]    $SampleIntervalMs = 1000,
  [string] $OutDir = "$PWD\ProcDiscoveryReports",
  [switch] $WriteCsv,
  [switch] $WriteJson,

  # Discovery can get noisy. These are just defaults; remove/adjust as you like.
  [string[]] $ExcludeNames = @( "sample1.exe", "msedge.exe",
    "conhost.exe","dllhost.exe","sihost.exe","RuntimeBroker.exe"
#    "SearchIndexer.exe","SearchHost.exe","backgroundTaskHost.exe",
#    "ApplicationFrameHost.exe","SystemSettings.exe"
  ),


  # Optional: ignore very short-lived processes
  [int] $MinRuntimeToSampleSec = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- 1. GLOBAL CONFIGURATION MAPPING (Fix for PS 5.1 Scope Issues) ---
# Event Actions in PS 5.1 cannot see "param" variables or use "$using:". 
# We must copy them to the global scope.
$global:Config_SampleIntervalMs      = $SampleIntervalMs
$global:Config_OutDir                = $OutDir
$global:Config_WriteCsv              = $WriteCsv
$global:Config_WriteJson             = $WriteJson
$global:Config_ExcludeNames          = $ExcludeNames
$global:Config_MinRuntimeToSampleSec = $MinRuntimeToSampleSec

# --- 2. TTS SETUP ----------------------------------------------------
Add-Type -AssemblyName System.Speech
$global:TtsLock = New-Object object
$global:TtsSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$global:TtsSynth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female)
$global:TtsSynth.Volume = 100
$global:TtsSynth.Rate   = 0

function global:Speak-ProcessEvent {
  param(
    [Parameter(Mandatory=$true)]
    [string] $EventType,
    [Parameter(Mandatory=$true)]
    [string] $ProcessName
  )
return
  try {
    [System.Threading.Monitor]::Enter($global:TtsLock)
    try {
      [void]$global:TtsSynth.Speak("$EventType $ProcessName")
    } finally {
      [System.Threading.Monitor]::Exit($global:TtsLock)
    }
  } catch {}
}

# --- 3. HELPER FUNCTIONS ---------------------------------------------
function global:New-DirIfMissing([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function global:Format-Bytes([double]$bytes) {
  $suffixes = "B","KB","MB","GB","TB"
  $i = 0
  while ($bytes -ge 1024 -and $i -lt $suffixes.Length-1) { $bytes /= 1024; $i++ }
  "{0:N2} {1}" -f $bytes, $suffixes[$i]
}

function global:Format-Bps([double]$bps) {
  (Format-Bytes $bps) + "/s"
}

function global:Safe-Name([string]$s) {
  return ($s -replace '[\\/:*?"<>|]', '_')
}

function global:Get-ParentInfo([int]$PidVal) {
  $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$PidVal" -ErrorAction SilentlyContinue
  if (-not $cim) {
    return [pscustomobject]@{
      ParentProcessId = $null
      ParentProcessName = $null
      ExecutablePath = $null
      CommandLine = $null
    }
  }

  $ppid = [int]$cim.ParentProcessId
  $pname = $null
  try { $pname = (Get-Process -Id $ppid -ErrorAction Stop).ProcessName + ".exe" } catch { $pname = $null }

  [pscustomobject]@{
    ParentProcessId   = $ppid
    ParentProcessName = $pname
    ExecutablePath    = $cim.ExecutablePath
    CommandLine       = $cim.CommandLine
  }
}

function global:Get-PerfInstanceNameForPid([int]$PidVal) {
  try {
    $cat = New-Object System.Diagnostics.PerformanceCounterCategory("Process")
    foreach ($inst in $cat.GetInstanceNames()) {
      try {
        $pc = New-Object System.Diagnostics.PerformanceCounter("Process","ID Process",$inst,$true)
        $val = [int]$pc.RawValue
        $pc.Dispose()
        if ($val -eq $PidVal) { return $inst }
      } catch { }
    }
  } catch { }
  return $null
}

function global:New-PerfCounters([string]$Instance) {
  $counters = [ordered]@{}
  $counters.CpuPct       = New-Object System.Diagnostics.PerformanceCounter("Process","% Processor Time",$Instance,$true)
  $counters.WorkingSet   = New-Object System.Diagnostics.PerformanceCounter("Process","Working Set",$Instance,$true)
  $counters.PrivateBytes = New-Object System.Diagnostics.PerformanceCounter("Process","Private Bytes",$Instance,$true)
  $counters.IoReadBps    = New-Object System.Diagnostics.PerformanceCounter("Process","IO Read Bytes/sec",$Instance,$true)
  $counters.IoWriteBps   = New-Object System.Diagnostics.PerformanceCounter("Process","IO Write Bytes/sec",$Instance,$true)
  [void]$counters.CpuPct.NextValue()
  return $counters
}

function global:Dispose-PerfCounters($counters) {
  if (-not $counters) { return }
  foreach ($k in $counters.Keys) {
    try { $counters[$k].Dispose() } catch {}
  }
}

# --- 4. STATE & STARTUP ---------------------------------------------
$global:State = [hashtable]::Synchronized(@{})
$global:SessionStart = Get-Date
$global:LogicalProcessors = [int]$env:NUMBER_OF_PROCESSORS
if (-not $global:LogicalProcessors -or $global:LogicalProcessors -lt 1) { $global:LogicalProcessors = 1 }

New-DirIfMissing $global:Config_OutDir

Write-Host "Discovery session start: $($global:SessionStart.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
Write-Host "Event-driven start/stop capture for ALL processes that start AFTER this moment."
Write-Host "Sampling interval: $($global:Config_SampleIntervalMs)ms"
Write-Host "OutDir: $($global:Config_OutDir)"
Write-Host "Press Ctrl+C to stop and print a session summary.`n"

# Timer sampling event (per PID)
function global:Start-Sampler([int]$PidVal) {
  $timer = New-Object System.Timers.Timer
  $timer.Interval = $global:Config_SampleIntervalMs
  $timer.AutoReset = $true
  $srcId = "ProcDisc_Sample_$PidVal"

  Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier $srcId -MessageData $PidVal -Action {
    try {
      $pidLocal = [int]$Event.MessageData
      $st = $global:State[$pidLocal]
      if (-not $st) { return }

      if (-not (Get-Process -Id $pidLocal -ErrorAction SilentlyContinue)) { return }

      $now = Get-Date
      $st.SampleCount++

      $cpu = 0.0; $ws = 0.0; $pv = 0.0; $rb = 0.0; $wb = 0.0

      if ($st.Perf) {
        try {
          $cpuRaw = [double]$st.Perf.CpuPct.NextValue()
          $cpu = $cpuRaw / [double]$st.LogicalProcessors
          if ($cpu -lt 0) { $cpu = 0 }
          $ws = [double]$st.Perf.WorkingSet.NextValue()
          $pv = [double]$st.Perf.PrivateBytes.NextValue()
          $rb = [double]$st.Perf.IoReadBps.NextValue()
          $wb = [double]$st.Perf.IoWriteBps.NextValue()
        } catch { }
      }

      $st.CpuAvgSum += $cpu
      if ($cpu -gt $st.CpuPeak) { $st.CpuPeak = $cpu }
      $st.WsAvgSum += $ws
      if ($ws -gt $st.WsPeak) { $st.WsPeak = $ws }
      $st.PvAvgSum += $pv
      if ($pv -gt $st.PvPeak) { $st.PvPeak = $pv }
      $st.ReadBpsSum += $rb
      if ($rb -gt $st.ReadBpsPeak) { $st.ReadBpsPeak = $rb }
      $st.WriteBpsSum += $wb
      if ($wb -gt $st.WriteBpsPeak) { $st.WriteBpsPeak = $wb }

      $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$pidLocal" -ErrorAction SilentlyContinue
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
      }

      $st.LastSampleTime = $now
      $global:State[$pidLocal] = $st
    } catch {
      Write-Warning ("[SAMPLE][error] PID={0} {1}" -f $Event.MessageData, $_.Exception.Message)
    }
  } | Out-Null

  $timer.Start()
  return [pscustomobject]@{ Timer=$timer; EventId=$srcId }
}

function global:Stop-Sampler([int]$PidVal) {
  $st = $global:State[$PidVal]
  if (-not $st) { return }

  try {
    if ($st.Timer) { $st.Timer.Stop(); $st.Timer.Dispose() }
  } catch {}
  try {
    if ($st.SampleEventId) { Unregister-Event -SourceIdentifier $st.SampleEventId -ErrorAction SilentlyContinue }
  } catch {}
  Dispose-PerfCounters $st.Perf
}

# --- 5. START TRACE EVENT -------------------------------------------
Register-WmiEvent -Query "SELECT * FROM Win32_ProcessStartTrace" -SourceIdentifier "ProcDisc_Start" -Action {
  try {
    $pname = $Event.SourceEventArgs.NewEvent.ProcessName
    $pid   = [int]$Event.SourceEventArgs.NewEvent.ProcessID
    $start = Get-Date


    # Fix: Use $global:Config_ExcludeNames instead of $using:ExcludeNames
    if ($global:Config_ExcludeNames -contains $pname) {
      Write-Host ("[START][excluded] {0} PID={1} {2}" -f $pname, $pid, $start.ToString("HH:mm:ss.fff"))
      # Speak-ProcessEvent -EventType "Started-Excluded: " -ProcessName $pname
      return
    }
	Write-Host ("[START][preliminar] {0} PID={1} {2}" -f $pname, $pid, $start.ToString("HH:mm:ss.fff"))	

    $parent = Get-ParentInfo -PidVal $pid
    $dispParentName = if ($parent.ParentProcessName) { $parent.ParentProcessName } else { "Unknown" }
    $dispParentId   = if ($parent.ParentProcessId)   { $parent.ParentProcessId }   else { -1 }

    $st = [pscustomobject]@{
      ProcessName = $pname
      Pid = $pid
      StartTime = $start
      EndTime = $null
      ParentProcessId = $parent.ParentProcessId
      ParentProcessName = $parent.ParentProcessName
      ExecutablePath = $parent.ExecutablePath
      CommandLine = $parent.CommandLine
      LogicalProcessors = $global:LogicalProcessors
      SampleCount = 0
      CpuAvgSum = 0.0; CpuPeak = 0.0; WsAvgSum = 0.0; WsPeak = 0.0
      PvAvgSum = 0.0; PvPeak = 0.0; ReadBpsSum = 0.0; ReadBpsPeak = 0.0
      WriteBpsSum = 0.0; WriteBpsPeak = 0.0
      TotalReadBytes = 0.0; TotalWriteBytes = 0.0
      LastReadBytes = -1.0; LastWriteBytes = -1.0
      LastSampleTime = $start
      PerfInstance = $null; Perf = $null
      Timer = $null; SampleEventId = $null
      
      # Fix: Use global config variable
      SampleEnabledAt = $start.AddSeconds($global:Config_MinRuntimeToSampleSec)
      SamplingEnabled = $false
    }

    $inst = Get-PerfInstanceNameForPid -PidVal $pid
    $st.PerfInstance = $inst
    if ($inst) {
      try { $st.Perf = New-PerfCounters -Instance $inst } catch { $st.Perf = $null }
    }

    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction SilentlyContinue
    if ($cim) {
      $st.LastReadBytes  = [double]$cim.ReadTransferCount
      $st.LastWriteBytes = [double]$cim.WriteTransferCount
    }

    $global:State[$pid] = $st

    # Fix: Use global config variable
    if ($global:Config_MinRuntimeToSampleSec -le 0) {
      $sample = Start-Sampler -PidVal $pid
      $st.Timer = $sample.Timer
      $st.SampleEventId = $sample.EventId
      $st.SamplingEnabled = $true
      $global:State[$pid] = $st
    } else {
      $delayMs = [int]([math]::Max(0, ($st.SampleEnabledAt - (Get-Date)).TotalMilliseconds))
      $one = New-Object System.Timers.Timer
      $one.Interval = [math]::Max(1,$delayMs)
      $one.AutoReset = $false
      $oneId = "ProcDisc_EnableSample_$pid"
      Register-ObjectEvent -InputObject $one -EventName Elapsed -SourceIdentifier $oneId -MessageData $pid -Action {
        try {
          $pidLocal = [int]$Event.MessageData
          $st2 = $global:State[$pidLocal]
          if (-not $st2) { return }
          if (-not (Get-Process -Id $pidLocal -ErrorAction SilentlyContinue)) { return }
          if (-not $st2.SamplingEnabled) {
            $sample2 = Start-Sampler -PidVal $pidLocal
            $st2.Timer = $sample2.Timer
            $st2.SampleEventId = $sample2.EventId
            $st2.SamplingEnabled = $true
            $global:State[$pidLocal] = $st2
          }
        } catch {

          Write-Warning ("[ENABLE-SAMPLE][error] PID={0} {1}" -f $Event.MessageData, $_.Exception.Message)
        }
      } | Out-Null
      $one.Start()
    }

    Write-Host ("[START] {0} PID={1} {2} | Parent={3} PID={4}" -f `
      $pname, $pid, $start.ToString("HH:mm:ss.fff"),
      $dispParentName, $dispParentId)
    Speak-ProcessEvent -EventType "Started: " -ProcessName $pname	  
  } catch {	  
    Write-Host ("[START][error] {0}" -f $_.Exception.Message)

	
  }
} | Out-Null

# --- 6. STOP TRACE EVENT --------------------------------------------
Register-WmiEvent -Query "SELECT * FROM Win32_ProcessStopTrace" -SourceIdentifier "ProcDisc_Stop" -Action {
  try {
    $pname = $Event.SourceEventArgs.NewEvent.ProcessName
    $pid   = [int]$Event.SourceEventArgs.NewEvent.ProcessID
    $end   = Get-Date

    $st = $global:State[$pid]
    if (-not $st) {
      Write-Host ("[STOP][untracked] {0} PID={1} {2}" -f $pname, $pid, $end.ToString("HH:mm:ss.fff"))
      Speak-ProcessEvent -EventType "Stopped-Untracked: " -ProcessName $pname
      return
    }

    $st.EndTime = $end
    Stop-Sampler -PidVal $pid

    $dur = $st.EndTime - $st.StartTime
    $secs = [double]$dur.TotalSeconds
    if ($secs -le 0) { $secs = 0.0001 }
    $samples = [int]$st.SampleCount
    
    $cpuAvg = if ($samples -gt 0) { $st.CpuAvgSum / $samples } else { 0.0 }
    $wsAvg  = if ($samples -gt 0) { $st.WsAvgSum  / $samples } else { 0.0 }
    $pvAvg  = if ($samples -gt 0) { $st.PvAvgSum  / $samples } else { 0.0 }
    $readAvgBps  = if ($samples -gt 0) { $st.ReadBpsSum  / $samples } else { 0.0 }
    $writeAvgBps = if ($samples -gt 0) { $st.WriteBpsSum / $samples } else { 0.0 }
    $cpuTimeEstMs = ($cpuAvg / 100.0) * $secs * 1000.0 * [double]$st.LogicalProcessors

    $report = [pscustomobject]@{
      ProcessName = $st.ProcessName
      Pid = $st.Pid
      StartTime = $st.StartTime
      EndTime = $st.EndTime
      Duration = "{0:hh\:mm\:ss\.fff}" -f $dur
      ParentProcessName = $st.ParentProcessName
      ParentProcessId = $st.ParentProcessId
      ExecutablePath = $st.ExecutablePath
      CommandLine = $st.CommandLine
      Samples = $samples
      CpuAvgPercent = [math]::Round($cpuAvg,2)
      CpuPeakPercent = [math]::Round($st.CpuPeak,2)
      CpuTimeEstimated = [TimeSpan]::FromMilliseconds([math]::Max(0,[math]::Round($cpuTimeEstMs,0)))
      WorkingSetAvg = Format-Bytes $wsAvg
      WorkingSetPeak = Format-Bytes $st.WsPeak
      PrivateBytesAvg = Format-Bytes $pvAvg
      PrivateBytesPeak = Format-Bytes $st.PvPeak
      TotalReadBytes = Format-Bytes $st.TotalReadBytes
      TotalWriteBytes = Format-Bytes $st.TotalWriteBytes
      ReadThroughputAvg = Format-Bps $readAvgBps
      ReadThroughputPeak = Format-Bps $st.ReadBpsPeak
      WriteThroughputAvg = Format-Bps $writeAvgBps
      WriteThroughputPeak = Format-Bps $st.WriteBpsPeak
    }

    Speak-ProcessEvent -EventType "Stopped:" -ProcessName $pname
    Write-Host ("[STOP]  {0} PID={1} {2} | Ran {3}" -f `
      $pname, $pid, $end.ToString("HH:mm:ss.fff"), $report.Duration)
    $report | Format-List | Out-String | Write-Host

    # Optional exports - FIX: Use Global Config vars
    $safe = Safe-Name $st.ProcessName
    $stamp = $st.StartTime.ToString("yyyyMMdd_HHmmss")
    $base = Join-Path $global:Config_OutDir "$safe`_PID$pid`_$stamp"

    if ($global:Config_WriteJson) {
      ($report | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath "$base.json" -Encoding UTF8
      Write-Host "Wrote JSON: $base.json"
    }
    if ($global:Config_WriteCsv) {
      $report | Export-Csv -LiteralPath "$base.csv" -NoTypeInformation -Encoding UTF8
      Write-Host "Wrote CSV:  $base.csv"
    }

    $global:State.Remove($pid) | Out-Null
  } catch {
# 1. Load the required .NET assembly (safe to run multiple times)
    Add-Type -AssemblyName System.Windows.Forms

    # 2. Play the standard Windows Error sound ("Hand")
    [System.Media.SystemSounds]::Hand.Play()	  
    Write-Warning ("[STOP][error] {0}" -f $_.Exception.Message)
  }
} | Out-Null

# --- 7. MAIN LOOP ---------------------------------------------------
try {
  while ($true) { 	
  	Write-Host "<" -NoNewline
	Wait-Event -Timeout 5
	Write-Host ">" -NoNewline


  }
}  catch {
    Write-Host ("[STOP][error] {0}" -f $_.Exception.Message)	
# 1. Load the required .NET assembly (safe to run multiple times)
    Add-Type -AssemblyName System.Windows.Forms

    # 2. Play the standard Windows Error sound ("Hand")
    [System.Media.SystemSounds]::Hand.Play()	  
    Write-Host ("[STOP][error] {0}" -f $_.Exception.Message)
  }
finally {
  Write-Host "`nStopping discovery session..."
  foreach ($pid in @($global:State.Keys)) { Stop-Sampler -PidVal $pid }
  Unregister-Event -SourceIdentifier "ProcDisc_Start" -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier "ProcDisc_Stop"  -ErrorAction SilentlyContinue
  try { $global:TtsSynth.Dispose() } catch {}
  Write-Host "Session ended."
}