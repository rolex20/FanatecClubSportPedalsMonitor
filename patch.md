I read all 4 files and did a direct “what PedDash used to get (main.c + pedBridge.ps1) vs what FanatecPedals.ps1 *actually* publishes” comparison.

### What’s going wrong (root cause)

FanatecPedals.ps1 **defines** the full legacy schema (it includes every field from the old `PedalMonState` + the pedBridge-added timing fields, plus your new brake fields), **but 27 legacy fields are never written to `$State` at all**, so they stay `0` forever in the JSON frames. Separately, your **disconnect/reconnect path `continue`s before enqueue**, so PedDash never receives the “disconnect” or “reconnect” event frames that main.c explicitly publishes.

---

## Exhaustive inventory of missing/unpopulated legacy fields (27)

These are present in `Fanatec.PedalMonState` but **never assigned** anywhere in FanatecPedals.ps1 today:

### A) Config / static fields (should be set once, outside loop)

* `target_vendor_id`
* `target_product_id`
* `telemetry_enabled`
* `no_console_banner`
* `debug_raw_mode`
* `ipc_enabled`
* `margin`
* `iterations`

### B) Derived constants (computed in locals today, but never mirrored to `$State`)

* `axisMargin`
* `gasIdleMax`
* `gasFullMin`
* `gas_timeout_ms`
* `gas_window_ms`
* `gas_cooldown_ms`

### C) Runtime state (you track these in locals, but never mirror into `$State`)

* `isRacing`
* `peakGasInWindow`
* `lastFullThrottleTime`
* `lastGasActivityTime`
* `lastGasAlertTime`
* `lastClutchValue`
* `repeatingClutchCount`
* `last_reconnect_time_ms`  *(you set disconnect time, but never set reconnect time)*

### D) Estimator state (tracked in locals but never mirrored, and one semantic reset differs)

* `currentPercent`
* `estimate_window_peak_percent`
* `estimate_window_start_time`
* `last_printed_estimate`
* `last_estimate_print_time`

### E) Missing frames (not fields)

* **Disconnect frame is not published** (main.c publishes immediately on transition)
* **Reconnect frame is not published** (main.c publishes immediately on transition)

---

# Patch plan + exact code snippets (with placement)

Below are “drop-in” snippets. I’m keeping *static* fields out of the `while` loop (as you requested), and only mirroring truly dynamic fields each iteration.

---

## 1) Add two small helpers (SECTION 5: HELPER FUNCTIONS)

Place these **after** `Get-AxisValue` in “SECTION 5”.

```powershell
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

function Publish-TelemetryFrame {
    param(
        [Fanatec.PedalMonState]$State,
        [ref]$TelemetrySeq,
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [double]$LoopStartMs
    )

    $TelemetrySeq.Value++
    $State.telemetry_sequence = [uint32]$TelemetrySeq.Value

    $State.receivedAtUnixMs       = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $State.metricHttpProcessMs    = [Fanatec.Shared]::LastHttpTimeMs
    $State.metricTtsSpeakMs       = [Fanatec.Shared]::LastTtsTimeMs
    $State.metricLoopProcessMs    = $Stopwatch.Elapsed.TotalMilliseconds - $LoopStartMs
    $State.producer_notify_ms     = [uint32][Environment]::TickCount

    [Fanatec.Shared]::TelemetryQueue.Enqueue($State.Clone())
}
```

---

## 2) Fix + fill legacy config fields once (SECTION 6: INITIALIZATION)

### 2a) Replace the current `tts_enabled` assignment

Find this line in your init block:

```powershell
$State.tts_enabled = [int][bool]$Tts.IsPresent
```

Replace with:

```powershell
# main.c semantics: 1 == enabled, 0 == disabled
$State.tts_enabled = [int][bool]$Tts
```

### 2b) Add the missing static/config fields (place right after you set `clutch_repeat_required`)

Immediately after:

```powershell
$State.clutch_repeat_required = $ClutchRepeat
```

add:

