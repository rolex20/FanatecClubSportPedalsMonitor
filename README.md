# Fanatec ClubSport Pedals Monitor

A Windows console tool that monitors **Fanatec ClubSport Pedals V2** (and similar devices) for:

- **Clutch Hall sensor noise** (used as rudder in flight sims).
- **Gas pedal drift** (hall-sensor/pot no longer reaching full travel - 1st gen hall sensor with issues).

It runs alongside heavy simulators (DCS, MSFS, etc.) with negligible CPU usage and is intentionally **not designed for > 24h continuous runs**, so `GetTickCount()` wrap-around is not handled (and not needed in the intended use case).

This project is implemented in **C (Win32 / WinMM)** and **PowerShell**, and uses techniques such as:

- Joystick polling via `joyGetPosEx`.
- Axis normalization into a user-friendly `0 .. axisMax` space.
- State-machine–based signal analysis for clutch noise and gas drift.
- Real-time deadzone-out estimation and optional auto-adjustment.
- Process priority/affinity tuning to avoid impacting simulator threads.
- A single-instance guard via a named mutex.
- Optimized integer-to-string handling with **in-place right-to-left digit writing** (no `snprintf` in the hot path).
- Safer TTS launching via **`CreateProcessA`** (no shell, no quoting issues) with a PowerShell helper script.

It’s a compact but realistic example of low-level Windows systems programming with C and PowerShell working together.

---

## Background / Why This Exists

Years after buying (2014) a **Fanatec ClubSport Pedals V2 (US)**, the **clutch pedal** (left pedal, Hall sensor) started generating random noise. For racing this wasn’t critical (I mostly use paddle shifters), but I also use these pedals as **rudder pedals in flight sims** via Joystick Gremlin. The noise would occasionally cause my aircraft to yaw or drift in DCS, Falcon BMS, P3D, Strike Fighters, and Microsoft Flight Simulator.

Fanatec doesn’t sell replacement Hall sensors for these pedals, so instead of throwing them away I wrote a small C program that:

- Polls the pedal axis at a fixed interval.
- Detects when the clutch/rudder signal is “stuck” or noisy while gas is idle.
- Calls a PowerShell TTS script so I hear something like **“rudder, rudder”** in my headphones.

When I hear the warning, I pump the clutch a few times; the noise clears and the pedals are usable again. Because the monitor is extremely light on CPU and can be pinned to cheaper cores, it doesn’t hurt simulator performance.

Later, the **gas pedal** started to **drift** and stopped reaching 100% consistently. That’s when I extended the program to monitor gas usage, detect drift, and then went further to **estimate and optionally auto-adjust the “deadzone-out”** (max saturation) value that games use for throttle calibration. The latest version refines how those alerts and estimates are delivered, especially via TTS.

---

## Key Features

### Clutch noise monitoring

- Detects Hall sensor noise on the clutch axis (used as rudder in flight sims).
- Only considers clutch noise when:
  - Gas is idle (in its configured idle deadzone).
  - Clutch is not fully released.
- Uses a “stickiness” metric over several samples to detect a “stuck” position instead of reacting to single-sample spikes.
- Calls `sayRudder.ps1` (via a fixed PowerShell command) to:
  - Speak a rudder warning, and
  - Print a textual message (done inside the PowerShell script).

### Gas drift monitoring

- Monitors the **gas pedal** for failure to reach full travel over time.
- Uses a **racing state machine**:
  - When the gas moves beyond the idle band, you’re considered **racing**.
  - If you haven’t reached “full throttle” in `--gas-window` seconds, the window is evaluated.
  - The algorithm considers the **maximum gas travel** seen in that window, not just the last sample.
- The drift detector only warns if:
  - The maximum usage in the window exceeds `--gas-min-usage` (% of travel) so we have “real” usage.
  - And that maximum is suspiciously low vs the expected full-throttle threshold.
- Triggers `sayGas.ps1` with an integer argument representing the **maximum gas percentage reached** (e.g. “83”), so the script can speak and print something like “Gas 83%”.

### Axis normalization

Pedal hardware, especially Fanatec in raw mode, often reports **inverted** values:

