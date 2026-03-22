# PedDash

This folder contains the newest and most complete GUI version of my Fanatec pedal monitor: a Windows desktop app for **Fanatec ClubSport Pedals V2** and similar WinMM joystick devices, focused on low-latency visualization, deadzone tuning, drift/noise monitoring, and practical day-to-day use with real hardware.

Built with **C# / .NET 8**, **WinUI 3**, **Windows App SDK**, **Win2D GPU-accelerated custom rendering**, **WinMM joystick interop via P/Invoke**, **real-time signal history buffers**, **state-machine pedal analysis**, **dynamic INI configuration persistence**, **single-instance desktop app guarding**, **process priority + CPU affinity control**, **CSV telemetry/event export**, **runtime paint/read/compute latency instrumentation**, and optional **System.Speech TTS** alerts.

It exists for the same reason as the root project: keeping older Fanatec hardware useful instead of throwing it away when sensors start getting noisy or pedal travel stops reaching the same values it used to. The difference is that this version is the polished desktop app: the monitoring logic is still practical and performance-minded, but now it is paired with a purpose-built UI that makes the pedal behavior, timing, and calibration state much easier to inspect in real time.

---

## Where this version fits in the repo

This repository now has three useful versions of the same idea:

- **Root `main.c`**: the minimum console-first C version. Lowest overhead, text-first, good when you want a small monitor that stays out of the way.
- **Root `FanatecPedals.ps1` + `PedDash.html`**: the earlier GUI/dashboard route with lighter installation requirements, but heavier/slower because it depends on the PowerShell + HTML stack.
- **This `GUI` app (`PedDash`)**: the latest C# desktop version. It needs the .NET / WinUI runtime stack, but the goal is a more responsive, more maintainable, more instrumented GUI than the PowerShell/HTML version.

So the tradeoff is simple:

- If you want the most minimal monitor, use the C console tool.
- If you want a GUI with minimal setup and accept extra weight, use the PowerShell/HTML version.
- If you want the newest GUI with the most features, the clearest diagnostics, and the best path forward in this repo, use this WinUI app.

---

## What PedDash does

PedDash continuously reads the pedals, normalizes the axes when needed, applies deadzone logic, and shows both the raw physical behavior and the game-facing logical output.

It also carries forward the practical monitoring features from the older versions:

- **Gas drift monitoring** when the pedal stops reaching expected full travel over time.
- **Gas deadzone-out estimation** based on real usage windows instead of a single sample.
- **Optional in-memory auto-adjust of gas deadzone-out** with a safety minimum.
- **Clutch noise / rudder-spike detection** for the classic noisy Hall sensor problem.
- **Automatic disconnect/reconnect handling** when the controller disappears and comes back.
- **Optional spoken alerts** for drift, reconnects, and related runtime events.

On top of that, the GUI adds a lot more visibility:

- **Racing page** with Win2D gauges for physical vs game-facing pedal percentages.
- **Signals page** with rolling waveform charts for gas, brake, and clutch.
- **Lag page** showing tick, read, compute, and paint timing separately.
- **Data Map page** exposing the internal runtime values and state-machine fields live.
- **Configuration page** for editing the active `.ini` without digging through the file manually.
- **CSV export** for event history and telemetry history.

---

## Input modes and normal use

PedDash supports two input modes:

- **Hardware mode** for the real Fanatec pedals through WinMM.
- **Simulation mode** for UI/testing work when the hardware is not connected.

The normal intended workflow for actual use is the local [`FanatecPedals.current.ini`](./FanatecPedals.current.ini) in this folder, with the app running against the real hardware configuration rather than the simulator. Simulation mode is there mainly so the UI and rendering pipeline can still be exercised without the pedals attached.

The app loads `FanatecPedals.current.ini` from its own folder by default, and you can also launch a different config file with:

```powershell
PedDash.exe --config "C:\path\to\your\FanatecPedals.current.ini"
```