```powershell
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
```

### 2c) Mirror derived constants once (right after you compute `$GasIdleMax/$GasFullMin/$AxisMargin`)

Right after:

```powershell
$GasIdleMax = [uint32]($AxisMax * $GasDeadzoneIn / 100)
$GasFullMin = [uint32]($AxisMax * $GasDeadzoneOut / 100)
$AxisMargin = [uint32]($AxisMax * $Margin / 100)
```

add:

```powershell
# Precompute ms versions once (main.c does this to keep hot path clean)
$GasTimeoutMs  = [uint32]($GasTimeout  * 1000)
$GasWindowMs   = [uint32]($GasWindow   * 1000)
$GasCooldownMs = [uint32]($GasCooldown * 1000)

$State.axisMargin     = $AxisMargin
$State.gasIdleMax      = $GasIdleMax
$State.gasFullMin      = $GasFullMin
$State.gas_timeout_ms  = $GasTimeoutMs
$State.gas_window_ms   = $GasWindowMs
$State.gas_cooldown_ms = $GasCooldownMs
```

### 2d) Add the missing estimator bookkeeping variables (init locals) + seed `$State` once

In your “Runtime Logic Variables” area, add **one** new variable and seed fields:

Replace your estimator init block with this (or add what’s missing):

```powershell
$EstimateWindowStartTime   = [uint32][Environment]::TickCount
$BestEstimatePercent       = 100
$LastPrintedEstimate       = 100           # <-- MISSING today
$EstimateWindowPeakPercent = 0
$LastEstimatePrintTime     = 0
$CurrentPercent            = 0             # <-- MISSING today

# Seed telemetry-visible estimator/runtime fields
$State.best_estimate_percent        = [uint32]$BestEstimatePercent
$State.last_printed_estimate        = [uint32]$LastPrintedEstimate
$State.estimate_window_peak_percent = [uint32]$EstimateWindowPeakPercent
$State.estimate_window_start_time   = [uint32]$EstimateWindowStartTime
$State.last_estimate_print_time     = [uint32]$LastEstimatePrintTime
$State.currentPercent               = [uint32]$CurrentPercent
```

Also seed the missing “runtime state” fields once (right after you initialize the locals):

```powershell
$State.isRacing             = 0
$State.peakGasInWindow      = [uint32]$PeakGasInWindow
$State.lastFullThrottleTime = [uint32]$LastFullThrottleTime
$State.lastGasActivityTime  = [uint32]$LastGasActivityTime
$State.lastGasAlertTime     = [uint32]$LastGasAlertTime
$State.lastClutchValue      = [uint32]$LastClutchValue
$State.repeatingClutchCount = [int]$RepeatingClutchCount
```

---

## 3) Move “Reset one-shots” to the top of the loop (SECTION 7)

Right after you set `producer_loop_start_ms` / `fullLoopTime_ms` (i.e., very early in the loop), add:

```powershell
# Reset per-frame one-shot flags (matches main.c)
# NOTE: controller_disconnected is latched and is NOT cleared here.
$State.gas_alert_triggered     = 0
$State.clutch_alert_triggered  = 0
$State.gas_estimate_decreased  = 0
$State.gas_auto_adjust_applied = 0
$State.controller_reconnected  = 0
```

Then **delete** your existing “Reset One-Shots” block later in the loop (so you don’t reset after work is already done).

---

## 4) Replace the logical % blocks with Compute-LogicalPct (SECTION 7)

Replace your current “Logical Pct Calc” section with:

```powershell
$State.gas_logical_pct    = Compute-LogicalPct -Value $State.gasValue    -IdleMax $GasIdleMax -FullMin $GasFullMin
$State.clutch_logical_pct = Compute-LogicalPct -Value $State.clutchValue -IdleMax $GasIdleMax -FullMin $GasFullMin
$State.brake_logical_pct  = Compute-LogicalPct -Value $State.brakeValue  -IdleMax $GasIdleMax -FullMin $GasFullMin
```

