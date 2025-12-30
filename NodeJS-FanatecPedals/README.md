# NodeJS Fanatec Pedals Telemetry

A single-threaded Node.js replacement for `FanatecPedals.ps1`. It polls WinMM `joyGetPosEx` and streams one telemetry frame per poll over WebSockets while keeping the same telemetry fields expected by `PedDash.html`.

## Prerequisites

- Windows environment with `winmm.dll` available.
- Node.js 18+ (for stable timers and `performance.now`).
- Fanatec pedals connected via WinMM.

## Install

```bash
cd NodeJS-FanatecPedals
npm install
```

## Run

```bash
node src/index.js --SleepTime 10 --MonitorClutch --MonitorGas --VendorId 0EB7 --ProductId 1839
```

Key options mirror the PowerShell script (case-sensitive):

- `--SleepTime, -s` poll interval in ms (default 1000).
- `--Margin, -m` clutch tolerance percent.
- `--ClutchRepeat` samples required before a clutch alert.
- `--NoAxisNormalization` disables inversion.
- `--GasDeadzoneIn / --GasDeadzoneOut` percent thresholds.
- `--BrakeDeadzoneIn / --BrakeDeadzoneOut` percent thresholds (default to gas values when omitted).
- `--ClutchDeadzoneIn / --ClutchDeadzoneOut` percent thresholds (default to gas values when omitted).
- `--GasWindow / --GasCooldown / --GasTimeout / --GasMinUsage` gas drift tuning.
- `--EstimateGasDeadzone` enables auto-estimator; `--AutoGasDeadzoneMin` enables auto adjust when >= 0.
- `--JoystickID, -j` numeric joystick id (>=16 with VID+PID triggers auto-detect).
- `--VendorId / --ProductId` hex strings for auto-detect and reconnect scanning.
- `--MonitorClutch / --MonitorGas` enable monitoring paths.
- `--Telemetry` toggle telemetry publishing.
- `--Tts` or `--NoTts` toggle text-to-speech notifications (uses Windows `say` when available; otherwise logs the phrase).
- `--JoyFlags` WinMM dwFlags (default 255 / JOY_RETURNALL). Axis resolution becomes 1023 when the RAW flag (256) is set.

## WebSocket endpoint

- Server: `ws://localhost:8181/ws`
- Transport: one JSON message **per poll**. No batching or replay. Late clients start with fresh frames only.
- Backpressure: if a client's `bufferedAmount` exceeds 5MB the frame is skipped for that client ("lost is lost").
- Optimization: when `wss.clients.size === 0` no `JSON.stringify` or `send` occurs, but the poller keeps running and updating internal state.

## HTTP endpoint (PedDash/validator compatible)

- Server: `http://localhost:8181/`
- `OPTIONS /` responds 200 with CORS headers.
- `GET /` returns a single-frame envelope:

```
{
  "schemaVersion": 1,
  "bridgeInfo": {
    "batchId": 1,
    "generatedAtUnixMs": 1700000000000,
    "framesInBatch": 1
  },
  "frames": [ { /* latest Fanatec.PedalMonState frame */ } ]
}
```

Only the latest frame is returned (no replay buffer). `batchId` increments per HTTP response. `Cache-Control: no-store` is emitted for PedDash compatibility.

## HTTP control

- `GET http://localhost:8181/QUIT` shuts down cleanly.
- `SIGINT` (Ctrl+C) also shuts down the poller and WebSocket server.

## Telemetry payload

Each WebSocket message is a single frame object containing **all** fields from the `Fanatec.PedalMonState` schema (exact names, numeric types). Typical fields include:

- Raw and logical pedal values (`rawGas`, `gas_physical_pct`, `gas_logical_pct`, etc.).
- Runtime flags (`gas_alert_triggered`, `clutch_alert_triggered`, `controller_disconnected`, `controller_reconnected`).
- Gas estimator state (`best_estimate_percent`, `gas_auto_adjust_applied`, `estimate_window_peak_percent`, etc.).
- Timing metadata (`telemetry_sequence`, `producer_loop_start_ms`, `fullLoopTime_ms`, `metricLoopProcessMs`, `metricHttpProcessMs`).

Clients should treat missing frames as drops and continue with the next frame; no buffering or replay is performed.