- Raw: `idle ~ axisMax`, `pressed ~ 0`.

The monitor normalizes axes into a consistent model:

- `0 = pedal at rest`, `axisMax = pedal fully pressed`.

If your hardware already reports `0 .. axisMax` with `0 = idle`, you can disable this step:

```bash
--no-axis-normalization
````

In that case, the raw values are used directly.

### Gas deadzone-out estimation (TTS + console via script)

`--estimate-gas-deadzone-out`:

* Keeps a rolling window whose length is `--gas-cooldown` seconds while you are racing.

* In each window with sufficient usage (peak ≥ `--gas-min-usage`%), it records the **maximum gas percentage** observed.

* Tracks a **monotonically non-increasing** best estimate of the reachable maximum over the lifetime of the current device attachment.

* When the best estimate decreases and at least one cooldown period has elapsed:

  * Builds a TTS message like `"New deadzone estimation: 93"` entirely in C using an in-place RTL digit writer.
  * Calls `saySomething.ps1` via `CreateProcessA`, so:

    * The message is spoken.
    * The PowerShell script can also print an informational line to the console, e.g.:

      ```text
      [Estimate] Suggested --gas-deadzone-out: 93
      ```

* Estimation runs regardless of `--verbose`; it is a core behavior of the flag, not just a logging feature.

You can then plug the estimated value into:

* Your game’s **deadzone-out / max saturation** setting, and/or
* This monitor’s own `--gas-deadzone-out` option.

### Optional auto-adjust of gas deadzone-out

`--adjust-deadzone-out-with-minimum N`:

* Requires **both** `--monitor-gas` and `--estimate-gas-deadzone-out`.
* Uses the same estimator as above.
* Automatically **decreases** `gas_deadzone_out` over time to match the best observed maximum, but:

  * **Never** below `N` (0–100).
  * Only when:

    * The new best estimate is **lower** than the current `gas_deadzone_out`.
    * And **≥ N**.
    * And the window had meaningful usage (peak ≥ `--gas-min-usage`%).

When an adjustment is applied, the program prints something like:

```text
[AutoAdjust] gas-deadzone-out updated to 92 (min=90)
```

and updates the internal full-throttle threshold (`gasFullMin`) immediately. This keeps the drift detector aligned with a weakening potentiometer without letting the threshold drop to unrealistic values.

### Auto-reconnect by VID/PID

* `--vendor-id HEX`, `--product-id HEX`:

  * The program can detect when the USB device is unplugged.
  * It periodically searches for a joystick with matching VID/PID.
  * When found, it:

    * Reinitializes axis ranges (`axisMax`, `gasIdleMax`, `gasFullMin`).
    * Resets gas/clutch and estimator state.
    * Announces reconnection via TTS (“Controller found. Resuming monitoring.”).
* Estimation state (`best_estimate_percent`, etc.) is reset on reconnect, so each device attachment is treated fresh.

### Debugging & diagnostics

* `--verbose`:

  * Prints current gas and clutch values each iteration.
  * Prints configuration details at startup (axis max, gas/clutch config, whether estimation and auto-adjust are enabled).
* `--debug-raw`:

  * In verbose mode, prints **raw** and **normalized** values for both gas and clutch, which is ideal for initial calibration.
* `--no_buffer`:

  * Disables stdout buffering (helpful when logging to a file or piping into another tool).
* Startup banner:

  * On launch, the program prints:

    ```text
    Fanatec Pedals Monitor started.
    ```

  so you know immediately that the monitor process is running.

### Performance & integration

* `--idle` and `--belownormal`:

  * Adjust process priority so the monitor reliably yields to simulator threads.
* `--affinitymask N`:

  * Pins the monitor to specific CPU cores.
  * Common pattern: pin it to efficiency cores on hybrid CPUs.
* Single-instance guard:

  * Uses a named mutex (`fanatec_monitor_single_instance_mutex`).
  * If a second instance is started:

    * A TTS message is spoken (“Error. Another instance of Fanatec Monitor is already running.”).
    * An error is printed and the process exits.

---

## Supported Platforms & Requirements

* **OS:** Windows 10 / 11 (x64).
* **Compiler:** MinGW-w64 or any Windows C compiler providing:

  * `windows.h`
  * `mmsystem.h`
  * `getopt.h` (or equivalent `getopt_long`)
  * `assert.h`
* **Linking:** link against `winmm.lib` (for WinMM joystick APIs).
* **IDE note (NetBeans):**
  With NetBeans IDE 18, it may be necessary to add `C:\Windows\System32\winmm.dll` in
  `Run → Set Project Configuration → Customize → Build → Linker → Libraries → Add Library File`
  to satisfy `joyGetPosEx()` linkage.
* **Hardware:** Designed and tested with **Fanatec ClubSport Pedals V2**, but works with any WinMM joystick-like device.

---

## Build Instructions

Example MinGW-w64 build:

```bash
x86_64-w64-mingw32-gcc -O2 -Wall ^
    -o fanatecmonitor.exe main.c ^
    -lwinmm
