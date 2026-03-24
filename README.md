# Fanatec ClubSport Pedals Monitor

A performance-minded Windows project for keeping older **Fanatec ClubSport Pedals V2** hardware useful instead of throwing it away when sensors start getting noisy or when the pedals stop reaching the same travel they used to.

The practical win is simple:

- it can **warn you with audio** when clutch Hall-sensor noise is starting to act up, so you know it is time to **pump the clutch** and clear it before it ruins a flight
- it can **measure how far the gas pedal is really reaching**, tell you **what deadzone-out / max saturation** you should use in your racing game, and keep monitoring when drift goes even beyond that
- it lets you keep using older hardware that still feels great mechanically, even when the sensors are no longer as perfect as they were on day one

I still use these Fanatec pedals today, more than **12 years later**, and they still work beautifully across my sim racing and flight titles. This repo exists because I would rather understand the hardware, compensate for its age, and keep racing/flying than throw it away and pretend the only solution is buying something new.

This is not a giant commercial driver suite. It is a small family of tools for people who like older hardware, practical fixes, and code that respects both performance and reality.

---

## Techniques & technologies used (quick scan)

This repo is a compact showcase of **performance-minded Windows engineering** across multiple stacks: **low-level C systems programming**, **manual hot-path optimization**, **real-time hardware monitoring**, **PowerShell automation**, **HTML dashboard work**, and a newer **C# / WinUI 3 / Win2D desktop GUI**.

It includes:

- **KUSER_SHARED_DATA** timing reads
- **cache-line-aware struct layout**
- **branch-prediction hints**
- **force-inlined hot paths**
- **manual integer/string formatting without generic `printf`-style machinery in performance-sensitive paths**
- **WinMM joystick interop**
- **state-machine pedal analysis**
- **VID/PID reconnect logic**
- **single-instance Windows process control**
- **CPU affinity and priority tuning**
- **TTS alert pipelines**
- **real-time signal visualization**
- **latency instrumentation**
- **INI-backed runtime configuration**
- **Win2D GPU-accelerated custom rendering**

The goal is practical, not theoretical: diagnose aging pedals, compensate for noisy sensors and drift, and keep good hardware working for years longer than people expect.

---

## Which version should you use?

This repo now contains **three generations** of the same idea, and each one is still useful.

### 1) Start here if you love minimal overhead: the root C monitor (`main.c`)

If you are the kind of user who prefers a small, direct, text-first tool that stays out of the way, this is probably the version you want.

This is the lowest-overhead path in the repo:

- plain C
- WinMM
- console output
- speech alerts
- no GUI stack
- no dashboard effects
- very little nonsense

If the whole point is "tell me when the clutch is getting noisy" or "tell me what my gas pedal is really reaching" without wasting CPU/GPU on pretty things, the C version is the natural first choice.

### 2) Lighter GUI/dashboard route: `PedDash.html` + `FanatecPedals.ps1`

If you want a GUI/dashboard and are comfortable with **PowerShell + HTML**, this is still a practical route.

It is easier to try than the newest WinUI app if you do not want to install the full modern desktop-app stack, but it is also heavier, older, and less elegant.

### 3) Newest and most complete GUI: [`GUI/PedDash`](./GUI/README.md)

If you want the **newest GUI**, the strongest diagnostics, and the best long-term GUI path in this repo, look here:

- **[Open the latest GUI README](./GUI/README.md)**

This version gives you the richest visual experience and the clearest real-time inspection tools, but it asks more from the machine and from the user:

- it requires the **.NET 8 / WinUI 3 / Windows App SDK** stack
- it is a real desktop app, not a tiny monitor
- in my case it can cost **up to about 5% GPU**, because I intentionally used more beautiful rendering features for the gauges and graphs:
  - **Win2D custom rendering**
  - **glow layers / composited visual effects**
  - **real-time waveform drawing and animated gauge updates**

So the tradeoff is honest:

- the **C version** is for minimal overhead
- the **PowerShell/HTML version** is the middle ground
- the **WinUI GUI** is the nicest and most complete, if you are willing to pay the dependency and GPU cost

---

## The repo's archaeology

This project did not appear fully formed.

It started as a small C tool to solve one annoying real-world hardware problem. Then the gas pedal started drifting too. Then came better detection logic, reconnect handling, alerting, dashboards, experiments, and eventually a much more complete GUI.

So yes, this repo has some archaeology in it, and that is intentional.

- The oldest previous C version now lives in [`deprecated/prev_c_program`](./deprecated/prev_c_program)
- The PowerShell/HTML route is still here because it was an important step in the evolution
- The new `GUI` app is the version that is no longer the baby anymore

