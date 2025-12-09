# Fanatec ClubSport Pedals Monitor

A tiny Windows console tool that monitors **Fanatec ClubSport Pedals V2** (and similar devices) for:

* **Clutch Hall sensor noise** (used as rudder in flight sims).
* **Gas pedal drift** (potentiometer no longer reaching full travel).

It runs alongside heavy simulators (DCS, MSFS, etc.) with negligible CPU usage.

This project is implemented in **C (Win32 / WinMM)** and **PowerShell**, and uses techniques like **joystick polling via `joyGetPosEx`**, **state machine–based signal analysis**, **axis normalization**, **process priority/affinity tuning**, **optimized integer to string conversion**, and **single instance synchronization via a named mutex**. 

---

## Background / Why This Exists

In 2014 I bought a **Fanatec ClubSport Pedals V2 (US)** expecting Hall sensors to be the end of potentiometer noise forever. After a few years, the **clutch pedal** (left pedal) started generating random noise. In racing titles this didn’t matter much (I use paddle shifters), but I also use these pedals as **rudder pedals in flight sims** via a merged setup in Joystick Gremlin. The noise sometimes caused my aircraft to yaw unpredictably in DCS, Falcon BMS, P3D, Strike Fighters, and Microsoft Flight Simulator.

Fanatec doesn’t sell replacement Hall sensors for these pedals, so I wrote a small C program that:

* Polls the pedal axis at a fixed interval.
* Detects “stuck” or noisy clutch values when the gas pedal is idle.
* Triggers a PowerShell TTS script that says **“rudder, rudder”** (Bitchin’ Betty style).

When I hear the warning, I simply pump the clutch a few times; the noise clears and I can keep flying. This has kept my aging pedals usable for many years, with **minimal CPU impact**, which is exactly why I wrote it in C.

Originally the tool only monitored the clutch. Over time, my **gas pedal** started to show **drift** and failed to hit 100% consistently, so I extended the program to monitor gas travel and warn me when the pedal’s effective maximum drops.

---

## Key Features

Compared to the original version, the current program adds or improves:

* **Clutch noise monitoring**

  * Detects when clutch (rudder) sits in a “noisy” band while gas is idle.
  * Warns via `sayRudder.ps1` (TTS).

* **Gas drift detection**

  * Detects when the gas pedal **never reaches near full travel** for a configurable time window while racing.
  * Announces the **maximum percentage travel** seen (e.g., “Gas 82%”) via `sayGas.ps1`.

* **Axis normalization**

  * Hardware often reports **inverted values** (Fanatec raw: idle ≈ max, pressed ≈ 0).
  * The monitor normalizes to a human friendly model:

    * `0 = pedal at rest`, `axisMax = fully pressed`.
  * Can be disabled with `--no-axis-normalization` for already sane devices.

* **Configurable tuning**

  * **Clutch:**

    * `--margin` (stickiness margin in %)
    * `--clutch-repeat` (consecutive samples required before alert).
  * **Gas:**

    * Deadzones: `--gas-deadzone-in` (idle band), `--gas-deadzone-out` (full throttle band).
    * Timing: `--gas-window`, `--gas-timeout`, `--gas-cooldown`.
    * Minimum usage: `--gas-min-usage` (ignore windows where you barely touch the throttle).

* **Auto reconnect by VID/PID**

  * `--vendor-id` and `--product-id` (hex) allow automatic rediscovery after unplug/replug.

* **Debug / diagnostics**

  * `--verbose` to print readings and timing.
  * `--debug-raw` to print **both raw and normalized** axis values in verbose mode.
  * `--no_buffer` to disable stdout buffering for logging.

* **Performance / integration**

  * `--idle` / `--belownormal` process priority.
  * `--affinitymask` to pin the monitor to specific CPU cores (e.g., “efficiency” cores).
  * Single instance enforcement via a named mutex (prevents multiple monitors from running).

---

## Supported Platforms & Requirements

* **OS:** Windows 10 / 11 (x64).
* **Compiler:** MinGW w64 gcc or similar (needs `windows.h`, `mmsystem.h`, `getopt.h`).
* **IDE: NetBeans 18 + C/C++ plugin + MSYS64
* **Libraries:**

  * Link with **`winmm.lib`** (for `joyGetPosEx`, `joyGetDevCaps`, etc.).
* **Hardware:**

  * Designed/tested with **Fanatec ClubSport Pedals V2 (US)**, but works with any joystick like device exposing axes via WinMM.

---

## Build Instructions

1. **Clone the repository** and ensure the `.c` and `.ps1` files are in the same directory.

2. **Build with MinGW w64** (example):

   ```bash
   x86_64-w64-mingw32-gcc -O2 -Wall -municode ^
       -o fanatecmonitor.exe main.c ^
       -lwinmm
   ```

