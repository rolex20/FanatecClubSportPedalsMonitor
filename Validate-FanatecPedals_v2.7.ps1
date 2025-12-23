<#
.SYNOPSIS
  Validate FanatecPedals HTTP + frame schema for PedDash compatibility.

.DESCRIPTION
  - Sends OPTIONS and repeated GET requests to the bridge URL (default http://localhost:8181/)
  - Validates CORS/no-cache headers
  - Validates JSON envelope: schemaVersion, bridgeInfo, frames[]
  - Validates that each frame contains ALL legacy main.c fields + bridge metrics
  - By default, allows extra keys (e.g., brake telemetry). Use -StrictKeys to fail on extras.

.EXAMPLE
  .\Validate-FanatecPedals.ps1 -DurationSec 15

.EXAMPLE
  .\Validate-FanatecPedals.ps1 -DurationSec 15 -StrictKeys

.EXAMPLE
  .\Validate-FanatecPedals.ps1 -InteractiveEvents
#>

[CmdletBinding()]
param(
  [string]$Url = "http://localhost:8181/",
  [int]$PollMs = 100,
  [int]$DurationSec = 10,
  [switch]$StrictKeys,
  [switch]$InteractiveEvents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail($msg) {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  $script:HadFailure = $true
}

function Pass($msg) {
  Write-Host "PASS: $msg" -ForegroundColor Green
}

function Warn($msg) {
  Write-Host "WARN: $msg" -ForegroundColor Yellow
}

function Get-ExpectedFrameKeys {
  # 70 legacy fields (main.c) + 4 bridge metrics used by PedDash.
  return @(
    "verbose_flag","monitor_clutch","monitor_gas","gas_deadzone_in","gas_deadzone_out","gas_window","gas_cooldown","gas_timeout","gas_min_usage_percent",
    "axis_normalization_enabled","debug_raw_mode","clutch_repeat_required","estimate_gas_deadzone_enabled","auto_gas_deadzone_enabled","auto_gas_deadzone_minimum",
    "target_vendor_id","target_product_id","telemetry_enabled","tts_enabled","ipc_enabled","no_console_banner",
    "gas_physical_pct","clutch_physical_pct","gas_logical_pct","clutch_logical_pct",
    "joy_ID","joy_Flags","iterations","margin","sleep_Time",
    "axisMax","axisMargin","lastClutchValue","repeatingClutchCount","isRacing","peakGasInWindow","lastFullThrottleTime","lastGasActivityTime","lastGasAlertTime",
    "gasIdleMax","gasFullMin","gas_timeout_ms","gas_window_ms","gas_cooldown_ms",
    "best_estimate_percent","last_printed_estimate","estimate_window_peak_percent","estimate_window_start_time","last_estimate_print_time",
    "currentTime","rawGas","rawClutch","gasValue","clutchValue","closure","percentReached","currentPercent","iLoop",
    "producer_loop_start_ms","producer_notify_ms","fullLoopTime_ms","telemetry_sequence",
    "receivedAtUnixMs","metricHttpProcessMs","metricTtsSpeakMs","metricLoopProcessMs",
    "gas_alert_triggered","clutch_alert_triggered","controller_disconnected","controller_reconnected","gas_estimate_decreased","gas_auto_adjust_applied",
    "last_disconnect_time_ms","last_reconnect_time_ms"
  ) | Sort-Object -Unique
}

function Compare-KeySets {
  param(
    [string[]]$Expected,
    [string[]]$Actual,
    [string]$Context = "frame"
  )

  $exp = [System.Collections.Generic.HashSet[string]]::new([string[]]$Expected)
  $act = [System.Collections.Generic.HashSet[string]]::new([string[]]$Actual)

  $missing = $Expected | Where-Object { -not $act.Contains($_) }
  $extra   = $Actual   | Where-Object { -not $exp.Contains($_) }

  if ($missing.Count -gt 0) {
    Fail "$Context is missing keys: $($missing -join ', ')"
    return
  }

  Pass "$Context contains all expected keys ($($Expected.Count))."

  if ($extra.Count -gt 0) {
    if ($StrictKeys) { Fail "$Context has unexpected extra keys: $($extra -join ', ')" }
    else { Warn "$Context has extra keys (allowed): $($extra -join ', ')" }
  } elseif ($StrictKeys) {
    Pass "$Context key set matches exactly (StrictKeys)."
  }
}

function Try-InvokeWebRequest {
  param(
    [string]$Method,
    [string]$Uri
  )
  try {
    return Invoke-WebRequest -Uri $Uri -Method $Method -UseBasicParsing
  } catch {
    Fail "$Method $Uri failed: $_"
    return $null
  }
}

# -------------------------------
# 1) Header Contract Validation
# -------------------------------
$script:HadFailure = $false

Write-Host "Validating bridge at $Url" -ForegroundColor Cyan

$opt = Try-InvokeWebRequest -Method "OPTIONS" -Uri $Url
if ($opt) {
  if ($opt.StatusCode -ne 200) { Fail "OPTIONS returned status $($opt.StatusCode) (expected 200)" } else { Pass "OPTIONS returned 200" }

  $h = $opt.Headers
  if ($h["Access-Control-Allow-Origin"] -ne "*") { Fail "Missing/incorrect Access-Control-Allow-Origin header (expected '*')" } else { Pass "CORS: Allow-Origin '*'" }
  if (-not $h["Access-Control-Allow-Methods"]) { Warn "Access-Control-Allow-Methods not present (recommended for PedDash)" } else { Pass "CORS: Allow-Methods present" }
  if (-not $h["Cache-Control"]) { Warn "Cache-Control header not present (recommended no-store)" } else { Pass "Cache-Control present" }
}

$expectedKeys = Get-ExpectedFrameKeys

# -------------------------------
# 2) Poll GET and validate JSON
# -------------------------------
$stopAt = (Get-Date).AddSeconds($DurationSec)

$framesSeen = 0
$badJson = 0
$emptyGets = 0

$discTransitions = 0
$reconnEvents = 0
$lastDiscLatched = $null

while ((Get-Date) -lt $stopAt) {
  $res = Try-InvokeWebRequest -Method "GET" -Uri $Url
  if (-not $res) { Start-Sleep -Milliseconds $PollMs; continue }

  if ($res.StatusCode -ne 200) {
    Fail "GET returned status $($res.StatusCode) (expected 200)"
    Start-Sleep -Milliseconds $PollMs
    continue
  }

  $payload = $null
  try {
    $payload = $res.Content | ConvertFrom-Json
  } catch {
    $badJson++
    Fail "Invalid JSON in response: $_"
    Start-Sleep -Milliseconds $PollMs
    continue
  }

  if ($payload.schemaVersion -ne 1) { Fail "schemaVersion=$($payload.schemaVersion) (expected 1)" }
  if (-not $payload.bridgeInfo) { Fail "Missing bridgeInfo" }
  if (-not $payload.frames) { Fail "Missing frames array" }

  $frames = @($payload.frames)
  if ($frames.Count -eq 0) {
    $emptyGets++
    Start-Sleep -Milliseconds $PollMs
    continue
  }

  foreach ($f in $frames) {
    $framesSeen++

    $actualKeys = @($f.PSObject.Properties.Name | Sort-Object -Unique)
    Compare-KeySets -Expected $expectedKeys -Actual $actualKeys -Context "frame#$framesSeen"

    # Event tracking
    $disc = [int]($f.controller_disconnected)
    if ($lastDiscLatched -eq $null) { $lastDiscLatched = $disc }
    if ($lastDiscLatched -eq 0 -and $disc -eq 1) { $discTransitions++ }
    $lastDiscLatched = $disc

    $reconn = [int]($f.controller_reconnected)
    if ($reconn -eq 1) { $reconnEvents++ }
  }

  Start-Sleep -Milliseconds $PollMs
}

Write-Host ""
Write-Host "---- Summary ----" -ForegroundColor Cyan
Write-Host ("Frames seen: {0}" -f $framesSeen)
Write-Host ("Empty GETs:  {0}" -f $emptyGets)
Write-Host ("Bad JSON:    {0}" -f $badJson)
Write-Host ("Disc transitions seen (0->1): {0}" -f $discTransitions)
Write-Host ("Reconnect event frames seen (controller_reconnected==1): {0}" -f $reconnEvents)

if ($InteractiveEvents) {
  Write-Host ""
  Write-Host "Interactive event test:" -ForegroundColor Cyan
  Write-Host "1) Ensure pedals are CONNECTED, then UNPLUG them and press Enter." -ForegroundColor Yellow
  Read-Host | Out-Null

  $timeout = (Get-Date).AddSeconds(90)
  $seenDisc = $false
  while ((Get-Date) -lt $timeout) {
    $r = Try-InvokeWebRequest -Method "GET" -Uri $Url
    if ($r) {
      try { $p = $r.Content | ConvertFrom-Json } catch { continue }
      foreach ($f in @($p.frames)) {
        if ([int]$f.controller_disconnected -eq 1) { $seenDisc = $true; break }
      }
    }
    if ($seenDisc) { break }
    Start-Sleep -Milliseconds 250
  }

  if (-not $seenDisc) { Fail "Did not observe controller_disconnected==1 within 90s after unplug." }
  else { Pass "Observed disconnect latched state." }

  Write-Host "2) Now PLUG the pedals back in and press Enter." -ForegroundColor Yellow
  Read-Host | Out-Null

  $timeout = (Get-Date).AddSeconds(90)
  $seenReconn = $false
  $reconnCount = 0

  while ((Get-Date) -lt $timeout) {
    $r = Try-InvokeWebRequest -Method "GET" -Uri $Url
    if ($r) {
      try { $p = $r.Content | ConvertFrom-Json } catch { continue }
      foreach ($f in @($p.frames)) {
        if ([int]$f.controller_reconnected -eq 1) { $seenReconn = $true; $reconnCount++ }
      }
    }
    if ($seenReconn -and $reconnCount -ge 1) { break }
    Start-Sleep -Milliseconds 250
  }

  if (-not $seenReconn) { Fail "Did not observe controller_reconnected==1 within 90s after replug." }
  else { Pass "Observed reconnect event frame(s): $reconnCount (expected 1 in a clean run)." }

  if ($reconnCount -ne 1) { Warn "Reconnect event appeared $reconnCount times. PedDash usually tolerates this, but it's worth investigating if it becomes noisy." }
}

Write-Host ""
if ($script:HadFailure) {
  Write-Host "RESULT: RED (compatibility checks failed)" -ForegroundColor Red
  exit 1
} else {
  Write-Host "RESULT: GREEN (compatibility checks passed)" -ForegroundColor Green
  exit 0
}
