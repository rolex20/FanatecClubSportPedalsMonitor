# NodeJs Fanatec Pedals Bridge

A Node.js replacement for `FanatecPedals.ps1` that keeps the same telemetry payloads while modernizing the runtime with WebSockets and worker-threaded WinMM polling.

## Features
- WinMM `joyGetPosEx` polling via `ffi-napi` with JOYINFOEX parity (48-byte struct).
- Worker-thread loop targets >=100 Hz and keeps the main event loop responsive.
- WebSocket streaming (default `ws://localhost:8182`) plus a legacy HTTP endpoint on `http://localhost:8181/` that mirrors the PowerShell JSON shape.
- Async text-to-speech queue using a worker-wrapped `say` binding (non-blocking for telemetry cadence).
- Gas drift and clutch noise detection aligned with the PowerShell script defaults, including cooldowns and deadzone math.

## Layout
```
NodeJs-FanatecPedals/
  README.md
  package.json
  src/
    server.js           # Entry point: HTTP + WebSocket servers
    ffi/joy.js          # WinMM FFI bindings and JOYINFOEX struct
    logic/telemetry.js  # Worker-thread polling + detection logic
    logic/tts.js        # Async TTS helper
    logic/struct-check.js # Simple struct size check (npm test)
    config/index.js     # Defaults + .ini/CLI/env loader
    util/logger.js      # Structured logger
  PedDash.html          # Dashboard with WebSocket toggle
```

## Install
```bash
cd NodeJs-FanatecPedals
npm install
```

## Run
```bash
npm start
```

### CLI / ENV switches
- `--pollIntervalMs` (env `SLEEPTIME`): loop interval in ms (default 10 for 100 Hz).
- Deadzone/debounce flags mirror the PowerShell script: `--margin`, `--clutchRepeat`, `--gasDeadzoneIn`, `--gasDeadzoneOut`, `--brakeDeadzoneIn`, `--brakeDeadzoneOut`, `--clutchDeadzoneIn`, `--clutchDeadzoneOut`, `--gasWindow`, `--gasCooldown`, `--gasTimeout`, `--gasMinUsage`.
- Device selection: `--joystickId` (default 17 for auto-detect parity), `--vendorId`, `--productId`, `--joyFlags` (JOY_RETURNALL=255 default).
- Feature flags: `--monitorClutch`, `--monitorGas`, `--telemetry`, `--tts`, `--noTts`, `--debugRaw`, `--verbose`.
- Ports: `--httpPort` (default 8181) and `--wsPort` (default 8182).
- Config file: `--configFile ./FanatecPedals.current.example.ini` (INI keys match the PowerShell script names).

## Dashboard
Use the bundled `PedDash.html` inside this folder. Choose **Data Source: WebSocket** to subscribe to the high-rate stream or **Legacy HTTP** to keep the original polling loop. The WebSocket client auto-reconnects with exponential backoff and feeds the same rendering pipeline used by the legacy fetch loop.

## Testing
```bash
npm test
```
Validates JOYINFOEX struct size (48 bytes). Hardware polling paths require Windows with WinMM available.
