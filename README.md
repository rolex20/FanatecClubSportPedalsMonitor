# Fanatec ClubSport Pedals Monitor

A lightweight Windows console tool that monitors **Fanatec ClubSport Pedals V2** (and similar WinMM joystick devices) for:

- **Clutch Hall sensor noise** (often mapped as rudder in flight sims → random yaw spikes).
- **Gas pedal drift** (pedal no longer reaching consistent “full travel” over time).

It runs alongside heavy simulators (DCS, MSFS, etc.) with negligible CPU usage and is intentionally **not designed for > 24h continuous runs**, so `GetTickCount()` wrap-around is not handled (and not needed in the intended use case).

---

## Techniques & technologies used (quick list)

This project uses **low-level Windows systems programming in C**: **single-instance enforcement** using a named mutex, **process priority + CPU affinity** tuning for “don’t disturb the sim” behavior, optional **shared-memory telemetry** (file mapping + event signaling) with Windows security descriptor handling for cross-privilege access, WinMM joystick polling (`joyGetPosEx`) with optional raw mode, deterministic **state-machine signal analysis** (clutch stickiness + gas drift windows), **axis normalization** into consistent semantics (0=idle, max=fully pressed), **high-performance integer formatting** via in-place right-to-left digit writing (no `snprintf` in hot paths), robust device **disconnect/reconnect** recovery using VID/PID scanning,  and optional alert delivery via either **CreateProcessA-launched PowerShell TTS** or an experimental **named-pipe IPC** “SPEAK” command path.

It's implemented in C (Windows API / WinMM) (x64) and PowerShell with “performance-minded” Windows programming to help you keep your old Fanatec hardware under control.

---

## UI / Dashboard vs minimal console tool

If you want a **GUI/dashboard**, run **`PedDash.html`** together with **`FanatecPedals.ps1`**.

That pairing is the recommended way to **visualize pedal travel** and quickly discover good initial **deadzone-in / deadzone-out** values for your sim racing game.

If you want a **minimal, text-first program** that can run with very low overhead and simply monitor + warn you (console + optional TTS), use this C program (`fanatecmonitor.exe`) as documented here.

> Note on legacy integration: earlier experiments included other bridge/dashboard plumbing. Today, the recommended GUI/dashboard path is **PedDash.html + FanatecPedals.ps1**. This C tool is designed to be useful **standalone**.

I also have the oldest/initial c program (only supported the clutch pedal for flight sims) in /original-old-c-program

In the future I plan to remove some code from the current main c program and remove telemetry, ipc and other experimental features now moved to FanatecPedals.ps1 and PedDash.html

---

## Background / why this exists

Years after buying (2014) a **Fanatec ClubSport Pedals V2 (US)**, the **clutch pedal** (left pedal, Hall sensor) started generating random noise. For racing this wasn’t critical (I mostly use paddle shifters), but I also use these pedals as **rudder pedals in flight sims** via Joystick Gremlin. The noise would occasionally cause my aircraft to yaw or drift in DCS, Falcon BMS, P3D, Strike Fighters, and Microsoft Flight Simulator.

Fanatec doesn’t sell replacement Hall sensors for these pedals, so instead of throwing them away I wrote a small C program that:

- Polls the pedal axes at a fixed interval.
- Detects when the clutch/rudder signal is “stuck” (sticky/noisy) while the gas is idle.
- Alerts me (console + optional TTS), so I can pump the clutch a few times to clear the noise.

Later, the **gas pedal** started to **drift** and stopped reaching 100% consistently. That’s when I extended the program to monitor gas usage, detect drift, and then went further to **estimate (and optionally auto-adjust) the “deadzone-out / max saturation”** value used for throttle calibration.

---

## Key features

### 1) Clutch noise monitoring (rudder spikes)

- Detects clutch Hall sensor noise on the clutch axis.
- Only considers clutch noise when:
  - Gas is idle (in its configured idle band).
  - Clutch is not fully released.
