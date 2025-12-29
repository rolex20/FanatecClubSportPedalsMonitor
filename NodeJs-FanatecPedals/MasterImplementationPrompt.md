# Master Implementation Prompt: Fanatec Pedals Telemetry Migration (PowerShell → Node.js)

**Role:** You are an expert Node.js systems engineer and performance tuner. Build a production-ready Node.js replacement for `FanatecPedals.ps1` that preserves all current functionality and UI behaviors while modernizing the stack.

## Goals & Rationale
- **Exploit Node.js JIT (V8/TurboFan)**: Replace PowerShell/C# `Add-Type` interop with native Node.js. Emphasize that V8 JIT compiles hot paths to x86, eliminating the PS interpreter overhead and reducing marshalling costs.
- **Maintain feature parity**: Reproduce all telemetry fields, gas-drift/clutch-noise detection, deadzone logic, device auto-detection, config flags, HTTP headers/metadata, and TTS behaviors found in `FanatecPedals.ps1` and consumed by `PedDash.html`.
- **Introduce WebSockets**: Replace 100ms HTTP polling with push-based streaming (≥100 Hz) while keeping an opt-in switch in the dashboard to choose between the legacy fetch loop and the new WebSocket stream.
- **Non-blocking TTS**: Provide asynchronous speech alerts without perturbing telemetry cadence.
- **Hardware utilization (Galvatron)**: Intel i14700K (20 cores), Windows 11 Pro, RTX 4090. Keep the event loop unblocked; consider worker threads for FFI polling and/or TTS.

## Deliverables & Layout
Create a new directory `NodeJs-FanatecPedals/` containing:
- `package.json`, `package-lock.json` (or `pnpm-lock.yaml`), `.npmrc` if needed.
- `src/` with:
  - `server.js` (entrypoint: WebSocket + HTTP compatibility route if needed).
  - `ffi/joy.js` (FFI bindings for `WinMM.dll` + JOYINFOEX struct/flags).
  - `logic/telemetry.js` (polling loop, normalization, drift/noise detection, telemetry frame assembly matching PS script fields/names/types).
  - `logic/tts.js` (async speech alerts).
  - `config/index.js` (config defaults + optional .ini loader mirroring PS arguments).
  - `util/logger.js` (structured logging with timestamps; keep verbose/debug toggles).
- Updated `PedDash.html` (copy existing UI, add WebSocket option and listener; keep current rendering and configuration panel). Place this updated file in `NodeJs-FanatecPedals/PedDash.html`.
- A `README.md` in the new directory describing setup, config flags, and run instructions.

## Source Artifacts (for feature parity)
- Backend reference: `FanatecPedals.ps1` (telemetry fields, JOYINFOEX flags, gas/clutch detection, HTTP response shape, config switches, TTS triggers, affinity/priority hints).
- Frontend reference: `PedDash.html` (tabs, rendering logic, fetch-based dataLoop, lag tracking, config form fields, gauges/events/telemetry map).

## Implementation Requirements

### 1) Node.js JIT & V8 Optimization
- Target modern Node.js LTS with V8 TurboFan/Orinoco. Keep hot loops monomorphic and avoid hidden-class thrash: predefine object shapes for telemetry frames; avoid dynamic property addition mid-flight.
- Use typed arrays or `Buffer` where beneficial. Avoid `delete` and polymorphic call sites inside the polling loop.
- Prefer `const/let` and `for` loops over array methods inside the 100 Hz path. Inline critical calculations (gas drift/clutch noise) with numeric operations; avoid boxing.
- Document rationale in comments: “Hot path for TurboFan; stable shapes for JIT.”

### 2) WinMM FFI via `ffi-napi` + `ref-napi`
- Map `JOYINFOEX` precisely:
  - DWORD `dwSize`, `dwFlags`, `dwXpos`, `dwYpos`, `dwZpos`, `dwRpos`, `dwUpos`, `dwVpos`, `dwButtons`, `dwButtonNumber`, `dwPOV`, `dwReserved1`, `dwReserved2`.
  - Size = `48` bytes (12 × 4-byte DWORD). Use `ref.types.uint32`.
- Flags: support the same JOY_RETURN* constants as the PS script (`JOY_RETURNALL` default = 255). Expose a config flag to override.
- FFI binding signature: `MMRESULT joyGetPosEx(UINT uJoyID, LPJOYINFOEX pji);`.
- Ensure `dwSize` and `dwFlags` are initialized on every call; zero the struct before use. Handle non-zero return codes with retries/backoff and reconnect notifications identical to PS behavior.
- Device selection: implement auto-detect by Vendor/Product IDs and JoystickID parity with PS logic (search devices if JoystickID=17 default). Mirror the “no fallback to joystick 0 unless explicitly requested.”