3. Make sure the following scripts sit next to `fanatecmonitor.exe`:

   * `sayRudder.ps1` – says “rudder, rudder” or similar (clutch alert).
   * `sayGas.ps1` – announces gas drift (e.g., “Gas 82%”).
   * `saySomething.ps1` – generic TTS helper for reconnect messages, etc.

4. Optionally integrate the EXE into your IDE or build system (e.g., NetBeans, custom Makefile).
   The original project used NetBeans + MinGW w64 and a simple post build copy step.

---

## Quick Start

### 1. Show help

```bash
fanatecmonitor.exe --help
```

If you run it without parameters, it will print help and exit (as before).

---

### 2. Typical Flight Sim Launch (rudder noise + optional gas drift)

This is the modern equivalent of how I used to start the original clutch only program on boot:

Original (clutch only):

```bash
fanatecmonitor.exe --joystick 1 --flags 266 --iterations 90000 --margin 1 --idle --affinitymask 983040
```

Updated (clutch + gas, with VID/PID auto reconnect):

```bash
fanatecmonitor.exe ^
  --monitor-clutch --monitor-gas ^
  --joystick 1 ^
  --flags 266 ^
  --iterations 90000 ^
  --margin 1 ^
  --gas-deadzone-in 5 --gas-deadzone-out 93 ^
  --gas-window 30 --gas-timeout 10 --gas-cooldown 60 --gas-min-usage 20 ^
  --vendor-id 0EB7 --product-id 1839 ^
  --idle --affinitymask 983040
```

Notes:

* `--flags 266` = `JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY` (Fanatec raw 0–1023).
* `--iterations 90000` with `--sleep 1000` ≈ 25 hours of monitoring.
* `--idle` + `--affinitymask 983040` pins the monitor to “cheap” cores so your main sim threads stay on faster cores, a pattern I used on a 12700K.

---

### 3. Example: Forza Motorsport / Racing Sims (Gas drift only)

For racing titles where you care about gas drift but don’t use the clutch monitoring:

```bash
fanatecmonitor.exe ^
  --monitor-gas ^
  --joystick 1 ^
  --flags 266 ^
  --iterations 0 ^                 # 0 = run until you close it
  --sleep 1000 ^                   # check every second
  --gas-deadzone-in 5 ^            # top 5% = idle band
  --gas-deadzone-out 93 ^          # 93%+ = treated as "full throttle"
  --gas-window 30 ^                # if you don't hit full throttle for 30s...
  --gas-timeout 10 ^               # 10s idle = assume menu/pause
  --gas-cooldown 60 ^              # at most 1 alert per minute
  --gas-min-usage 20               # ignore windows where usage < 20%
```

This configuration:

* Tells you if the pedal’s **maximum effective travel** drops below expected while racing.
* Avoids alerts when you’re just creeping in the pits or behind a safety car (never above 20% travel).

---

## Command Line Options (Reference)

### Core Options

* `--joystick ID`
  Joystick ID (0–15) to monitor. Required unless you specify `--vendor-id` + `--product-id`.

* `--vendor-id HEX`, `--product-id HEX`
  Hexadecimal Vendor ID and Product ID (e.g., `--vendor-id 0EB7 --product-id 1839` for ClubSport V2). Used for **auto reconnect** if the USB device is unplugged.

* `--iterations N`
  Number of main loop iterations to run.

  * Default: `1`
  * `0` = run indefinitely.
    **Note:** real runtime is `iterations × sleep (ms)`, you’re no longer tied to “1 second per iteration” as in the original README.

* `--sleep MS`
  Delay (in milliseconds) between polls. Default: `1000`.

* `--flags N`
  `JOYINFOEX.dwFlags` mask (see WinMM docs).

  * Default: `JOY_RETURNALL`.
  * Typical for Fanatec raw: `266` = `JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY`.

* `--no_buffer`
  Disable stdout buffering (useful when logging to a file).

* `--verbose`, `--brief`
  Turn verbose logging on/off.

---

### Clutch Monitor Options

* `--monitor-clutch`
  Enable clutch (rudder) noise monitoring.

* `--margin N`
  Clutch stickiness tolerance in **percent of full axis range** (0–100). Default: `5`.
  Internally converted to raw units as `axisMargin = axisMax * margin / 100`.

* `--clutch-repeat N`
  Number of **consecutive samples** within `axisMargin` required to trigger an alert.

  * Default: `4` (with `--sleep 1000`, this ≈ 4 seconds of “stuck” readings).
  * If you reduce `--sleep` to `100`, consider increasing `--clutch-repeat` so the effective time window stays similar (~40 samples for ~4 seconds).

---

### Gas Monitor Options

* `--monitor-gas`
  Enable gas pedal drift monitoring.

* `--gas-deadzone-in P`
  Idle band size in percent of full travel (0–100). Default: `5`.

  * In normalized space (`0 = idle`), values ≤ `axisMax * 0.05` are treated as idle.