- Uses a “stickiness” metric over several samples to avoid reacting to single-sample spikes.
- When a clutch-noise condition is detected, the program triggers an alert with the text **`Rudder`**.

### 2) Gas drift monitoring (not reaching full travel)

- Monitors the gas pedal for failure to reach expected “full throttle” over time.
- Uses a **racing state machine**:
  - When the gas moves beyond the idle band, you’re considered **racing**.
  - If you haven’t reached “full throttle” in `--gas-window` seconds, the window is evaluated.
  - The algorithm uses the **maximum gas travel** seen in that window (peak), not just the last sample.
- Drift alerts are rate-limited by `--gas-cooldown`.
- Alerts only fire if the window had meaningful usage: peak usage must be **strictly greater** than `--gas-min-usage` (%).

When drift is detected, the program constructs a message like **`Gas NN percent.`** (e.g., “Gas 83 percent.”) using an in-place digit writer and routes it through the alert pipeline.

### 3) Axis normalization

Pedal hardware (especially Fanatec in raw mode) often reports **inverted** values:

- Raw: `idle ~ axisMax`, `pressed ~ 0`

The monitor normalizes axes into a consistent model:

- `0 = pedal at rest`, `axisMax = pedal fully pressed`

If your hardware already reports `0 .. axisMax` with `0 = idle`, you can disable normalization:

```bash
--no-axis-normalization
````

### 4) Deadzone-out estimation (discover usable “max saturation”)

`--estimate-gas-deadzone-out`:

* Keeps a rolling window whose length is `--gas-cooldown` seconds while you are racing.
* In each window with sufficient usage (peak ≥ `--gas-min-usage`%), it records the **maximum gas percentage** observed.
* Tracks a **monotonically non-increasing** best estimate of your pedal’s reachable maximum during the current device attachment.
* When the best estimate decreases, it announces an updated estimate through the normal alert pipeline.

Estimator comparison behavior is deliberate:

* Drift detection uses strict `>` (quiet, conservative).
* Estimation uses `>=` (learns from borderline windows).

### 5) Optional auto-adjust of gas deadzone-out

`--adjust-deadzone-out-with-minimum N`:

* Requires **both** `--monitor-gas` and `--estimate-gas-deadzone-out`.
* Automatically decreases `gas-deadzone-out` over time to match observed maximum, but:

  * **Never** below `N` (0–100).
  * Only when the estimator finds a new, lower “best” value and that value is still ≥ `N`.
* Prints an `[AutoAdjust] ...` line to the console when an adjustment is applied.

### 6) Auto-reconnect by VID/PID

`--vendor-id HEX --product-id HEX`:

* Detects when the device stops responding.
* Enters a reconnect loop that periodically scans for a joystick with matching VID/PID.
* When found, it resets internal state (gas/clutch/estimator) and resumes monitoring.

### 7) Single-instance guard

A named mutex prevents accidental double-launch:

* If another instance is already running, the program alerts and exits.

### 8) Alert delivery (console + optional TTS)

All alerts go through a single pipeline:

* Console logging (timestamped)
* Optional speech:

  * Default: PowerShell TTS via `CreateProcessA` (helper script)
  * Optional: experimental IPC “SPEAK” command dispatch (discouraged)

---

## Legacy / experimental flags (telemetry, IPC, and TTS knobs)

These exist mainly for curiosity/backward-compatibility and are **discouraged** going forward.

* `--telemetry`
  Enables shared-memory telemetry intended for external consumers (mapping + event). This was originally introduced for older dashboard/bridge experiments. I’m planning to remove this flag in a future cleanup.

* `--ipc`
  Experimental named-pipe “SPEAK” dispatch instead of launching PowerShell for each spoken message. This was an experiment and is planned to be removed. It requires an additional PowerShell suite from another repo. **Recommendation: don’t use `--ipc`** unless you know exactly why you need it.

* `--tts` / `--no-tts`
  TTS is enabled by default and can be disabled. These knobs were most useful in legacy integration scenarios, but you can still use them with the standalone console tool.

If you want a dashboard experience today, prefer **`PedDash.html` + `FanatecPedals.ps1`**.

---

## Supported platforms & requirements

* **OS:** Windows 10 / 11 (x64). (Developed and used on Windows 11.)
* **Compiler:** MinGW-w64 or any Windows C compiler providing:

  * `windows.h`
  * `mmsystem.h`
  * `getopt.h` (or equivalent `getopt_long`)
  * `assert.h`
  * `sddl.h` (for security descriptor helper APIs)
* **Linking:** link against **WinMM** (`-lwinmm` or `winmm.lib`).

---

## Build instructions

Example MinGW-w64 build:

```bash
x86_64-w64-mingw32-gcc -O2 -Wall ^
  -o fanatecmonitor.exe main.c ^
  -lwinmm
