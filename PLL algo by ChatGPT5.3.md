**Deliverable:**
* A **single, self-contained HTML file** (`index.html`) containing all HTML, CSS, and JavaScript.
* **No** external libraries, frameworks, or network calls.
* The code must be production-ready, bug-free, and optimized for performance.
### **1. Visual Design & Theme**
* **Style:** Retro-Arcade meets Modern Telemetry (Cyberpunk aesthetic).
* **Colors:** Dark background (`#050508`), Dark panels (`#0f0f16`).
* **Accents:** Neon Cyan, Lime Green, Magenta, Amber, and Red.
* **Typography:** High-contrast sans-serif. Use **massive** font sizes for key numeric readouts (optimized for a small 10" monitor viewed from a distance).
* **Layout:** Fixed header, Tab navigation bar, and a main content area that fills the remaining viewport.
### **2. Technical Constraints & Simulation Engine**
* **Simulation Loop:**
    * Implement a `updateSimulation()` function that runs exactly every **50ms** (define this as a `const` at the top of the JS).
    * Simulate **Gas** and **Clutch** pedals using sine waves with added random noise/jitter to look human.
    * Simulate **Latency (Lag)** metrics (Pedal, Bridge, Dash, Total) using a random walk algorithm.
    * Maintain history arrays (max 300 samples) for all metrics.
    * Calculate **3-second running averages** for all lag metrics.
* **Rendering Loop:** Use `requestAnimationFrame` for smooth UI updates (60fps), independent of the data update rate.
* **CSS Grid/Canvas Fix:** When placing `<canvas>` elements inside CSS Grids, ensure containers have `overflow: hidden` and `min-height: 0` to prevent infinite layout expansion bugs.
### **3. UI Structure & Tabs**
#### **Global Header (Always Visible)**
* **Left:** Branding ("PedDash").
* **Center:** A **"FFW" (Fast Forward)** indicator pill. It should randomly toggle on/off (glowing Amber) based on simulation state.
* **Right:** Compact summary of Total Lag (ms) and breakdown (Ped/Bridge/Dash).
#### **Tab 1: "Racing" (Main View)**
* **Gauges:** Two large **Dual-Ring Gauges** (Gas & Clutch).
    * **Outer Ring:** Physical sensor value (Raw).
    * **Inner Ring:** Logical game value (Processed).
    * **Center Text:** The Logical value (0-100). **Font size must be huge.**
    * **Colors:** White at 0%, Green 1-99%, Red at 100%.
* **Labels:** Beneath gauges, show "PHYS" and "LOG" values. If values change, briefly flash the text Cyan.
* **Status Strip:** Row of "Chips" (Drift, Noise, Estimator) that light up based on random simulation events.
#### **Tab 2: "Lag & Timing"**
* **Layout:** CSS Grid. Top row = Metrics, Bottom row = Chart.
* **Metrics Panel:** Display current ms and **Avg 3s** for Total, PedMon, Bridge, and Dash latencies.
* **Chart:** A multi-line historical chart.
    * **Important:** Limit chart height to **35vh** (do not let it fill the screen).
    * X-Axis: Time labels (e.g., "-15s", "Now").
    * Y-Axis: Dynamic scaling based on max lag.
#### **Tab 3: "Signals & Events"**
* **Layout:** Split view. Top 30% = Charts, Bottom = Event Log.
* **Charts:** Two separate historical line charts (Gas vs. Time, Clutch vs. Time).
    * **Y-Axis:** Fixed scale **0 to 100**.
    * **X-Axis:** Time history.
* **Event Log:** A scrolling list of simulated events (e.g., "Gas Drift Detected", "FFW Active") with timestamps.
#### **Tab 4: "Data Map" (Telemetry Grid)**
* **Layout:** A categorized Grid layout (Categories: "Pedal Inputs", "Latency Metrics", "System Status").
* **Cards:** Inside categories, display value cards using a responsive grid (auto-fill).
* **Interactivity:**
    * **Hover:** Show a small "Quick Tip" floating tooltip near the cursor.
    * **Click:** Open a central **Modal/Popup** explaining the metric in plain English (e.g., explaining what "Logical vs Physical" means).
# More design ideas

You are a senior front-end engineer and UI designer.
Your task is to build a single, self-contained HTML file that prototypes an “arcade-style pedal dashboard” for sim racing.

This is only a visual / behavior prototype. There is no real telemetry: all data must be simulated in JavaScript.

Deliverable

Output one complete HTML document:

<html>, <head>, <style>, <body>, <script> all in a single file.


No external build tools.

No external JS frameworks.

No external CSS frameworks.

No network calls.

It must run by simply opening it in a browser (e.g. MS Edge / Chrome) as a local HTML file.

Overall look & feel

Design goal: it should feel like a retro-arcade + modern telemetry dashboard:

Dark theme, high contrast.

Background: very dark (e.g. near-black or deep blue).

Use neon-like accent colors: cyan, lime green, magenta, amber.

Rounded cards, soft glows, subtle shadows.

All text readable on a small 10.1" secondary monitor at 1366×768 (assume it might be driven at 1080p but physically small).

Typography:

Big numeric readouts for key values.

Smaller but still readable labels.

Layout & tabs

Use a tabbed UI so we can fit everything on the small monitor.

3.1 Global layout

Inside <body>:

A full-screen container (max 1366×768, centered if possible).

At the very top, a fixed global header strip (always visible) with:

Left: small status labels, e.g.

PedDash Arcade Prototype

Simulated session

Center: FFW (fast-forward) indicator area (details in section 4).

Right: compact lag summary:

Total lag: XXX ms

And smaller text below: PedMon: A ms | Bridge: B ms | Dash: C ms (all simulated).

Below header:

A tab bar with 3 tabs:

Tab 1: Racing

Tab 2: Lag & Timing

Tab 3: Signals & Events

Below tab bar:

The tab content area, filling the rest of the viewport.

3.2 Tab behavior

Only one tab’s content is visible at a time.

When a tab is not active:

Do not update its DOM / canvases on every frame.

The underlying data model can keep updating, but drawing should happen only for the active tab.

On tab switch:

Perform a full render of that tab using the latest data buffers.

FFW indicator (catch-up mode visual)

Even though this prototype uses simulated data, implement a visual FFW indicator that can be triggered from the simulation.

Place it in the global header center.

Normal state: hidden.

FFW state:

Show a pill/label like: ⏩ FFW (catching up) or similar.

Use a bright color (e.g. amber or yellow) with a subtle glow.

Optional: very subtle CSS animation (e.g. pulsing opacity or animated stripes) to imply fast-forward.

The simulation should randomly or deterministically toggle a ffwActive boolean so the UI can show/hide this indicator.

Tab 1 – “Racing” (main view while driving)

This is the primary “arcade” view. Prioritize clarity and eye candy here.

5.1 Dual ring gauges: Gas & Clutch

Top row: two large dual-ring gauges, side by side:

Left gauge: Gas

Right gauge: Clutch

Each gauge shows both physical and logical pedal travel:

Range: 0–100% for both.

Outer ring: physical travel (what the pedal sensor physically reads).

Inner ring: logical / in-game percentage after deadzones, etc.

Center text: the logical percentage (0–100).

Color rules for the big center number:

0% → bright white.

1–99% → bright green.

100% → bright red.

The rings themselves can use related colors (e.g. softer versions of green/red) but must be visually clear which ring is physical vs logical. Include a small legend or labels (“PHYS” / “LOG”).

Implementation hint:

Use <canvas> and draw arcs for the rings, or

Use SVG arcs, or

Use pure CSS with conic gradients if you prefer.

Animate smoothly (ease between old and new values rather than hard jumps).

5.2 Numeric labels

Below each gauge, show small labels:

For Gas:

Physical: XX%

Logical: YY%

For Clutch:

Same structure.

If value changed compared to the previous frame, briefly highlight the text in a “changed” color (e.g. bright cyan) for a short time (like < 500ms).

5.3 Mini status strip

Under the gauges, add a horizontal status row with small “chips”:

Gas drift indicator light (simulated):

Off most of the time.

Occasionally turn on (e.g. red or amber) for a brief period when the simulation triggers a “gas alert”.

Clutch noise / Rudder indicator.

Estimator indicator (e.g. when simulated “auto-adjust” happens).

These are just boolean-ish indicators driven by your simulated data.

5.4 Tiny event ticker

At the bottom of this tab, add a small event ticker:

Example entries:

12:34:56 Gas 85%

12:34:59 Rudder noise

12:35:03 Controller disconnected

Use a simple scrolling or “most recent on top” layout.

This is purely local, based on simulated events.

Tab 2 – “Lag & Timing”

Even though there’s no real network or C program here, we want to simulate latency metrics and show them graphically.

6.1 Numeric summary

At the top of this tab, show a panel with current (simulated) values:

Total lag: XXX ms

PedMon lag: AAA ms

Bridge lag: BBB ms

Dash lag: CCC ms

Below, maybe smaller text for running averages over last N seconds (all simulated).

6.2 Lag “oscilloscope” graphs

Below the numeric summary, show graphs over time:

Either 4 separate mini line charts or 1 chart with 4 colored lines:

Total lag (ms)

PedMon lag (ms)

Bridge lag (ms)

Dash lag (ms)

X-axis: recent time window (e.g. last 20–30 seconds).

Y-axis: lag in milliseconds (auto scale, but keep it reasonable, e.g. up to ~250 ms).

Implementation hints:

Use <canvas> for charts (simple 2D line plotting).

Data source: a rolling array of simulated lag samples.

Use different line colors and a legend.

Only update/draw these charts while the Lag & Timing tab is active.

Tab 3 – “Signals & Events”

This tab focuses on raw pedal signals and a more detailed event log.

7.1 Gas & Clutch waveforms

Top section: two mini waveform charts:

One for Gas physical % over time.

One for Clutch physical % over time.

Vertical range: 0–100%.

Time axis: last N seconds (similar to lag charts).

Implementation:

Again, <canvas> with simple polyline drawing.

Use a smooth, continuous scroll effect (e.g. shift the data or redraw with a moving index).

7.2 Detailed event list

Below the waveforms, show a scrollable list/table of simulated events:

Columns example:

Time (e.g. 12:34:56).

Type (e.g. Gas alert, Rudder noise, Disconnect, Reconnect).

Details (e.g. Gas reached 87%, or Estimator adjusted threshold).

If you want extra polish: clicking an event can briefly highlight the relevant region in the waveform (optional).

Telemetry simulation (JS)

You must implement a client-side simulation of telemetry and events.

8.1 Core state

Create a JS object that holds the live state, for example:

const state = {
gasPhysical: 0,   // 0..100
gasLogical: 0,    // 0..100
clutchPhysical: 0,
clutchLogical: 0,

// Simulated lags in ms:
lagPedMon: 0,
lagBridge: 0,
lagDash: 0,
lagTotal: 0,

ffwActive: false,

// Arrays for history:
lagHistory: [],         // objects with { time, pedMon, bridge, dash, total }
gasHistory: [],         // objects with { time, physical, logical }
clutchHistory: [],      // same
events: []              // objects with { time, type, message }
};

You can adjust the exact structure as needed, but keep a clear separation of:

pedal percentages,

lag metrics,

recent event history.

8.2 Update loop

Use setInterval or requestAnimationFrame (with your own timing) to:

Update state.gasPhysical and state.clutchPhysical smoothly:

Use sine waves, easing, or “random walk” style so it looks like a human pressing pedals, not pure noise.

Compute gasLogical and clutchLogical from the physical ones:

For example, clamp & scale to simulate deadzones (e.g. values below 5% become 0, values above 95% become 100).

Simulate lag metrics:

lagPedMon ~ random in [5, 25] ms.

lagBridge ~ random in [10, 60] ms.

lagDash ~ random in [5, 40] ms.

lagTotal = lagPedMon + lagBridge + lagDash.

Occasionally trigger:

ffwActive = true for a short period, then back to false.

Events like “Gas alert”, “Rudder noise”, “Controller disconnected”, “Controller reconnected”.

Push samples to history arrays and trim to a reasonable length (e.g. last 300 points).

The update loop should also:

Recompute the lag numeric summary.

Notify the currently active tab to redraw its content.

Performance & CPU friendliness

Even though this is a prototype, make it reasonably efficient:

Use at most one main update loop for data.

Only draw/animate the active tab.

For hidden tabs:

Keep updating history data in state, but don’t constantly redraw their canvases.

Keep canvas sizes bounded to the visible area; no huge offscreen canvases.

Code organization & comments

Keep everything in the single HTML file.

Organize code in logical sections:

CSS styles.

HTML structure.

JS: state definition, simulation, rendering per tab, event handlers.

Add comments:

Short, human-friendly comments for non-obvious parts (e.g. how the dual-ring gauge drawing works).

No need for over-commenting basic HTML/JS.

Interaction summary

When the HTML file is opened:

Simulation starts automatically.

“Racing” tab is active by default.

User should be able to:

Switch tabs via the tab bar.

Observe gauges and charts updating live.

Occasionally see the FFW indicator light up.

See random events appear in the ticker / event list.

Important:
Focus purely on this visual & interactive prototype.
Do not implement any real network calls or hooks to external processes. All data must be generated on the client with JavaScript.