---

## Performance notes

This version was written specifically to be a better long-term GUI than the PowerShell/HTML version, not just a visual rewrite.

Some of the performance-minded parts of the app:

- **Win2D custom controls** instead of generic heavy charting widgets.
- **Cached geometry / glow layers** for repeated waveform rendering.
- **Bounded history and event ring buffers** to avoid uncontrolled growth.
- **Frame-rate capping** and smoothing controls for the UI.
- **Read / compute / paint timing breakdowns** so latency can be inspected, not guessed.
- **Optional process priority and CPU affinity settings** carried over from the older tooling ideas.

This is still a richer desktop app than the plain C monitor, so it is not meant to beat the console version on absolute minimal overhead. The point is that it should be a stronger, more informative GUI while staying far leaner and more direct than the PowerShell/HTML approach.

---

## Main screens

### 1) Racing

The Racing screen is the fastest "how are the pedals behaving right now?" view:

- live gas / brake / clutch gauges
- physical percentage vs deadzone-mapped game percentage
- status pills for drift alert, clutch noise, auto-adjust, and racing-state activity
- rolling event log

### 2) Signals and Events

This page is for waveform inspection and history:

- rolling gas / brake / clutch charts
- optional brake hiding
- waveform height adjustment
- event stream
- CSV export for events and telemetry

### 3) Lag and Timing

This page breaks the runtime into separate timing buckets:

- loop tick period
- device read time
- logic compute time
- sample-to-paint latency

That makes it easier to judge whether a problem is in hardware polling, app logic, or GUI rendering.

### 4) Data Map

This page is the live internal-state dashboard:

- raw axis values
- normalized values
- logical percentages
- threshold values
- drift estimator state
- reconnect flags
- timing counters
- event flags

It is intentionally useful both for tuning and for understanding how the monitoring logic is behaving under the hood.

### 5) Configuration

The Configuration page edits the active INI-backed settings for:

- input mode
- joystick and VID/PID settings
- deadzones
- gas monitoring thresholds
- clutch monitoring thresholds
- render smoothing / FPS cap
- TTS / telemetry / verbosity
- history depth and related runtime options

Some hardware/process changes are marked as requiring a restart so the app does not silently half-apply device settings.

---

## Real hardware details

For the real pedals, this app uses the classic Windows **WinMM** joystick API and reads the pedal axes through `JOYINFOEX`. In the usual Fanatec-style raw setup, that means:

- **gas** from `Y`
- **brake** from `X`
- **clutch** from `R`

Axis normalization is available because some pedal setups report idle and pressed in the inverted direction. The app keeps both:

- **physical percentage**: what the hardware is actually doing
- **logical percentage**: what the game-facing deadzone mapping would output

That split is important when a pedal still moves mechanically, but no longer reaches the same useful in-game range.

---

## Build and publish

This project targets:

- **.NET 8**
- **WinUI 3**
- **Windows App SDK**
- **x64 only**
- **Windows 10/11**

The supported unpackaged publish output is:

```text
bin\win-x64\publish
```

Typical commands:

```powershell
dotnet restore PedDash.csproj
dotnet build PedDash.csproj -c Debug -p:Platform=x64
dotnet publish PedDash.csproj -c Release /p:PublishProfile=win-x64
```

There is also a [`manual-build-notes.md`](./manual-build-notes.md) file in this folder with the full publishing notes, including why trimming is intentionally not the default.

---

## Why keep all three versions

Each version solves a different problem well:

- the **C tool** is the smallest and simplest monitor
- the **PowerShell/HTML version** is flexible and easy to try on systems that already fit that stack
- the **C# WinUI version** is the current "best GUI" path with more structure, more diagnostics, and a better long-term desktop foundation

I keep them all because they reflect different tradeoffs, not because they are duplicates.

---

## License

See the root [`LICENSE`](../LICENSE) file for licensing details.