```

### NetBeans note (WinMM linkage)

Some NetBeans toolchains may require explicitly adding `winmm` in the project linker settings. If you see missing `joyGetPosEx` linkage errors, ensure WinMM is linked.

---

## Runtime files (PowerShell helper)

If you want spoken alerts (default behavior), keep this script in the same folder as `fanatecmonitor.exe`:

* `saySomething.ps1` — generic TTS helper used for alert speech (gas/clutch alerts, reconnect messages, etc.)

> Legacy note: older versions used per-alert scripts (e.g., separate scripts for gas vs rudder). The current program is designed around “speak this text” through `saySomething.ps1` (or IPC).

---

## Quick start

### Show help

```bash
fanatecmonitor.exe --help
```

If you run the program without enough information to identify a device, it will print help and exit.

---

## Typical launch examples

### Flight sim: clutch as rudder + gas drift monitoring (raw Fanatec input)

```bash
fanatecmonitor.exe ^
  --monitor-clutch --monitor-gas ^
  --joystick 1 ^
  --flags 266 ^
  --iterations 90000 ^
  --sleep 1000 ^
  --margin 1 ^
  --gas-deadzone-in 5 --gas-deadzone-out 93 ^
  --gas-window 30 --gas-timeout 10 --gas-cooldown 60 --gas-min-usage 20 ^
  --vendor-id 0EB7 --product-id 1839 ^
  --idle --affinitymask 983040
```

Notes:

* `--flags 266` = `JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY` (raw 0–1023 axes for typical Fanatec mapping).
* `--iterations 90000` with `--sleep 1000` is about 25 hours (close to the intended limit).
* `--idle` + `--affinitymask ...` keeps the monitor low-impact.

### Racing: drift calibration + estimation

```bash
fanatecmonitor.exe ^
  --monitor-gas ^
  --joystick 1 ^
  --flags 266 ^
  --iterations 0 ^
  --sleep 1000 ^
  --gas-deadzone-in 5 ^
  --gas-deadzone-out 93 ^
  --gas-window 30 ^
  --gas-timeout 10 ^
  --gas-cooldown 60 ^
  --gas-min-usage 20 ^
  --estimate-gas-deadzone-out
```

### Calibration session with auto-adjust

```bash
fanatecmonitor.exe ^
  --monitor-gas ^
  --joystick 1 ^
  --flags 266 ^
  --iterations 0 ^
  --sleep 1000 ^
  --gas-deadzone-in 5 ^
  --gas-deadzone-out 93 ^
  --gas-window 30 ^
  --gas-timeout 10 ^
  --gas-cooldown 60 ^
  --gas-min-usage 20 ^
  --estimate-gas-deadzone-out ^
  --adjust-deadzone-out-with-minimum 90