This matches the old pipeline semantics and adds the missing divide-by-zero guard that main.c already has.

---

## 5) Fix disconnect/reconnect to publish frames + set `last_reconnect_time_ms` (SECTION 7)

Replace your entire current disconnect block:

```powershell
# --- Handle Disconnect ---
if ($res -ne 0) {
    ...
    continue
}
```

with this version (same behavior, but **publishes frames like main.c**):

```powershell
# --- Handle Disconnect (main.c-compatible: publish disconnect/reconnect frames) ---
if ($res -ne 0) {

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
            $AxisMargin = [uint32]($AxisMax * $State.margin / 100)

            $State.gasIdleMax  = $GasIdleMax
            $State.gasFullMin  = $GasFullMin
            $State.axisMargin  = $AxisMargin

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
```

---

## 6) Make estimator telemetry fields match main.c (SECTION 7: inside “Estimator”)

Replace your estimator block with this (same thresholds as main.c: drift uses `>`, estimator uses `>=`, and it resets on autopause):

```powershell
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
```

Also: when you auto-pause (`$IsRacing = $false`), add the main.c reset:

```powershell
elseif ($IsRacing -and ($State.currentTime - $LastGasActivityTime) -gt $GasTimeoutMs) {
    if ($Verbose) { Write-Host ("Gas: Auto-Pause (Idle for {0} s)." -f $GasTimeout) -ForegroundColor Cyan }
    $IsRacing = $false

    if ($EstimateGasDeadzone) {
        $EstimateWindowStartTime   = $State.currentTime
        $EstimateWindowPeakPercent = 0
    }
}
```

---

## 7) Mirror the missing runtime fields right before publish (SECTION 7)

Immediately before your “Telemetry Publish” call, add:

```powershell
# --- Mirror runtime locals into telemetry fields (fixes the “always 0” values in PedDash) ---
$State.isRacing             = [int][bool]$IsRacing
$State.peakGasInWindow      = [uint32]$PeakGasInWindow
$State.lastFullThrottleTime = [uint32]$LastFullThrottleTime
$State.lastGasActivityTime  = [uint32]$LastGasActivityTime
$State.lastGasAlertTime     = [uint32]$LastGasAlertTime

$State.lastClutchValue      = [uint32]$LastClutchValue
$State.repeatingClutchCount = [int]$RepeatingClutchCount
```

Then replace the whole current publish block with a single call:

```powershell
Publish-TelemetryFrame -State $State -TelemetrySeq ([ref]$TelemetrySeq) -Stopwatch $Stopwatch -LoopStartMs $LoopStart
```

---

# Result: what this fixes in PedDash immediately

* `isRacing`, `peakGasInWindow`, `lastFullThrottleTime`, `lastGasActivityTime`, `lastGasAlertTime` become correct/live (no more “always 0”).
* `repeatingClutchCount` and `lastClutchValue` become correct/live.
* Estimator debug fields (`currentPercent`, window start/peak, printed/last print times) become correct/live and match main.c semantics.
* `target_vendor_id/target_product_id`, `telemetry_enabled`, `no_console_banner`, `debug_raw_mode`, `ipc_enabled`, `margin`, `iterations` show up exactly like before.
* Disconnect/reconnect frames now appear exactly like the old pipeline (PedDash will see the transition, not just “silence”).

If you want, I can also point out the (small) remaining compatibility deltas that are *not* field-related (CORS OPTIONS headers, batchId increment style, and whether `receivedAtUnixMs` should be stamped at dequeue time instead of enqueue time).



---

Here are the “non-field” compatibility deltas that are still different between **(main.c + pedBridge.ps1)** and your current **FanatecPedals.ps1**, plus the exact changes to make them match.

---

## 1) HTTP CORS parity + OPTIONS preflight handling (still missing)

**pedBridge.ps1** sends these headers on every response and explicitly handles preflight:

* `Access-Control-Allow-Origin: *`
* `Access-Control-Allow-Methods: GET, OPTIONS`
* `Access-Control-Allow-Headers: *`
* `Cache-Control: no-store`
* If `OPTIONS`: return `200` and **no JSON body**

**FanatecPedals.ps1** currently only sends:

* `Access-Control-Allow-Origin`
* `Cache-Control`
  …and it will try to return JSON even for `OPTIONS`.

That can cause “random” browser failures if any environment triggers a preflight (file:// origin quirks, devtools, future fetch headers, extensions, etc.).

### Patch (where: inside `Create-HttpServerInstance` HTTP loop, right after `$request/$response`)

Replace your header block with this:

```powershell
$response.AddHeader("Access-Control-Allow-Origin", "*")
$response.AddHeader("Access-Control-Allow-Methods", "GET, OPTIONS")
$response.AddHeader("Access-Control-Allow-Headers", "*")
$response.AddHeader("Cache-Control", "no-store")

if ($request.HttpMethod -eq "OPTIONS") {
    $response.StatusCode = 200
    $response.Close()
    continue
}
```

---

## 2) `bridgeInfo.batchId` generation style (still not matching pedBridge)

**pedBridge.ps1** uses a **global static BatchId** and increments it with:

```powershell
[System.Threading.Interlocked]::Increment([ref][PedMon.Shared]::BatchId)
```

That’s atomic and stays correct even if you ever make the HTTP server more concurrent.

**FanatecPedals.ps1** currently uses a local:

```powershell
$localBatchId++
```

That’s fine in a single-threaded listener loop, but it’s not *identical* to the pedBridge behavior and it resets if the runspace is recreated.

### Patch (two tiny edits)

#### 2a) Add a static BatchId to `Fanatec.Shared` (in your C# `$Source`)

Inside:

```csharp
public static class Shared {
    public static ConcurrentQueue<PedalMonState> TelemetryQueue = ...
    public static double LastHttpTimeMs = 0;
    ...
}
```

add:

```csharp
public static int BatchId = 0;
```

#### 2b) Reset it at startup (SECTION 6 init)

Right after you reset StopSignal:

```powershell
[Fanatec.Shared]::StopSignal = $false
[Fanatec.Shared]::BatchId = 0
```

#### 2c) Use Interlocked increment in the HTTP thread

In the HTTP loop, replace `$localBatchId++` with:

```powershell
$batchId = [System.Threading.Interlocked]::Increment([ref][Fanatec.Shared]::BatchId)
```

and set:

```powershell
bridgeInfo = @{
  batchId = $batchId
  ...
}
```

You can delete `$localBatchId` entirely after this.

---

## 3) `receivedAtUnixMs`: enqueue-time vs dequeue-time stamping

This one is mostly about *semantics*:

* **Old pipeline (main.c → pedBridge.ps1):** `receivedAtUnixMs` is stamped when **pedBridge receives/captures** the frame (right before enqueueing it).
* **FanatecPedals.ps1:** you stamp `receivedAtUnixMs` right before enqueue as well.

So you’re already aligned in the **important way**: it represents “frame capture/enqueue time”, not “time the browser fetched it”.

### Should you stamp at dequeue time (HTTP serve time)?

I would **not**. PedDash uses `frames[0].receivedAtUnixMs` and `frames[last].receivedAtUnixMs` as “oldest/newest enqueue time” to infer backlog and catch-up dynamics. If you stamp at dequeue, all frames in a batch collapse toward the same timestamp and that signal gets destroyed.

You already have `bridgeInfo.servedAtUnixMs` for serve-time.

**Recommendation:** keep `receivedAtUnixMs` at publish/enqueue time (what you’re doing now).

---

### Optional tiny “extra parity” (not required, but worth noting)

* pedBridge answers only `GET` + `OPTIONS`; FanatecPedals currently answers “whatever” with JSON. After adding the OPTIONS block, you’re effectively equivalent for browser use.

If you want, I can give you a single consolidated “diff-style” patch for just these HTTP-side changes so you can paste them in cleanly.