```

Make sure the following PowerShell scripts are in the same folder as `fanatecmonitor.exe`:

* `sayRudder.ps1` – TTS + text warning for clutch/rudder noise.
* `sayGas.ps1` – TTS + text warning announcing maximum gas percentage.
* `saySomething.ps1` – generic TTS helper used for reconnect, duplicate-instance, estimation messages, etc.
* `sayDuplicateInstance.ps1` – TTS + text notification for “already running” cases (if you keep using the legacy script name).

---

## Quick Start

### Show help

```bash
fanatecmonitor.exe --help
```

If you run the program without enough information to identify a device, it will print help and exit.

---

## Typical Launch Examples

### Flight sim: clutch as rudder + gas drift monitoring

Example similar to the original “always on” clutch monitor, now with gas monitoring enabled and default deadzones:

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

* `--flags 266` = `JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY` (Fanatec raw 0–1023).
* `--iterations 90000` with `--sleep 1000` ≈ 25 hours, which is right at the intended limit.
* `--idle` + `--affinitymask 983040` keeps the monitor on specific low-priority cores.

### Racing / Forza Motorsport: gas drift calibration with typical 5/93 deadzones

For a racing title using deadzones similar to Forza (5% input deadzone, 93% output deadzone):

```bash
fanatecmonitor.exe ^
  --monitor-gas ^
  --joystick 1 ^
  --flags 266 ^
  --iterations 0 ^                  # 0 = run until you close it
  --sleep 1000 ^                    # poll every second
  --gas-deadzone-in 5 ^             # 5% idle deadzone
  --gas-deadzone-out 93 ^           # expect near-full travel at ~93%
  --gas-window 30 ^                 # 30 seconds to see full throttle
  --gas-timeout 10 ^                # 10 seconds idle -> assume menu/pause
  --gas-cooldown 60 ^               # at most 1 gas alert per minute
  --gas-min-usage 20 ^              # ignore windows with usage <= 20%
  --estimate-gas-deadzone-out