```

---

## Command line options (reference)

### Device selection / reconnect

* `--joystick ID`
  Joystick ID (0–15) to monitor.

* `--vendor-id HEX`, `--product-id HEX`
  Vendor/Product IDs (hex) used for auto-reconnect scanning.

### Core loop

* `--iterations N`
  Default `1`. `0` = run indefinitely.

* `--sleep MS`
  Delay between polls (ms). Default `1000`. Must be `> 0`.

* `--flags N`
  WinMM `JOYINFOEX.dwFlags`. Default `JOY_RETURNALL`.
  Raw Fanatec setups often use `266` (`JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY`).

* `--verbose`, `--brief`
  Enable/disable verbose iteration logging.

* `--no_buffer`
  Disable stdout buffering.

* `--no-console-banner`
  Suppress the startup banner.

### Clutch monitoring

* `--monitor-clutch`
  Enable clutch/rudder noise monitoring.

* `--margin N`
  Clutch stickiness margin (0–100). Default `5`.

* `--clutch-repeat N`
  Consecutive “stuck” samples required to trigger a clutch alert. Default `4`.

### Gas monitoring / tuning

* `--monitor-gas`
  Enable gas drift monitoring.

* `--gas-deadzone-in P`
  Idle band (0–100). Default `5`.

* `--gas-deadzone-out P`
  Full-throttle threshold (0–100). Default `93`.

* `--gas-window S`
  Seconds to wait for a full-throttle event before evaluating drift. Default `30`.

* `--gas-timeout S`
  Seconds idle before assuming pause/menu (temporarily disables “racing”). Default `10`.

* `--gas-cooldown S`
  Minimum seconds between gas drift alerts. Default `60`.

* `--gas-min-usage P`
  Minimum peak usage (%) required to consider a window meaningful. Default `20`.

* `--estimate-gas-deadzone-out`
  Enable estimation (requires `--monitor-gas`).

* `--adjust-deadzone-out-with-minimum N`
  Auto-adjust deadzone-out downwards, never below `N`. Requires estimation + gas monitoring.

### Axis & diagnostics

* `--no-axis-normalization`
  Disable inversion/normalization and use raw values directly.

* `--debug-raw`
  In verbose mode, print raw and normalized values (gas/clutch).

### Performance / scheduling

* `--idle`
  Set process priority to `IDLE_PRIORITY_CLASS`.

* `--belownormal`
  Set process priority to `BELOW_NORMAL_PRIORITY_CLASS`.

* `--affinitymask N`
  CPU affinity bitmask (decimal).

### Legacy / experimental

* `--telemetry`
  Enable shared-memory telemetry (mapping + event). Discouraged; planned removal.

* `--tts`, `--no-tts`
  Enable/disable spoken alerts (default enabled).

* `--ipc`
  Use experimental IPC “SPEAK” dispatch for speech. Discouraged; planned removal.

---

## How the detection algorithms work (implementation notes)

### Clutch noise (stickiness detector)

* Only active when gas is idle and clutch is not fully released.
* Computes `closure` = absolute difference between consecutive normalized clutch values.
* Converts `margin` percent into absolute units: `axisMargin = axisMax * margin / 100`.
* If `closure <= axisMargin` for `--clutch-repeat` consecutive samples, it alerts “Rudder”.

### Gas drift (windowed peak + racing state)

* Maintains `isRacing`:

  * Gas > idle band → racing, window starts/resets
  * Gas idle for > `--gas-timeout` seconds → pauses racing/drift checks
* While racing:

  * Tracks `peakGasInWindow`
  * Full throttle event (gas ≥ `gasFullMin`) resets the window anchor
  * If `--gas-window` elapses without a full event:

    * rate-limit using `--gas-cooldown`
    * compute peak percent from `peakGasInWindow`
    * alert only if peak percent is strictly greater than `--gas-min-usage`

### Estimator vs drift threshold

* Drift alerts use strict `>` against `gas-min-usage` (quieter).
* Estimation uses `>=` (learns from borderline windows).

---

## Roadmap (pragmatic cleanup)

* Simplify/remove legacy experimental flags (`--telemetry`, `--ipc`) as the modern dashboard experience lives in **PedDash.html + FanatecPedals.ps1**.
* Keep the console tool focused: minimal overhead + robust monitoring + clear alerts.

---

## License

See the `LICENSE` file in this repository for licensing details.

---