I like keeping that history visible because it shows the real path: problem, workaround, refinement, over-engineering, cleanup, and then a better version that grows up without pretending the earlier versions never existed.

---

## Background / why this exists

Years after buying these pedals in **2014**, my **Fanatec ClubSport Pedals V2 (US)** started showing the kind of age that good hardware eventually shows if you actually use it for years instead of treating it like a display piece.

The first issue was the **clutch pedal Hall sensor**. In racing this was not a huge deal for me because I mostly use paddle shifters, but I also use these pedals as **rudder pedals in flight sims** through Joystick Gremlin. That meant a noisy clutch axis was no longer just "a little annoying." It could become a real in-sim problem:

- random yaw spikes
- subtle drift
- aircraft pulling when they should not
- that irritating feeling of knowing the bug is not in the sim, not in your mapping, not in your flying, but in aging hardware you still otherwise love

Fanatec did not sell replacement Hall sensors for these pedals, and I was not interested in throwing away a set of pedals that still felt mechanically excellent. So I wrote a small C program that would sit beside the sim, poll the axes, and tell me when the clutch/rudder signal was getting sticky or noisy so I could pump the pedal a few times and clear it.

That alone already made the hardware more usable again.

Then, later, the **gas pedal** started doing something more subtle and more dangerous for racing: it no longer reached full travel consistently. Not catastrophically. Not in a way that screams "broken." Just enough that over time it quietly steals performance from you if you are not paying attention.

That is the kind of failure I dislike the most. The hardware still works. The game still runs. The pedal still moves. But you are no longer actually getting the throttle you think you are getting.

So the project grew.

It stopped being only "warn me when the clutch gets noisy" and became "watch the gas pedal over time, estimate what it is really reaching, tell me what deadzone-out I should use, and keep watching in case the drift gets worse."

That is the reason this repo now has multiple versions and a bit of archaeology in it. It started with one practical fix for one real problem. Then the hardware aged, the needs grew, the tools grew with it, and now the repo contains the whole history of that evolution instead of pretending the final version arrived in one perfect leap.

And the funny part is: the pedals are still here, still in use, still doing their job across sim racing and flight titles more than a decade later.

That is the real victory.

---

## What the root C tool does

The root C monitor is a lightweight Windows console tool for **Fanatec ClubSport Pedals V2** and similar **WinMM joystick devices**.

It monitors for:

- **Clutch Hall sensor noise** that can create rudder spikes in flight simulators
- **Gas drift** when the pedal stops reaching expected full travel
- **Deadzone-out estimation**, and optional in-memory auto-adjust with a safety minimum
- **Device disconnect/reconnect** recovery by VID/PID

It runs alongside heavy simulators like **DCS**, **Falcon BMS**, **MSFS**, and similar software with intentionally minimal overhead.

It is also intentionally **not designed for >24h continuous runs**, so `GetTickCount()` wrap-around is not handled because that is outside the intended use case.

---

## Key features

### 1) Clutch noise monitoring (rudder spikes)

- Detects clutch Hall sensor noise on the clutch axis.
- Only considers clutch noise when:
  - gas is idle (in its configured idle band)
  - clutch is not fully released
- Uses a "stickiness" metric over several samples to avoid reacting to single-sample spikes.
- When a clutch-noise condition is detected, the program triggers an alert with the text **`Rudder`**.

### 2) Gas drift monitoring (not reaching full travel)

- Monitors the gas pedal for failure to reach expected "full throttle" over time.
- Uses a **racing state machine**:
  - when the gas moves beyond the idle band, you are considered **racing**
  - if you have not reached "full throttle" in `--gas-window` seconds, the window is evaluated
  - the algorithm uses the **maximum gas travel** seen in that window (peak), not just the last sample
- Drift alerts are rate-limited by `--gas-cooldown`.
- Alerts only fire if the window had meaningful usage: peak usage must be **strictly greater** than `--gas-min-usage` (%).

When drift is detected, the program constructs a message like **`Gas NN percent.`** using an in-place digit writer and routes it through the alert pipeline.

### 3) Axis normalization

Pedal hardware (especially Fanatec in raw mode) often reports **inverted** values:

- Raw: `idle ~ axisMax`, `pressed ~ 0`

The monitor normalizes axes into a consistent model:

- `0 = pedal at rest`, `axisMax = pedal fully pressed`

If your hardware already reports `0 .. axisMax` with `0 = idle`, you can disable normalization:

```bash
fanatecmonitor.exe --no-axis-normalization
```

### 4) Deadzone-out estimation (discover usable "max saturation")