### 3) Telemetry & Detection Logic
- Port the PS algorithms directly: deadzone normalization, logical percent calculations (physical vs logical), gas drift detection window/cooldown/timeout, clutch noise detection with margin and sample repeat, event batching and timestamps, disconnect/reconnect frames, legacy fields (`fullLoopTime_ms`, etc.).
- Preserve HTTP telemetry JSON schema (field names, numeric types, batchId semantics) so the dashboard remains compatible. If the Node server also exposes a compatibility HTTP endpoint, reuse same JSON shape.
- Expose configuration via CLI/env/config file mirroring PS parameters (sleep time, margins, deadzones, monitor toggles, TTS toggles, flags, priority/affinity hints). Provide sane defaults matching PS script defaults.
- Maintain 100 ms (or faster) loop; target 100–200 Hz to align with WebSocket push.
- Keep debug/verbose logging and optional raw output similar to PS (`DebugRaw`).

### 4) Event Loop, Concurrency, and Performance (Galvatron)
- Use a dedicated tight polling loop, optionally in a `Worker` thread, to keep FFI off the main event loop. Communicate with the WebSocket broadcast loop via `MessageChannel` or shared ring buffer.
- Run WebSocket server on the main thread; keep serialization lightweight (preallocated buffer or stable JSON shapes).
- Pin process priority/CPU affinity if available on Windows (via `node-process-windows` or documented PowerShell commands). Mirror PS flags: `--idle`, `--belownormal`, `--affinitymask`.
- Use `setInterval` or `setTimeout` with drift correction, or a custom loop using `hrtime.bigint()` for consistent 100 Hz cadence.

### 5) WebSockets (Server & Client)
- Use the `ws` library. On client connect, send latest telemetry frames at ≥100 Hz. Implement backpressure handling (drop/overwrite frames if the client is slow rather than blocking the polling loop).
- Optional: expose a lightweight HTTP endpoint (`/telemetry`) for legacy polling if desired; but primary path is WebSocket.
- Implement reconnect logic on the client (browser) with exponential backoff; set status pills (`DISCONNECTED`, `FFW CATCH-UP`) using existing DOM IDs.

### 6) Async TTS
- Use a non-blocking library (e.g., `say` or `@google-cloud/text-to-speech` if available locally) wrapped so calls run off the main thread (worker or `child_process`).
- Preserve PS speech triggers: gas drift and clutch noise alerts with cooldowns. Ensure speech scheduling does not stall telemetry; queue and play asynchronously.

### 7) Frontend Surgical Changes (PedDash)
- Copy the existing `PedDash.html` into `NodeJs-FanatecPedals/PedDash.html`.
- Add a configuration toggle (in the existing Config tab panel) to select **Data Source: Legacy HTTP fetch vs. New WebSocket**.
- Implement a WebSocket client:
  - Connect to `ws://localhost:<port>` (configurable).
  - On `message`, parse telemetry JSON and feed existing rendering pipeline. Preserve all existing gauge, ticker, event, lag, and telemetry map logic.
  - Replace/augment `dataLoop()` so that when WebSocket mode is active, it subscribes once and stops the periodic `fetch` timer; when legacy mode is chosen, retain the current `fetch` loop untouched.
  - Update connection status indicators (`disc-indicator`, `ffw-indicator`, lag counters) using WebSocket events and frame timestamps.
- Keep all existing UI/UX, styles, and calculations; only add the minimal plumbing for WebSocket mode and the new toggle.

### 8) Error Handling & Logging
- Mirror PS error conditions: device not found, WinMM errors, JSON serialization issues. Emit console logs and optional on-screen error messages (via existing `#global-error`).
- Graceful shutdown: close WebSocket, stop polling loop, release FFI resources.

### 9) Testing & Validation
- Include a small script or npm test to validate JOYINFOEX struct size/offsets and to sanity-check telemetry output against stub data.
- Manual test plan: ensure dashboard receives data at 100–200 Hz, TTS fires asynchronously, and gas/clutch alerts match PS behavior under simulated inputs.

### 10) Output
- Produce the full Node.js codebase under `NodeJs-FanatecPedals/` per the structure above, ready to run on Windows 11 (Galvatron). Keep npm scripts for start/dev/test. Do not remove or alter legacy files outside this new directory.