```

This setup:

* Warns you via TTS if gas drift is detected (“Gas NN%” from `sayGas.ps1`).
* Periodically announces new deadzone estimates via `saySomething.ps1` (“New deadzone estimation: NN”), which you can plug back into the game or into `--gas-deadzone-out`.

### Calibration session with auto-adjust

If you want the monitor itself to auto-adjust `--gas-deadzone-out` based on observed pedal behavior, run a calibration session where you intentionally floor the gas several times:

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

* The estimator observes your maximum gas travel in each window.
* If it finds that you consistently only reach, say, 92–93%, it will:

  * Announce a new deadzone estimate via TTS, and
  * Apply a one-way downward adjustment to `gas-deadzone-out` (never below 90 in this example),
  * Printing an `[AutoAdjust] ...` line to the console.

---

## Command Line Options (Reference)

### Core options

* `--joystick ID`
  Joystick ID (0–15) to monitor. Required unless VID/PID are provided.

* `--vendor-id HEX`, `--product-id HEX`
  Vendor and Product IDs (hex, e.g. `0EB7` and `1839`) used for auto-reconnect.

* `--iterations N`
  Number of iterations in the main loop.

  * Default: `1`.
  * `0` = run indefinitely.
    Combined with `--sleep`, it defines the total runtime.

* `--sleep MS`
  Delay between polls (milliseconds). Default: `1000`. Must be `> 0`.

* `--flags N`
  WinMM `JOYINFOEX.dwFlags`. Default: `JOY_RETURNALL`.
  For Fanatec raw input, `266` is common (`JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY`).

* `--margin N`
  Clutch stickiness margin (0–100). Default: `5`.

* `--no_buffer`
  Disable stdout buffering.

* `--verbose`, `--brief`
  Turn verbose logging on/off.

### Clutch monitor options

* `--monitor-clutch`
  Enable clutch/rudder noise monitoring.

* `--clutch-repeat N`
  Consecutive “stuck” samples required to trigger an alert.

  * Default: `4`.
  * If you lower `--sleep` from 1000 ms to something like 100 ms, consider increasing this to preserve a similar *time* window.

### Gas monitor options

* `--monitor-gas`
  Enable gas drift monitoring.

* `--gas-deadzone-in P`
  Idle band size (0–100%). Default: `5`.

* `--gas-deadzone-out P`
  Full-throttle threshold (0–100%). Default: `93`.

* `--gas-window S`
  Window length (seconds) before evaluating drift. Default: `30`.

* `--gas-timeout S`
  Idle timeout (seconds) before treating the session as paused/menu. Default: `10`.

* `--gas-cooldown S`
  Minimum time (seconds) between gas drift alerts. Default: `60`.

* `--gas-min-usage P`
  Minimum peak usage (0–100%) required in a window for drift detection / estimation to be considered meaningful.
  Default: `20`.

* `--estimate-gas-deadzone-out`
  Enable deadzone-out estimation:

  * Internally tracks a best (lowest) observed peak gas percentage.
  * Announces new estimates via TTS and allows your PowerShell to print a console line.
  * Requires `--monitor-gas`.

* `--adjust-deadzone-out-with-minimum N`
  Enable automatic downward adjustment of `--gas-deadzone-out`, but never below `N` (0–100).

  * Requires `--monitor-gas` **and** `--estimate-gas-deadzone-out`.
  * Uses the estimator results and only adjusts when the new estimate is lower than the current `gas-deadzone-out` and ≥ `N`.

### Axis & debug options

* `--no-axis-normalization`
  Disable automatic inversion. Use this if your device already reports `0 = idle, max = fully pressed`.

* `--debug-raw`
  In verbose mode, print both raw and normalized gas/clutch values for easier calibration.

### Performance options

* `--idle`
  Set process priority to `IDLE_PRIORITY_CLASS`.

* `--belownormal`
  Set process priority to `BELOW_NORMAL_PRIORITY_CLASS`.

* `--affinitymask N`
  CPU affinity bitmask (decimal). Useful to pin the monitor to specific cores.

---

## How the Detection Algorithms Work

### Clutch noise

* Only active when gas is idle and the clutch is not fully released.
* Computes `closure` = absolute difference between consecutive normalized clutch values.
* Converts `margin` from percentage to absolute units: `axisMargin = axisMax * margin / 100`.
* If `closure <= axisMargin` for `--clutch-repeat` consecutive samples, it considers the clutch axis “stuck” and:

  * Invokes `sayRudder.ps1` via a fixed PowerShell command.
* This avoids reacting to transient noise or normal clutch use.

### Gas drift

* Maintains an `isRacing` flag based on recent gas activity:

  * Gas > idle band ⇒ racing, windows start/reset, `lastGasActivityTime` updated.
  * Gas in idle band for more than `--gas-timeout` seconds ⇒ assume menu/pause and pause drift detection.
* During racing:

  * Tracks `peakGasInWindow` = maximum normalized gas value since the last full-throttle event.
  * If gas reaches `gasFullMin` (derived from `--gas-deadzone-out`), the window is reset.
  * If `gas_window` seconds pass without reaching `gasFullMin`:

    * And `gas_cooldown` seconds have passed since the last alert.
    * And the peak usage in that window is **strictly greater** than `--gas-min-usage`:

      * It computes the maximum travel percentage.
      * Calls `sayGas.ps1` with that value as argument.
* Drift detection uses `>` against `gas_min_usage_percent` to be slightly more conservative than the estimator, keeping alerts quieter while still allowing the estimator to learn from borderline windows.

### Estimator vs drift threshold

* Drift detection uses:

  ```c
  if (percentReached > gas_min_usage_percent) { ... }   // strict >
  ```

* Estimation uses:

  ```c
  if (estimate_window_peak_percent >= gas_min_usage_percent) { ... }  // >=
  ```

The difference is deliberate:

* The **alert** path is conservative (avoids nagging you on borderline usage).
* The **estimator** is slightly more permissive (it can learn even from equal-to-threshold windows, which still contain useful information about maximum reachable travel).

---

## Changelog (Short)

### Original Version

* Lightweight C tool to monitor the **clutch pedal** and detect Hall sensor noise.
* Only cared about clutch when the gas pedal was idle.
* Triggered `sayRudder.ps1` to speak a “rudder” warning.
* Designed to be extremely light on CPU so it could run side-by-side with flight sims.

### First Major Extension

* **Axis normalization** for inverted raw axes into a 0–max “human” model.
* **Gas drift monitoring** using a `isRacing` state machine and timing windows.
* **Gas deadzone-out estimation** via `--estimate-gas-deadzone-out`.
* **Optional auto-adjust** via `--adjust-deadzone-out-with-minimum N`.
* More tuning parameters:

  * Clutch: `--margin`, `--clutch-repeat`.
  * Gas: `--gas-deadzone-in`, `--gas-deadzone-out`, `--gas-window`, `--gas-timeout`, `--gas-cooldown`, `--gas-min-usage`.
* VID/PID-based auto-reconnect with state reset.
* Debug modes (`--verbose`, `--debug-raw`) and output control (`--no_buffer`).
* Process priority and CPU affinity tuning.
* Single-instance guard via named mutex.

### Latest Refinements (this version)

* **Safer, faster TTS integration:**

  * Replaced `system()` for generic TTS with a dedicated `Speak()` helper using `CreateProcessA` (no shell, fewer quoting issues).
  * `Speak()` uses a fixed executable path and builds a mutable command line for `saySomething.ps1`, then closes process handles immediately.
* **In-place integer formatting for hot paths:**

  * Introduced `append_digits_from_right()` with debug-only `assert`s:

    * Writes digits right-to-left into static buffers.
    * Avoids `snprintf` in hot code paths (gas alerts, estimator messages).
    * Fills left-of-digits with spaces up to a marker char (e.g., `':'` or `' '`), neatly overwriting any previous content.
  * Keeps `lwan_uint32_to_str()` available but removes it from the hottest paths.
* **TTS-driven deadzone estimation reporting:**

  * Instead of printing estimates directly from C, estimation builds messages like `"New deadzone estimation:NN"` and hands them to `saySomething.ps1`.
  * The PowerShell script is responsible for speaking and printing the message (you can keep or format the `[Estimate]` prefix there).
* **Improved single-instance behavior:**

  * Duplicate instance detection now:

    * Uses `CreateMutexA` + `GetLastError`.
    * Speaks a clear error message string via `Speak()`.
    * Prints the same message via `perror()` before exiting.
* **Reconnect robustness:**

  * On reconnect after a disconnect:

    * Recomputes `axisMax`, `gasIdleMax`, and `gasFullMin`.
    * Resets racing/clutch/estimation state to avoid stale alerts.
* **Small usability touches:**

  * Always prints a startup banner: `"Fanatec Pedals Monitor started."`.
  * Help text / README aligned to clarify:

    * Default `iterations` = 1, `0` = infinite.
    * `--sleep` must be `> 0`.
    * Requirements for `--estimate-gas-deadzone-out` and `--adjust-deadzone-out-with-minimum`.

---

## License

See the `LICENSE` file in this repository for licensing details.


## License

See the `LICENSE` file in this repository for licensing details.