`--estimate-gas-deadzone-out`:

- Keeps a rolling window whose length is `--gas-cooldown` seconds while you are racing.
- In each window with sufficient usage (peak >= `--gas-min-usage`%), it records the **maximum gas percentage** observed.
- Tracks a **monotonically non-increasing** best estimate of your pedal's reachable maximum during the current device attachment.
- When the best estimate decreases, it announces an updated estimate through the normal alert pipeline.

Estimator comparison behavior is deliberate:

- Drift detection uses strict `>` (quiet, conservative).
- Estimation uses `>=` (learns from borderline windows).

### 5) Optional auto-adjust of gas deadzone-out

`--adjust-deadzone-out-with-minimum N`:

- Requires **both** `--monitor-gas` and `--estimate-gas-deadzone-out`.
- Automatically decreases `gas-deadzone-out` over time to match observed maximum, but:
  - **never** below `N` (0-100)
  - only when the estimator finds a new, lower "best" value and that value is still >= `N`
- Prints an `[AutoAdjust] ...` line to the console when an adjustment is applied.

### 6) Auto-reconnect by VID/PID

`--vendor-id HEX --product-id HEX`:

- Detects when the device stops responding.
- Enters a reconnect loop that periodically scans for a joystick with matching VID/PID.
- When found, it resets internal state (gas/clutch/estimator) and resumes monitoring.

### 7) Single-instance guard

A named mutex prevents accidental double-launch:

- If another instance is already running, the program alerts and exits.

### 8) Alert delivery

All alerts go through a single pipeline:

- timestamped console logging
- spoken alerts through PowerShell TTS by default
- optional experimental IPC "SPEAK" dispatch via `--ipc`

---

## Supported platforms & requirements

- **OS:** Windows 10 / 11 (x64)
- **Compiler:** MinGW-w64 or any Windows C compiler providing:
  - `windows.h`
  - `mmsystem.h`
  - `getopt.h` (or equivalent `getopt_long`)
  - `assert.h`
- **Linking:** link against **WinMM** (`-lwinmm` or `winmm.lib`)

---

## Build instructions

Example MSYS2 UCRT64 / MinGW-w64 build:

```bash
gcc -O3 -Wall -Wextra -std=c11 -o fanatecmonitor.exe main.c -lwinmm
```

For my 14700K E-cores, this is the more aggressive build:

```bash
gcc -O3 -march=gracemont -flto -fwhole-program -mtune=gracemont -Wall -Wextra -std=c11 main.c -o fanatecmonitor.exe -lwinmm
```

### NetBeans note (WinMM linkage)

Some NetBeans toolchains may require explicitly adding `winmm` in the project linker settings. If you see missing `joyGetPosEx` linkage errors, ensure WinMM is linked.

---

## Runtime files (PowerShell helper)

If you want spoken alerts, keep this script in the same folder as `fanatecmonitor.exe`:

- `saySomething.ps1` - generic TTS helper used for alert speech (gas/clutch alerts, reconnect messages, etc.)

> Archaeology note: older versions used per-alert scripts. The current program is designed around "speak this text" through `saySomething.ps1` or the experimental IPC mode.

---

## Quick start

### Show help

```bash
fanatecmonitor.exe --help
```

If you run the program without enough information to identify a device, it will print help and exit.

---

## Typical launch examples

### Flight sim: clutch as rudder + gas monitoring (raw Fanatec input)

```bash
fanatecmonitor.exe --vendor-id 0EB7 --product-id 1839 --flags 266 --iterations 0 --idle --affinitymask 268369920 --margin 1 --monitor-clutch
```

Notes:

- `--flags 266` = `JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY` for a typical raw Fanatec mapping
- `--iterations 0` means run indefinitely
- `--idle` + `--affinitymask ...` keeps the monitor low-impact while the sim gets the machine first

### Racing: gas drift monitoring + estimation + optional auto-adjust

```bash
fanatecmonitor.exe --vendor-id 0EB7 --product-id 1839 --flags 266 --iterations 0 --idle --affinitymask 268369920 --monitor-gas --gas-deadzone-out 100 --estimate-gas-deadzone-out --gas-min-usage 60 --sleep 100 --adjust-deadzone-out-with-minimum 80
```

Notes:

- `--estimate-gas-deadzone-out` learns from real usage over time instead of trusting a single pull
- `--adjust-deadzone-out-with-minimum 80` allows automatic downward correction, but never below 80
- `--sleep 100` gives finer sampling than the default when you want tighter gas monitoring

---

## Command line options (reference)

### Device selection / reconnect

- `--joystick ID`
  Joystick ID (0-15) to monitor.