* `--gas-deadzone-out P`
  Full throttle threshold in percent of full travel (0–100). Default: `93`.

  * Values ≥ `axisMax * 0.93` are treated as “near full throttle”.

* `--gas-window S`
  Window length (seconds) to wait for a full throttle event while racing. Default: `30`.

  * If you don’t hit `gasFullMin` within this window, the program will check for drift.

* `--gas-timeout S`
  Idle time (seconds) after which we assume you’re in a menu/pause and **auto pause** drift checks. Default: `10`.

* `--gas-cooldown S`
  Minimum time (seconds) between gas drift alerts. Default: `60`.

* `--gas-min-usage P`
  Minimum usage threshold in percent of travel (0–100). Default: `20`.

  * Drift checks are ignored if the maximum gas travel in a window is ≤ this value.
  * Prevents false positives in low throttle scenarios (safety car, taxiing, etc.).

---

### Axis & Debug Options

* `--no-axis-normalization`
  Disable axis inversion. Use this if your controller already reports idle as 0 and fully pressed as `axisMax`.

  * Default behavior (when this flag is omitted):

    * If you use `JOY_RETURNRAWDATA`, inverted axes are normalized via `axisMax - raw`.

* `--debug-raw`
  When combined with `--verbose`, logs both **raw** and **normalized** axis values:

  ```text
  1234567, gas_raw=1023 gas_norm=0, clutch_raw=0 clutch_norm=1023
  ```

  Useful for calibration and verifying normalization is doing what you expect.

---

### Performance & Priority Options

* `--idle`
  Set the monitor process to **IDLE_PRIORITY_CLASS**.

* `--belownormal`
  Set process priority to **BELOW_NORMAL_PRIORITY_CLASS**.

* `--affinitymask N`
  Decimal CPU affinity mask (e.g., choose E cores only on hybrid CPUs).

These options are handy when you want the monitor to stay out of the way of your main simulator threads.

---

## How the Detection Algorithms Work

### Clutch Noise Detection

1. **Normalize axes** so:

   * `gasValue = 0` at rest, `axisMax` when fully pressed.
   * `clutchValue` similarly.

2. **Gating conditions:**

   * Only consider clutch noise when:

     * Gas is **idle**: `gasValue <= gasIdleMax` (inside idle band).
     * Clutch is **not fully released**: `clutchValue > 0`.

3. **Stickiness metric (`closure`):**

   * `closure` = absolute change between current and previous clutch value.
   * If `closure <= axisMargin` for `clutch_repeat_required` consecutive samples, we trigger a clutch alert.

4. **Alert:**

   * Calls `sayRudder.ps1` via PowerShell so you hear “rudder, rudder”.

This makes the clutch monitor sensitive to **stuck/noisy positions** while ignoring normal clutch movements and any gas activity.

---

### Gas Drift Detection (State Machine)

All gas logic is done on **normalized values** (`0 = idle`, `axisMax = fully pressed`):

1. **Activity vs idle:**

   * Gas is considered **active** when `gasValue > gasIdleMax`.
   * When active:

     * `isRacing = TRUE`.
     * `lastGasActivityTime` is updated.
   * When idle:

     * If `isRacing` and idle for `gas_timeout` seconds → **auto pause** (`isRacing = FALSE`).

2. **Tracking “race windows”:**

   * While `isRacing`:

     * Track `peakGasInWindow` = max gas value since last “full throttle”.
     * A “full throttle” event is `gasValue >= gasFullMin` (e.g., ≥ 93%).
     * Hitting full throttle resets the window (`lastFullThrottleTime`, `peakGasInWindow = 0`).

3. **Drift decision:**

   * If you **haven’t** hit full throttle for `gas_window` seconds:

     * Check that at least one sample exceeded `gas_min_usage_percent`.

       * If not → ignore (you were just puttering).
     * Compute `percentReached = 100 * peakGasInWindow / axisMax`.
     * If above the minimum threshold:

       * Alert (once per `gas_cooldown` seconds) with that percentage value.

The model is: *“If you’re really racing and using at least X% throttle, you ought to have floored it at least once in the last N seconds. If not, your pedal might be drifting.”*

---

## Limitations & Notes

* The program uses **WinMM joystick APIs**, so it sees the device via the classic Windows joystick layer, not DirectInput/XInput/etc. If your device only exposes an XInput interface, this won’t see it.
* The clutch and gas logic are tuned for **axes that are not used 100% of the time**:

  * For rudder/clutch: you mostly leave them centered or idle; noise stands out.
  * For gas: the state machine assumes at least occasional full throttle usage; pure “eco driving” may require higher `--gas-min-usage` or larger `--gas-window`.
* It’s not a generic noise suppressor for main movement axes in all games; in some scenarios, noisy hardware is simply not fixable at the software level.

---

## License

This project is released under the license referenced in `LICENSE` in the repository.