- `--vendor-id HEX`, `--product-id HEX`
  Vendor/Product IDs (hex) used for auto-reconnect scanning.

### Core loop

- `--iterations N`
  Default `1`. `0` = run indefinitely.

- `--sleep MS`
  Delay between polls (ms). Default `1000`. Must be `> 0`.

- `--flags N`
  WinMM `JOYINFOEX.dwFlags`. Default `JOY_RETURNALL`.
  Raw Fanatec setups often use `266` (`JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY`).

- `--verbose`, `--brief`
  Enable/disable verbose iteration logging.

- `--no_buffer`
  Disable stdout buffering.

- `--no-console-banner`
  Suppress the startup banner.

### Clutch monitoring

- `--monitor-clutch`
  Enable clutch/rudder noise monitoring.

- `--margin N`
  Clutch stickiness margin (0-100). Default `5`.

- `--clutch-repeat N`
  Consecutive "stuck" samples required to trigger a clutch alert. Default `4`.

### Gas monitoring / tuning

- `--monitor-gas`
  Enable gas drift monitoring.

- `--gas-deadzone-in P`
  Idle band (0-100). Default `5`.

- `--gas-deadzone-out P`
  Full-throttle threshold (0-100). Default `93`.

- `--gas-window S`
  Seconds to wait for a full-throttle event before evaluating drift. Default `30`.

- `--gas-timeout S`
  Seconds idle before assuming pause/menu (temporarily disables "racing"). Default `10`.

- `--gas-cooldown S`
  Minimum seconds between gas drift alerts. Default `60`.

- `--gas-min-usage P`
  Minimum peak usage (%) required to consider a window meaningful. Default `20`.

- `--estimate-gas-deadzone-out`
  Enable estimation (requires `--monitor-gas`).

- `--adjust-deadzone-out-with-minimum N`
  Auto-adjust deadzone-out downwards, never below `N`. Requires estimation + gas monitoring.

### Axis & diagnostics

- `--no-axis-normalization`
  Disable inversion/normalization and use raw values directly.

- `--debug-raw`
  In verbose mode, print raw and normalized values (gas/clutch).

### Performance / scheduling

- `--idle`
  Set process priority to `IDLE_PRIORITY_CLASS`.

- `--belownormal`
  Set process priority to `BELOW_NORMAL_PRIORITY_CLASS`.

- `--affinitymask N`
  CPU affinity bitmask (decimal or `0x...`).

### Discouraged / niche

- `--ipc`
  Use experimental IPC "SPEAK" dispatch for speech instead of launching PowerShell. This exists because I enjoy exploring these paths, but the normal PowerShell alert path is the default and the safer recommendation.

---

## How the detection algorithms work (implementation notes)

### Clutch noise (stickiness detector)

- Only active when gas is idle and clutch is not fully released.
- Computes `closure` = absolute difference between consecutive normalized clutch values.
- Converts `margin` percent into absolute units: `axisMargin = axisMax * margin / 100`.
- If `closure <= axisMargin` for `--clutch-repeat` consecutive samples, it alerts "Rudder".

### Gas drift (windowed peak + racing state)

- Maintains `isRacing`:
  - gas > idle band -> racing, window starts/resets
  - gas idle for > `--gas-timeout` seconds -> pauses racing/drift checks
- While racing:
  - tracks `peakGasInWindow`
  - full throttle event (gas >= `gasFullMin`) resets the window anchor
  - if `--gas-window` elapses without a full event:
    - rate-limit using `--gas-cooldown`
    - compute peak percent from `peakGasInWindow`
    - alert only if peak percent is strictly greater than `--gas-min-usage`

### Estimator vs drift threshold

- Drift alerts use strict `>` against `gas-min-usage` (quieter).
- Estimation uses `>=` (learns from borderline windows).

---

## Why keep all three versions

Each version solves a different problem well:

- the **C tool** is the smallest and simplest monitor
- the **PowerShell/HTML version** is flexible and easier to try if you already live comfortably in that stack
- the **C# WinUI version** is the current "best GUI" path with more structure, more diagnostics, and a better long-term desktop foundation

I keep them all because they reflect different tradeoffs, not because they are duplicates.

---

## Roadmap (pragmatic cleanup)

- Keep the console tool focused: minimal overhead + robust monitoring + clear alerts
- Keep the archaeology visible, but keep the current docs honest about which version is current, which one is leanest, and which one asks more from the machine
- Continue treating the repo as both a useful hardware-rescue toolkit and a place to enjoy systems/performance work

---

## License

See the `LICENSE` file in this repository for licensing details.

---
