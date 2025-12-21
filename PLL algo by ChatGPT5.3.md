- Please help me to identify what is the problem with my web application called PedDash 
- Gemini 3 Pro has been trying to fix the problem since version 12 but nothing, it has been incapable to fix the problem.
- Make a deep analysis and create a deep and detailed plan as an AI Prompt for another AI to explain the problem and all the things it needs to do to fix it with all the new features.
- If you find other issues please make a detailed report for those as well.
- The following is the version that was working well.  Carefully read it line by line to understand how it works.

```
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PedDash - Production v11</title>
    <style>
        :root {
            /* Theme Colors */
            --bg-color: #050508;
            --panel-bg: #0f0f16;
            --text-main: #e0e0e0;
            --text-muted: #777;
            
            /* Neon Accents */
            --neon-cyan: #00f3ff;
            --neon-green: #39ff14;
            --neon-magenta: #ff00ff;
            --neon-amber: #ffbf00;
            --neon-red: #ff3333;
            
            /* Dimensions */
            --header-height: 70px;
            --tab-height: 45px;
        }

        * { box-sizing: border-box; }

        body {
            margin: 0;
            padding: 0;
            background-color: var(--bg-color);
            color: var(--text-main);
            font-family: "Segoe UI", "Roboto", "Helvetica Neue", sans-serif;
            overflow: hidden;
            width: 100vw;
            height: 100vh;
            display: flex;
            flex-direction: column;
            user-select: none;
        }

        /* --- Global Header --- */
        header {
            height: var(--header-height);
            background: linear-gradient(to bottom, #1a1a24, #0f0f16);
            border-bottom: 1px solid #333;
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 0 20px;
            flex-shrink: 0;
        }

        .brand {
            font-weight: bold;
            letter-spacing: 1px;
            color: var(--neon-cyan);
            font-size: 1.2em;
            text-shadow: 0 0 5px rgba(0, 243, 255, 0.4);
        }
        
        .brand span {
            font-size: 0.7em;
            color: var(--text-muted);
            font-weight: normal;
            margin-left: 10px;
        }

        .center-status {
            width: 250px;
            text-align: center;
        }

        /* Status Pills */
        .pill {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.9em;
            font-weight: bold;
            opacity: 0;
            transition: opacity 0.2s;
            margin: 0 5px;
        }
        
        .pill.active { opacity: 1; animation: pulse 2s infinite; }
        
        .pill-ffw {
            background-color: rgba(255, 191, 0, 0.1);
            color: var(--neon-amber);
            border: 1px solid var(--neon-amber);
            box-shadow: 0 0 10px var(--neon-amber);
        }

        .pill-disc {
            background-color: rgba(255, 51, 51, 0.1);
            color: var(--neon-red);
            border: 1px solid var(--neon-red);
            box-shadow: 0 0 10px var(--neon-red);
        }

        @keyframes pulse {
            0% { box-shadow: 0 0 5px currentColor; }
            50% { box-shadow: 0 0 15px currentColor; }
            100% { box-shadow: 0 0 5px currentColor; }
        }

        .lag-summary {
            text-align: right;
            font-family: monospace;
            display: flex;
            flex-direction: column;
            justify-content: center;
        }

        .lag-main {
            font-size: 1.6em; 
            color: var(--text-main);
            font-weight: bold;
            line-height: 1.1;
        }

        .lag-details {
            font-size: 1.1em;
            color: var(--text-muted);
            margin-top: 2px;
        }

        /* --- Navigation Tabs --- */
        nav {
            height: var(--tab-height);
            background-color: #0f0f16;
            display: flex;
            border-bottom: 1px solid #333;
            flex-shrink: 0;
        }

        .tab-btn {
            background: transparent;
            border: none;
            color: var(--text-muted);
            padding: 0 25px;
            font-size: 1em;
            cursor: pointer;
            border-right: 1px solid #222;
            transition: all 0.2s;
            position: relative;
        }

        .tab-btn:hover {
            color: #fff;
            background-color: #161620;
        }

        .tab-btn.active {
            color: var(--neon-cyan);
            background-color: #1a1a24;
            box-shadow: inset 0 -3px 0 var(--neon-cyan);
        }

        /* --- Main Content Area --- */
        main {
            flex-grow: 1;
            position: relative;
            overflow: hidden;
            padding: 15px;
        }

        .tab-content {
            display: none;
            height: 100%;
            width: 100%;
            flex-direction: column;
        }

        .tab-content.active {
            display: flex;
        }

        /* --- Tab 1: Racing --- */
        .gauges-container {
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 60px;
            flex-grow: 1;
            padding-bottom: 20px;
        }

        .gauge-wrapper {
            display: flex;
            flex-direction: column;
            align-items: center;
            width: 320px;
        }

        .gauge-canvas { margin-bottom: 15px; }

        .gauge-labels {
            display: flex;
            justify-content: space-between;
            width: 100%;
            font-family: monospace;
            font-size: 1.8em;
            color: var(--text-muted);
            font-weight: bold;
        }

        .val-text { transition: color 0.2s; }
        .val-changed { color: var(--neon-cyan); text-shadow: 0 0 5px var(--neon-cyan); }

        .status-strip {
            display: flex;
            justify-content: center;
            gap: 15px;
            padding: 10px;
            background: #0f0f16;
            border-radius: 8px;
            border: 1px solid #333;
            margin-bottom: 15px;
            flex-shrink: 0;
        }

        .status-chip {
            padding: 5px 15px;
            border-radius: 4px;
            font-size: 0.9em;
            font-weight: bold;
            background: #222;
            color: #555;
            text-transform: uppercase;
            transition: all 0.2s;
        }

        .status-chip.active-red { background: rgba(255, 51, 51, 0.2); color: var(--neon-red); box-shadow: 0 0 8px var(--neon-red); border: 1px solid var(--neon-red); }
        .status-chip.active-amber { background: rgba(255, 191, 0, 0.2); color: var(--neon-amber); box-shadow: 0 0 8px var(--neon-amber); border: 1px solid var(--neon-amber); }
        .status-chip.active-blue { background: rgba(0, 243, 255, 0.2); color: var(--neon-cyan); box-shadow: 0 0 8px var(--neon-cyan); border: 1px solid var(--neon-cyan); }
        .status-chip.active-green { background: rgba(57, 255, 20, 0.2); color: var(--neon-green); box-shadow: 0 0 8px var(--neon-green); border: 1px solid var(--neon-green); }

        .ticker-container {
            height: 100px;
            background: #000;
            border: 1px solid #333;
            border-radius: 4px;
            padding: 10px;
            overflow-y: hidden;
            font-family: monospace;
            font-size: 1em;
            position: relative;
            flex-shrink: 0;
        }

        .ticker-list { display: flex; flex-direction: column-reverse; }
        .ticker-item { margin-bottom: 4px; border-bottom: 1px solid #222; padding-bottom: 2px; }
        .ticker-time { color: var(--text-muted); margin-right: 10px; }
        .ticker-msg { color: #fff; }

        /* --- Tab 2: Lag --- */
        .lag-panel {
            display: grid;
            grid-template-rows: max-content 35vh; 
            align-content: start; 
            height: 100%;
            gap: 20px;
        }

        .lag-metrics-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 15px;
        }

        .metric-card {
            background: #0f0f16;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 15px;
            text-align: center;
        }
        .metric-card h3 { margin: 0 0 5px 0; font-size: 1em; color: var(--text-muted); }
        .metric-card .value { font-size: 1.8em; font-weight: bold; font-family: monospace; }
        .metric-avg { font-size: 0.8em; color: #555; margin-top: 5px; font-family: monospace; }
        
        .chart-container {
            background: #0f0f16;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 15px;
            position: relative;
            overflow: hidden; 
        }

        /* --- Tab 3: Signals --- */
        .signals-layout {
            display: grid;
            grid-template-rows: 30vh 1fr;
            gap: 20px;
            height: 100%;
        }

        .waveforms-row {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            min-height: 0; 
        }

        .waveform-card {
            background: #0f0f16;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 10px;
            display: flex;
            flex-direction: column;
            position: relative;
            overflow: hidden; 
            min-height: 0;
        }
        .waveform-card h4 { margin: 0 0 10px 0; color: var(--text-muted); font-size: 1.1em; flex-shrink: 0; }

        .events-table-container {
            background: #0f0f16;
            border: 1px solid #333;
            border-radius: 8px;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            min-height: 0; 
        }

        .events-header {
            background: #1a1a24;
            padding: 10px;
            display: grid;
            grid-template-columns: 100px 150px 1fr;
            font-weight: bold;
            font-size: 1em;
            border-bottom: 1px solid #333;
            flex-shrink: 0;
        }

        .events-list { overflow-y: auto; flex-grow: 1; font-family: monospace; font-size: 1em; }

        .event-row {
            display: grid;
            grid-template-columns: 100px 150px 1fr;
            padding: 6px 10px;
            border-bottom: 1px solid #222;
        }
        .event-row:hover { background-color: #1a1a24; }

        /* --- Tab 4: Telemetry Map --- */
        .tele-container {
            height: 100%;
            overflow-y: auto;
            padding: 10px;
            display: flex;
            flex-direction: column;
            gap: 30px; 
        }

        .tele-group { display: flex; flex-direction: column; }

        .tele-group-header {
            color: var(--neon-cyan);
            border-bottom: 1px solid #333;
            padding-bottom: 5px;
            margin-bottom: 15px;
            font-size: 1.1em;
            text-transform: uppercase;
            letter-spacing: 1px;
            font-weight: bold;
            text-shadow: 0 0 2px rgba(0,243,255,0.3);
        }

        .tele-grid-section {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
            gap: 15px;
        }

        .tele-card {
            background: #161620;
            border: 1px solid #333;
            border-radius: 6px;
            padding: 15px;
            cursor: pointer;
            transition: all 0.2s;
            position: relative;
        }
        .tele-card:hover {
            border-color: var(--neon-cyan);
            background: #1a1a24;
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.5);
        }
        .tele-card h5 { margin: 0 0 5px 0; color: var(--text-muted); font-size: 0.85em; text-transform: uppercase; }
        .tele-card .tele-val { font-size: 1.4em; font-family: monospace; font-weight: bold; color: #fff; }

        /* Tooltips */
        .hover-tip {
            position: fixed;
            background: rgba(0,0,0,0.9);
            border: 1px solid var(--neon-cyan);
            color: var(--neon-cyan);
            padding: 5px 10px;
            border-radius: 4px;
            font-size: 0.8em;
            pointer-events: none;
            z-index: 1000;
            opacity: 0;
            transition: opacity 0.1s;
            transform: translateY(-100%);
            margin-top: -10px;
        }
        .hover-tip.visible { opacity: 1; }

        .modal-overlay {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            background: rgba(0,0,0,0.7);
            z-index: 2000;
            display: flex;
            justify-content: center;
            align-items: center;
            opacity: 0;
            pointer-events: none;
            transition: opacity 0.2s;
        }
        .modal-overlay.open { opacity: 1; pointer-events: auto; }

        .modal-card {
            background: #1a1a24;
            border: 1px solid var(--neon-cyan);
            box-shadow: 0 0 20px rgba(0, 243, 255, 0.2);
            width: 500px;
            max-width: 90%;
            padding: 20px;
            border-radius: 8px;
            position: relative;
        }
        .modal-card h2 { margin-top: 0; color: var(--neon-cyan); border-bottom: 1px solid #333; padding-bottom: 10px; }
        .modal-card p { color: #e0e0e0; line-height: 1.5; }
        .modal-close {
            position: absolute; top: 10px; right: 15px;
            background: none; border: none; color: #777; font-size: 1.5em; cursor: pointer;
        }
        .modal-close:hover { color: #fff; }

        /* Utility */
        canvas { display: block; width: 100%; height: 100%; }
        .txt-white { color: #fff; }
        .txt-green { color: var(--neon-green); }
        .txt-red { color: var(--neon-red); }
        .txt-cyan { color: var(--neon-cyan); }
        .txt-mag { color: var(--neon-magenta); }
        .txt-amb { color: var(--neon-amber); }

    </style>
</head>
<body>

    <header>
        <div class="brand">PedDash <span id="session-status">Waiting for Bridge...</span></div>
        <div class="center-status">
            <div id="disc-indicator" class="pill pill-disc">⚠ DISCONNECTED</div>
            <div id="ffw-indicator" class="pill pill-ffw">⏩ FFW CATCH-UP</div>
        </div>
        <div class="lag-summary">
            <div class="lag-main">Latency: <span id="hdr-total-lag" class="txt-red">--</span> ms</div>
            <div class="lag-details">
                Ped: <span id="hdr-ped-lag">00</span> | Brg: <span id="hdr-brg-lag">00</span> | Dsh: <span id="hdr-dsh-lag">00</span>
            </div>
        </div>
    </header>

    <nav>
        <button class="tab-btn active" onclick="switchTab('tab-racing')">Racing</button>
        <button class="tab-btn" onclick="switchTab('tab-lag')">Lag & Timing</button>
        <button class="tab-btn" onclick="switchTab('tab-signals')">Signals & Events</button>
        <button class="tab-btn" onclick="switchTab('tab-telemetry')">Data Map</button>
    </nav>

    <main>
        <!-- Tab 1: Racing -->
        <div id="tab-racing" class="tab-content active">
            <div class="gauges-container">
                <div class="gauge-wrapper">
                    <canvas id="canvas-gas" width="300" height="300" class="gauge-canvas"></canvas>
                    <div class="gauge-labels">
                        <span>PHYS: <span id="lbl-gas-phys" class="val-text">0%</span></span>
                        <span>LOG: <span id="lbl-gas-log" class="val-text">0%</span></span>
                    </div>
                </div>
                <div class="gauge-wrapper">
                    <canvas id="canvas-clutch" width="300" height="300" class="gauge-canvas"></canvas>
                    <div class="gauge-labels">
                        <span>PHYS: <span id="lbl-clutch-phys" class="val-text">0%</span></span>
                        <span>LOG: <span id="lbl-clutch-log" class="val-text">0%</span></span>
                    </div>
                </div>
            </div>
            <div class="status-strip">
                <div id="status-drift" class="status-chip">Drift Alert</div>
                <div id="status-noise" class="status-chip">Rudder Noise</div>
                <div id="status-auto" class="status-chip">Auto-Adjust</div>
                <div id="status-racing" class="status-chip">Racing</div>
            </div>
            <div class="ticker-container">
                <div id="ticker-list"></div>
            </div>
        </div>

        <!-- Tab 2: Lag -->
        <div id="tab-lag" class="tab-content">
            <div class="lag-panel">
                <div class="lag-metrics-grid">
                    <div class="metric-card">
                        <h3>Latency Total</h3>
                        <div class="value txt-red" id="card-total-lag">0 ms</div>
                        <div class="metric-avg" id="avg-total-lag">Avg 3s: 0</div>
                    </div>
                    <div class="metric-card">
                        <h3>PedMon (C)</h3>
                        <div class="value txt-cyan" id="card-ped-lag">0 ms</div>
                        <div class="metric-avg" id="avg-ped-lag">Avg 3s: 0</div>
                    </div>
                    <div class="metric-card">
                        <h3>Bridge (PS)</h3>
                        <div class="value txt-green" id="card-brg-lag">0 ms</div>
                        <div class="metric-avg" id="avg-brg-lag">Avg 3s: 0</div>
                    </div>
                    <div class="metric-card">
                        <h3>Dash (JS)</h3>
                        <div class="value txt-mag" id="card-dsh-lag">0 ms</div>
                        <div class="metric-avg" id="avg-dsh-lag">Avg 3s: 0</div>
                    </div>
                </div>
                <div class="chart-container">
                    <canvas id="canvas-lag-chart"></canvas>
                </div>
            </div>
        </div>

        <!-- Tab 3: Signals -->
        <div id="tab-signals" class="tab-content">
            <div class="signals-layout">
                <div class="waveforms-row">
                    <div class="waveform-card">
                        <h4>Gas Input History (Physical)</h4>
                        <canvas id="canvas-wave-gas"></canvas>
                    </div>
                    <div class="waveform-card">
                        <h4>Clutch Input History (Physical)</h4>
                        <canvas id="canvas-wave-clutch"></canvas>
                    </div>
                </div>
                <div class="events-table-container">
                    <div class="events-header">
                        <div>Time</div>
                        <div>Type</div>
                        <div>Details</div>
                    </div>
                    <div id="full-event-list" class="events-list"></div>
                </div>
            </div>
        </div>

        <!-- Tab 4: Telemetry -->
        <div id="tab-telemetry" class="tab-content">
            <div id="tele-container" class="tele-container"></div>
        </div>
    </main>

    <!-- Overlays -->
    <div id="hover-tip" class="hover-tip">Quick Info</div>
    <div id="modal-overlay" class="modal-overlay" onclick="closeModal()">
        <div class="modal-card" onclick="event.stopPropagation()">
            <button class="modal-close" onclick="closeModal()">&times;</button>
            <h2 id="modal-title">Title</h2>
            <p id="modal-desc">Description goes here.</p>
        </div>
    </div>

    <script>
		// Configuration constants for PedDash
		// --------------------------

		// Update Interval (ms). Set to 0 to enable Smart Adaptive Polling.
		// Default: 50ms (20Hz) - stable for most systems.
		const UPDATE_INTERVAL_MS = 0; 

		// Algorithm Selection for Update Interval = 0
		// Options: "INVERSE_STEP" (Legacy, Aggressive), "SMOOTH_CONVERGENCE" (Balanced, Oscillates), "FRAME_LOCK" (Recommended, Stable)
		const SMART_ALGO_MODE = "FRAME_LOCK";

		// Multiplier applied to the calculated sleep time.
		// 1.00 = Exact calc. < 1.00 = Faster/Aggressive. > 1.00 = Slower/Relaxed.
		const MANUAL_UPDATE_FACTOR = 1.00;

		// If true, logs an event when the Bridge returns an empty list (0 frames).
		const LOG_EMPTY_FRAMES = true;

		const BRIDGE_URL = "http://localhost:8181/";
		const MAX_HISTORY = 300; 
		const AVG_WINDOW_S = 3;

        /**
         * TELEMETRY DEFINITIONS
         */
        const TELE_GROUPS = [
            {
                title: "Pedal Metrics",
                keys: ['gas_physical_pct', 'gas_logical_pct', 'clutch_physical_pct', 'clutch_logical_pct']
            },
            {
                title: "Raw Inputs",
                keys: ['rawGas', 'gasValue', 'rawClutch', 'clutchValue', 'axisMax', 'debug_raw_mode', 'axis_normalization_enabled', 'joy_ID', 'joy_Flags']
            },
            {
                title: "Logic State",
                keys: ['isRacing', 'peakGasInWindow', 'best_estimate_percent', 'lastFullThrottleTime', 'lastGasActivityTime', 'lastClutchValue', 'repeatingClutchCount']
            },
            {
                title: "Gas Tuning",
                keys: ['gas_deadzone_in', 'gas_deadzone_out', 'gas_min_usage_percent', 'gas_window', 'gas_timeout', 'gas_cooldown', 'auto_gas_deadzone_enabled', 'auto_gas_deadzone_minimum', 'estimate_gas_deadzone_enabled']
            },
            {
                title: "Latency (ms)",
                keys: ['lagTotal', 'fullLoopTime_ms', 'metricLoopProcessMs', 'metricHttpProcessMs', 'lagDash', 'activeUpdateInterval', 'producer_loop_start_ms', 'producer_notify_ms']
            },
            {
                title: "Event Flags",
                keys: ['gas_alert_triggered', 'clutch_alert_triggered', 'gas_auto_adjust_applied', 'gas_estimate_decreased', 'controller_disconnected', 'controller_reconnected']
            },
            {
                title: "Event Timestamps",
                keys: ['last_disconnect_time_ms', 'last_reconnect_time_ms', 'last_estimate_print_time', 'estimate_window_start_time', 'lastGasAlertTime']
            },
            {
                title: "Diagnostics & Config",
                keys: ['telemetry_sequence', 'iLoop', 'iterations', 'sleep_Time', 'margin', 'axisMargin', 'framesReceivedLastFetch', 'pendingFrameCount', 'batchId', 'receivedAtUnixMs', 'currentTime']
            }
        ];
		
/*		

        const TELE_DEFS = {
            // Metrics
            gas_physical_pct: { label: "Gas Phys %", short: "Raw Input", long: "Percentage of physical pedal travel derived from normalized axis values. (Source: PedMon)" },
            gas_logical_pct:  { label: "Gas Log %", short: "Game Value", long: "Final value sent to game after deadzones are applied. (Source: PedMon)" },
            clutch_physical_pct: { label: "Clutch Phys %", short: "Raw Input", long: "Percentage of physical clutch travel. (Source: PedMon)" },
            clutch_logical_pct: { label: "Clutch Log %", short: "Game Value", long: "Final clutch value sent to game. (Source: PedMon)" },
            
            // Raw
            rawGas: { label: "Gas Raw", short: "JoyAPI Value", long: "Direct value from Windows joyGetPosEx. (Source: PedMon)" },
            gasValue: { label: "Gas Norm", short: "Normalized", long: "Value after hardware-inversion correction (0..axisMax). (Source: PedMon)" },
            rawClutch: { label: "Clutch Raw", short: "JoyAPI Value", long: "Direct value from Windows JoyAPI. (Source: PedMon)" },
            clutchValue: { label: "Clutch Norm", short: "Normalized", long: "Value after hardware-inversion correction. (Source: PedMon)" },
            axisMax: { label: "Axis Max", short: "Resolution", long: "Maximum possible value for the axis (e.g. 1023 or 65535). (Source: PedMon)" },
            debug_raw_mode: { label: "Debug Mode", short: "Verbose", long: "If enabled, PedMon prints raw data to console. (Source: PedMon)" },
            axis_normalization_enabled: { label: "Axis Norm", short: "Invert Flag", long: "If 1, PedMon inverts raw values (AxisMax - Raw) for Fanatec hardware. (Source: PedMon)" },
            joy_ID: { label: "Joy ID", short: "Device ID", long: "Windows Joystick ID (0-15). (Source: PedMon)" },
            joy_Flags: { label: "Joy Flags", short: "API Flags", long: "Flags passed to joyGetPosEx. (Source: PedMon)" },

            // Logic
            isRacing: { label: "Is Racing", short: "Session Active", long: "True if gas activity detected recently. (Source: PedMon)" },
            peakGasInWindow: { label: "Peak Gas", short: "Window Max", long: "Highest normalized gas value in current detection window. (Source: PedMon)" },
            best_estimate_percent: { label: "Best Est %", short: "Auto-Calib", long: "Lowest suggested gas-deadzone-out. (Source: PedMon)" },
            lastFullThrottleTime: { label: "Last Full T", short: "Timestamp", long: "Last time full throttle was observed (ms). (Source: PedMon)" },
            lastGasActivityTime: { label: "Last Activity", short: "Timestamp", long: "Last time gas was not idle (ms). (Source: PedMon)" },
            lastClutchValue: { label: "Last Clutch", short: "History", long: "Clutch value from previous frame (for noise detection). (Source: PedMon)" },
            repeatingClutchCount: { label: "Clutch Reps", short: "Noise Count", long: "Consecutive frames where clutch value was static/noisy. (Source: PedMon)" },

            // Tuning
            gas_deadzone_in: { label: "DZ In %", short: "Idle Zone", long: "Bottom % of travel ignored. (Source: PedMon)" },
            gas_deadzone_out: { label: "DZ Out %", short: "Max Zone", long: "Top % of travel treated as 100%. (Source: PedMon)" },
            gas_min_usage_percent: { label: "Min Usage %", short: "Drift Thresh", long: "Minimum pedal usage required for drift detection. (Source: PedMon)" },
            gas_window: { label: "Gas Window", short: "Seconds", long: "Time window to check for full throttle. (Source: PedMon)" },
            gas_timeout: { label: "Gas Timeout", short: "Seconds", long: "Idle time before assuming pause. (Source: PedMon)" },
            gas_cooldown: { label: "Cooldown", short: "Seconds", long: "Minimum time between alerts. (Source: PedMon)" },
            auto_gas_deadzone_enabled: { label: "Auto Adjust", short: "Enabled?", long: "If true, PedMon lowers DZ Out automatically. (Source: PedMon)" },
            auto_gas_deadzone_minimum: { label: "Auto Min", short: "Floor", long: "Minimum allowed value for auto-adjust. (Source: PedMon)" },
            estimate_gas_deadzone_enabled: { label: "Estimator", short: "Enabled?", long: "If true, calculates suggestions. (Source: PedMon)" },

            // Latency
            lagTotal: { label: "Latency Total", short: "Processing Time", long: "Cumulative processing time (PedMon + Bridge + HTTP + JS). (Source: PedDash)" },
            fullLoopTime_ms: { label: "PedMon Loop", short: "C Process", long: "Time taken by C program loop. (Source: PedMon)" },
            metricLoopProcessMs: { label: "Bridge Loop", short: "PS Process", long: "Time taken by PowerShell to read memory. (Source: PedBridge)" },
            metricHttpProcessMs: { label: "Bridge HTTP", short: "Serialize", long: "Time taken to serialize JSON. (Source: PedBridge)" },
            lagDash: { label: "Dash Render", short: "JS Process", long: "Time taken by browser to fetch and parse. (Source: PedDash)" },
            activeUpdateInterval: { label: "Poll Interval", short: "Sleep ms", long: "Current sleep time between fetch calls. (Source: PedDash)" },
            producer_loop_start_ms: { label: "Prod Start", short: "TickCount", long: "Timestamp when C loop started. (Source: PedMon)" },
            producer_notify_ms: { label: "Prod Notify", short: "TickCount", long: "Timestamp when C published data. (Source: PedMon)" },

            // Diagnostics
            telemetry_sequence: { label: "Seq ID", short: "Frame ID", long: "Incremented per C frame published. (Source: PedMon)" },
            iLoop: { label: "Loop Count", short: "Iterations", long: "Total C loops run. (Source: PedMon)" },
            iterations: { label: "Target Iters", short: "Config", long: "0 = Infinite. (Source: PedMon)" },
            sleep_Time: { label: "C Sleep", short: "Config ms", long: "Sleep time inside C program. (Source: PedMon)" },
            margin: { label: "Margin", short: "Clutch Tol", long: "Tolerance for clutch stickiness. (Source: PedMon)" },
            axisMargin: { label: "Axis Margin", short: "Raw Units", long: "Margin converted to raw axis units. (Source: PedMon)" },
            framesReceivedLastFetch: { label: "Frames Rx", short: "Batch Size", long: "Number of frames in last JSON response. (Source: PedDash)" },
            pendingFrameCount: { label: "Pending", short: "Queue Depth", long: "Frames waiting in Bridge queue. (Source: PedBridge)" },
            batchId: { label: "Batch ID", short: "HTTP ID", long: "Incremented per HTTP response. (Source: PedBridge)" },
            receivedAtUnixMs: { label: "Rx Unix", short: "Timestamp", long: "Bridge reception time. (Source: PedBridge)" },
            currentTime: { label: "C Current", short: "TickCount", long: "GetTickCount at capture. (Source: PedMon)" },

            // Events
            gas_alert_triggered: { label: "Evt: Gas", short: "Flag", long: "1 if gas alert triggered this frame. (Source: PedMon)" },
            clutch_alert_triggered: { label: "Evt: Clutch", short: "Flag", long: "1 if clutch noise alert triggered. (Source: PedMon)" },
            gas_auto_adjust_applied: { label: "Evt: AutoAdj", short: "Flag", long: "1 if auto-adjust applied. (Source: PedMon)" },
            gas_estimate_decreased: { label: "Evt: EstDec", short: "Flag", long: "1 if estimator found new low. (Source: PedMon)" },
            controller_disconnected: { label: "Evt: Disc", short: "Flag", long: "1 if controller disconnected. (Source: PedMon)" },
            controller_reconnected: { label: "Evt: Reconn", short: "Flag", long: "1 if controller reconnected. (Source: PedMon)" },
            last_disconnect_time_ms: { label: "Last Disc", short: "Timestamp", long: "Time of last disconnect. (Source: PedMon)" },
            last_reconnect_time_ms: { label: "Last Reconn", short: "Timestamp", long: "Time of last reconnect. (Source: PedMon)" },
            last_estimate_print_time: { label: "Last Est Prt", short: "Timestamp", long: "Time of last estimate TTS. (Source: PedMon)" },
            estimate_window_start_time: { label: "Est Win Start", short: "Timestamp", long: "Start of current estimation window. (Source: PedMon)" },
            lastGasAlertTime: { label: "Last Alert", short: "Timestamp", long: "Time of last gas alert. (Source: PedMon)" }
        }; */
		
				
const TELE_DEFS = {
            // Metrics
            gas_physical_pct: { label: "Gas Phys %", short: "gas_physical_pct: Raw Input", long: "Percentage of physical pedal travel derived from normalized axis values. (Source: PedMon, Original Name: gas_physical_pct)" },
            gas_logical_pct:  { label: "Gas Log %", short: "gas_logical_pct: Game Value", long: "Final value sent to game after deadzones are applied. (Source: PedMon, Original Name: gas_logical_pct)" },
            clutch_physical_pct: { label: "Clutch Phys %", short: "clutch_physical_pct: Raw Input", long: "Percentage of physical clutch travel. (Source: PedMon, Original Name: clutch_physical_pct)" },
            clutch_logical_pct: { label: "Clutch Log %", short: "clutch_logical_pct: Game Value", long: "Final clutch value sent to game. (Source: PedMon, Original Name: clutch_logical_pct)" },
            
            // Raw
            rawGas: { label: "Gas Raw", short: "rawGas: JoyAPI Value", long: "Direct value from Windows joyGetPosEx. (Source: PedMon, Original Name: rawGas)" },
            gasValue: { label: "Gas Norm", short: "gasValue: Normalized", long: "Value after hardware-inversion correction (0..axisMax). (Source: PedMon, Original Name: gasValue)" },
            rawClutch: { label: "Clutch Raw", short: "rawClutch: JoyAPI Value", long: "Direct value from Windows JoyAPI. (Source: PedMon, Original Name: rawClutch)" },
            clutchValue: { label: "Clutch Norm", short: "clutchValue: Normalized", long: "Value after hardware-inversion correction. (Source: PedMon, Original Name: clutchValue)" },
            axisMax: { label: "Axis Max", short: "axisMax: Resolution", long: "Maximum possible value for the axis (e.g. 1023 or 65535). (Source: PedMon, Original Name: axisMax)" },
            debug_raw_mode: { label: "Debug Mode", short: "debug_raw_mode: Boolean event flag", long: "If enabled, PedMon prints raw data to console. (Source: PedMon, Original Name: debug_raw_mode)" },
            axis_normalization_enabled: { label: "Axis Norm", short: "axis_normalization_enabled: Invert Flag", long: "If 1, PedMon inverts raw values (AxisMax - Raw) for Fanatec hardware. (Source: PedMon, Original Name: axis_normalization_enabled)" },
            joy_ID: { label: "Joy ID", short: "joy_ID: Device ID", long: "Windows Joystick ID (0-15). (Source: PedMon, Original Name: joy_ID)" },
            joy_Flags: { label: "Joy Flags", short: "joy_Flags: API Flags", long: "Flags passed to joyGetPosEx. (Source: PedMon, Original Name: joy_Flags)" },

            // Logic
            isRacing: { label: "Is Racing", short: "isRacing: Boolean event flag", long: "True if gas activity detected recently. (Source: PedMon, Original Name: isRacing)" },
            peakGasInWindow: { label: "Peak Gas", short: "peakGasInWindow: Window Max", long: "Highest normalized gas value in current detection window. (Source: PedMon, Original Name: peakGasInWindow)" },
            best_estimate_percent: { label: "Best Est %", short: "best_estimate_percent: Auto-Calib", long: "Lowest suggested gas-deadzone-out. (Source: PedMon, Original Name: best_estimate_percent)" },
            lastFullThrottleTime: { label: "Last Full T", short: "lastFullThrottleTime: TickCount Timestamp", long: "Last time full throttle was observed (ms) (Windows GetTickCount). (Source: PedMon, Original Name: lastFullThrottleTime)" },
            lastGasActivityTime: { label: "Last Activity", short: "lastGasActivityTime: TickCount Timestamp", long: "Last time gas was not idle (ms) (Windows GetTickCount). (Source: PedMon, Original Name: lastGasActivityTime)" },
            lastClutchValue: { label: "Last Clutch", short: "lastClutchValue: History Value", long: "Clutch value from previous frame (for noise detection). (Source: PedMon, Original Name: lastClutchValue)" },
            repeatingClutchCount: { label: "Clutch Reps", short: "repeatingClutchCount: Noise Count", long: "Consecutive frames where clutch value was static/noisy. (Source: PedMon, Original Name: repeatingClutchCount)" },

            // Tuning
            gas_deadzone_in: { label: "DZ In %", short: "gas_deadzone_in: Idle Zone", long: "Bottom % of travel ignored. (Source: PedMon, Original Name: gas_deadzone_in)" },
            gas_deadzone_out: { label: "DZ Out %", short: "gas_deadzone_out: Max Zone", long: "Top % of travel treated as 100%. (Source: PedMon, Original Name: gas_deadzone_out)" },
            gas_min_usage_percent: { label: "Min Usage %", short: "gas_min_usage_percent: Drift Thresh", long: "Minimum pedal usage required for drift detection. (Source: PedMon, Original Name: gas_min_usage_percent)" },
            gas_window: { label: "Gas Window", short: "gas_window: Seconds", long: "Time window to check for full throttle. (Source: PedMon, Original Name: gas_window)" },
            gas_timeout: { label: "Gas Timeout", short: "gas_timeout: Seconds", long: "Idle time before assuming pause. (Source: PedMon, Original Name: gas_timeout)" },
            gas_cooldown: { label: "Cooldown", short: "gas_cooldown: Seconds", long: "Minimum time between alerts. (Source: PedMon, Original Name: gas_cooldown)" },
            auto_gas_deadzone_enabled: { label: "Auto Adjust", short: "auto_gas_deadzone_enabled: Boolean event flag", long: "If true, PedMon lowers DZ Out automatically. (Source: PedMon, Original Name: auto_gas_deadzone_enabled)" },
            auto_gas_deadzone_minimum: { label: "Auto Min", short: "auto_gas_deadzone_minimum: Floor", long: "Minimum allowed value for auto-adjust. (Source: PedMon, Original Name: auto_gas_deadzone_minimum)" },
            estimate_gas_deadzone_enabled: { label: "Estimator", short: "estimate_gas_deadzone_enabled: Boolean event flag", long: "If true, calculates suggestions. (Source: PedMon, Original Name: estimate_gas_deadzone_enabled)" },

            // Latency
            lagTotal: { label: "Latency Total", short: "lagTotal: Cumulative Processing Time", long: "Cumulative processing time (PedMon + Bridge + HTTP + JS). (Source: PedDash, Original Name: lagTotal)" },
            fullLoopTime_ms: { label: "PedMon Loop", short: "fullLoopTime_ms: C Process Time", long: "Time taken by C program loop (excluding sleep). (Source: PedMon, Original Name: fullLoopTime_ms)" },
            metricLoopProcessMs: { label: "Bridge Loop", short: "metricLoopProcessMs: PS Process Time", long: "Time taken by PowerShell to read shared memory and process events. (Source: PedBridge, Original Name: metricLoopProcessMs)" },
            metricHttpProcessMs: { label: "Bridge HTTP", short: "metricHttpProcessMs: PS Serialization Time", long: "Time taken by PowerShell to serialize JSON and prepare HTTP response. (Source: PedBridge, Original Name: metricHttpProcessMs)" },
            lagDash: { label: "Dash Render", short: "lagDash: JavaScript Processing time", long: "Time taken by browser to fetch, parse, and update UI. (Source: PedDash, Original Name: lagDash)" },
            activeUpdateInterval: { label: "Poll Interval", short: "activeUpdateInterval: Scheduled Fetch Delay", long: "Current sleep time between fetch calls (controlled by PedDash). (Source: PedDash, Original Name: activeUpdateInterval)" },
            producer_loop_start_ms: { label: "Prod Start", short: "producer_loop_start_ms: C TickCount Timestamp", long: "Windows GetTickCount when C loop started. (Source: PedMon, Original Name: producer_loop_start_ms)" },
            producer_notify_ms: { label: "Prod Notify", short: "producer_notify_ms: C TickCount Timestamp", long: "Windows GetTickCount when C published data to shared memory. (Source: PedMon, Original Name: producer_notify_ms)" },

            // Diagnostics
            telemetry_sequence: { label: "Seq ID", short: "telemetry_sequence: Frame ID", long: "Incremented per C frame published. (Source: PedMon, Original Name: telemetry_sequence)" },
            iLoop: { label: "Loop Count", short: "iLoop: C Iterations", long: "Total C loops run. (Source: PedMon, Original Name: iLoop)" },
            iterations: { label: "Target Iters", short: "iterations: C Config", long: "0 = Infinite. (Source: PedMon, Original Name: iterations)" },
            sleep_Time: { label: "C Sleep", short: "sleep_Time: C Config Delay", long: "Configured sleep time inside C program's loop. (Source: PedMon, Original Name: sleep_Time)" },
            margin: { label: "Margin", short: "margin: Clutch Tolerance %", long: "Percentage tolerance for clutch stickiness detection. (Source: PedMon, Original Name: margin)" },
            axisMargin: { label: "Axis Margin", short: "axisMargin: Raw Units", long: "Clutch margin converted to raw axis units. (Source: PedMon, Original Name: axisMargin)" },
            framesReceivedLastFetch: { label: "Frames Rx", short: "framesReceivedLastFetch: HTTP Batch Size", long: "Number of frames (data points) received in the last HTTP JSON response. (Source: PedDash, Original Name: framesReceivedLastFetch)" },
            pendingFrameCount: { label: "Pending", short: "pendingFrameCount: Bridge Queue Depth", long: "Number of frames waiting in PedBridge's internal queue. (Source: PedBridge, Original Name: pendingFrameCount)" },
            batchId: { label: "Batch ID", short: "batchId: HTTP Response ID", long: "Incremented per HTTP response from PedBridge. (Source: PedBridge, Original Name: batchId)" },
            receivedAtUnixMs: { label: "Rx Unix", short: "receivedAtUnixMs: Bridge Timestamp", long: "Unix timestamp (ms) when PedBridge received data from PedMon. (Source: PedBridge, Original Name: receivedAtUnixMs)" },
            currentTime: { label: "C Current", short: "currentTime: TickCount Timestamp", long: "Windows GetTickCount at C program's data capture. (Source: PedMon, Original Name: currentTime)" },

            // Events
            gas_alert_triggered: { label: "Evt: Gas", short: "gas_alert_triggered: Boolean event flag", long: "1 if a gas drift alert was triggered this frame. (Source: PedMon, Original Name: gas_alert_triggered)" },
            clutch_alert_triggered: { label: "Evt: Clutch", short: "clutch_alert_triggered: Boolean event flag", long: "1 if a clutch noise alert was triggered this frame. (Source: PedMon, Original Name: clutch_alert_triggered)" },
            gas_auto_adjust_applied: { label: "Evt: AutoAdj", short: "gas_auto_adjust_applied: Boolean event flag", long: "1 if gas deadzone auto-adjustment was applied this frame. (Source: PedMon, Original Name: gas_auto_adjust_applied)" },
            gas_estimate_decreased: { label: "Evt: EstDec", short: "gas_estimate_decreased: Boolean event flag", long: "1 if a new (lower) deadzone estimate was spoken/printed this frame. (Source: PedMon, Original Name: gas_estimate_decreased)" },
            controller_disconnected: { label: "Evt: Disc", short: "controller_disconnected: Boolean event flag", long: "1 if a controller disconnect event occurred this frame. (Source: PedMon, Original Name: controller_disconnected)" },
            controller_reconnected: { label: "Evt: Reconn", short: "controller_reconnected: Boolean event flag", long: "1 if a controller reconnect event occurred this frame. (Source: PedMon, Original Name: controller_reconnected)" },
            last_disconnect_time_ms: { label: "Last Disc", short: "last_disconnect_time_ms: TickCount Timestamp", long: "Windows GetTickCount at the last recorded disconnect event. (Source: PedMon, Original Name: last_disconnect_time_ms)" },
            last_reconnect_time_ms: { label: "Last Reconn", short: "last_reconnect_time_ms: TickCount Timestamp", long: "Windows GetTickCount at the last recorded reconnect event. (Source: PedMon, Original Name: last_reconnect_time_ms)" },
            last_estimate_print_time: { label: "Last Est Prt", short: "last_estimate_print_time: TickCount Timestamp", long: "Windows GetTickCount at the last time a new estimate was printed. (Source: PedMon, Original Name: last_estimate_print_time)" },
            estimate_window_start_time: { label: "Est Win Start", short: "estimate_window_start_time: TickCount Timestamp", long: "Windows GetTickCount when the current gas estimation window began. (Source: PedMon, Original Name: estimate_window_start_time)" },
            lastGasAlertTime: { label: "Last Alert", short: "lastGasAlertTime: TickCount Timestamp", long: "Windows GetTickCount at the last gas drift alert. (Source: PedMon, Original Name: lastGasAlertTime)" }
        };		

        /**
         * STATE
         */
        const state = {
            currentTab: 'tab-racing',
            isConnected: false,
            hasReceivedData: false, 
            
            // Runtime Config
            activeInterval: UPDATE_INTERVAL_MS,
            
            // Targets (from Fetch)
            target: {
                gasPhys: 0, gasLog: 0, clutchPhys: 0, clutchLog: 0,
                lagTotal: 0, lagPed: 0, lagBrg: 0, lagDsh: 0
            },
            
            // Display (Interpolated)
            display: {
                gasPhys: 0, gasLog: 0, clutchPhys: 0, clutchLog: 0,
                lagTotal: 0, lagPed: 0, lagBrg: 0, lagDsh: 0
            },

            // Raw Frame Data
            frame: {},
            
            // Averages
            avgLagTotal: 0, avgLagPed: 0, avgLagBrg: 0, avgLagDash: 0,

            // History
            lagHistory: [],
            pedalHistory: [],
            events: []
        };

        // Helpers
        function pushHistory(arr, item) {
            arr.push(item);
            if (arr.length > MAX_HISTORY) arr.shift();
        }

        function calcAverages() {
            const count = (AVG_WINDOW_S * 1000) / (state.activeInterval || 50);
            if (state.lagHistory.length === 0) return;
            const recent = state.lagHistory.slice(-Math.max(1, count));
            const len = recent.length;
            
            state.avgLagTotal = recent.reduce((sum, i) => sum + i.total, 0) / len;
            state.avgLagPed = recent.reduce((sum, i) => sum + i.ped, 0) / len;
            state.avgLagBrg = recent.reduce((sum, i) => sum + i.brg, 0) / len;
            state.avgLagDash = recent.reduce((sum, i) => sum + i.dash, 0) / len;
        }

        function logEvent(type, msg) {
            if(state.events.length > 0) {
                const last = state.events[0];
                if(last.type === type && last.msg === msg && (Date.now() - last.ts) < 2000) return; 
            }
            const date = new Date();
            const timeStr = date.toLocaleTimeString('en-US', { hour12: false }) + "." + String(date.getMilliseconds()).padStart(3, '0');
            const evt = { ts: Date.now(), timeStr, type, msg };
            state.events.unshift(evt);
            if (state.events.length > 50) state.events.pop();
            updateEventDOM(evt);
        }

        /**
         * DOM ELEMENTS
         */
        const els = {
            brandStatus: document.getElementById('session-status'),
            discInd: document.getElementById('disc-indicator'),
            ffwInd: document.getElementById('ffw-indicator'),
            
            hdrTotal: document.getElementById('hdr-total-lag'),
            hdrPed: document.getElementById('hdr-ped-lag'),
            hdrBrg: document.getElementById('hdr-brg-lag'),
            hdrDsh: document.getElementById('hdr-dsh-lag'),

            // Racing
            cvsGas: document.getElementById('canvas-gas'),
            cvsClutch: document.getElementById('canvas-clutch'),
            lblGasPhys: document.getElementById('lbl-gas-phys'),
            lblGasLog: document.getElementById('lbl-gas-log'),
            lblClutchPhys: document.getElementById('lbl-clutch-phys'),
            lblClutchLog: document.getElementById('lbl-clutch-log'),
            stDrift: document.getElementById('status-drift'),
            stNoise: document.getElementById('status-noise'),
            stAuto: document.getElementById('status-auto'),
            stRacing: document.getElementById('status-racing'),
            tickerList: document.getElementById('ticker-list'),

            // Lag
            cardTotal: document.getElementById('card-total-lag'),
            cardPed: document.getElementById('card-ped-lag'),
            cardBrg: document.getElementById('card-brg-lag'),
            cardDsh: document.getElementById('card-dsh-lag'),
            avgTotal: document.getElementById('avg-total-lag'),
            avgPed: document.getElementById('avg-ped-lag'),
            avgBrg: document.getElementById('avg-brg-lag'),
            avgDsh: document.getElementById('avg-dsh-lag'),
            cvsLag: document.getElementById('canvas-lag-chart'),

            // Signals
            cvsWaveGas: document.getElementById('canvas-wave-gas'),
            cvsWaveClutch: document.getElementById('canvas-wave-clutch'),
            fullEventList: document.getElementById('full-event-list'),

            // Telemetry
            teleContainer: document.getElementById('tele-container'),

            // Overlays
            hoverTip: document.getElementById('hover-tip'),
            modalOverlay: document.getElementById('modal-overlay'),
            modalTitle: document.getElementById('modal-title'),
            modalDesc: document.getElementById('modal-desc')
        };

        const ctxGas = els.cvsGas.getContext('2d');
        const ctxClutch = els.cvsClutch.getContext('2d');
        const ctxLag = els.cvsLag.getContext('2d');
        const ctxWaveGas = els.cvsWaveGas.getContext('2d');
        const ctxWaveClutch = els.cvsWaveClutch.getContext('2d');

        /**
         * UI BUILDERS
         */
        function initTelemetryTab() {
            els.teleContainer.innerHTML = '';
            TELE_GROUPS.forEach(group => {
                const groupDiv = document.createElement('div');
                groupDiv.className = 'tele-group';
                const header = document.createElement('div');
                header.className = 'tele-group-header';
                header.textContent = group.title;
                groupDiv.appendChild(header);

                const gridDiv = document.createElement('div');
                gridDiv.className = 'tele-grid-section';

                group.keys.forEach(key => {
                    const def = TELE_DEFS[key];
                    const label = def ? def.label : key;
                    const short = def ? def.short : "";
                    const long = def ? def.long : "No description available.";

                    const card = document.createElement('div');
                    card.className = 'tele-card';
                    card.innerHTML = `<h5>${label}</h5><div class="tele-val" id="tele-${key}">--</div>`;
                    
                    card.onmouseenter = (e) => showHoverTip(e, short);
                    card.onmousemove = (e) => moveHoverTip(e);
                    card.onmouseleave = () => hideHoverTip();
                    card.onclick = () => showModal(label, long);

                    gridDiv.appendChild(card);
                });

                groupDiv.appendChild(gridDiv);
                els.teleContainer.appendChild(groupDiv);
            });
        }
        initTelemetryTab();

        /**
         * DATA FETCH LOOP
         */
        async function dataLoop() {
            const startFetch = performance.now();
            
            // AbortController to prevent hanging request
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 2000); // 2s timeout

            try {
                const res = await fetch(BRIDGE_URL, { signal: controller.signal });
                clearTimeout(timeoutId);
                const json = await res.json();
                
                // --- 0 Frame Logic ---
                if (!json || !json.frames || json.frames.length === 0) {
                    if (LOG_EMPTY_FRAMES) logEvent("Info", "Bridge: 0 frames received");
                    
                    // Smart Calculation for 0 Frames: Use previous interval (don't speed up blindly)
                    if (UPDATE_INTERVAL_MS === 0) {
                         // Keep current interval, maybe apply factor? For now, steady state.
                         scheduleNext(state.activeInterval * MANUAL_UPDATE_FACTOR);
                    } else {
                         scheduleNext(UPDATE_INTERVAL_MS);
                    }
                    return; // Do NOT update state/graphs
                }

                // Get latest frame
                const latest = json.frames[json.frames.length - 1];
                
                // Inject dash-side metrics into the frame object so they appear in Telemetry
                latest.framesReceivedLastFetch = json.frames.length;
                latest.pendingFrameCount = json.bridgeInfo.pendingFrameCount;
                latest.batchId = json.bridgeInfo.batchId;
                
                handleConnectionSuccess();
                processFrame(latest, startFetch, json.frames.length);
                
				// --- Calculate Next Sleep ---
                if (UPDATE_INTERVAL_MS > 0) {
                    scheduleNext(UPDATE_INTERVAL_MS);
                } else {
                    // Smart Sleep Logic
                    let nextSleep = state.activeInterval || 50; 
                    if (latest.sleep_Time) {
                        const cSleep = latest.sleep_Time;
                        const cProcess = latest.fullLoopTime_ms || 0;
                        const tProd = cSleep + cProcess; // Theoretical Producer Period
                        const received = latest.framesReceivedLastFetch || 0;
                        
                        if (SMART_ALGO_MODE === "FRAME_LOCK") {
                            const safeCruiseBuffer = 5; // ms buffer to run slightly slower than producer, compensates for jitter
                            const safeCruiseSpeed = tProd + safeCruiseBuffer;

                            if (received === 0) {
                                // If we received 0 frames, it means we polled too early.
                                // Reset to the producer's expected period to re-align.
                                nextSleep = tProd; 
                                if (LOG_EMPTY_FRAMES) logEvent("Debug", `FRAME_LOCK: 0 frames, resetting to producer period (${tProd}ms).`);
                            } else if (received > 1) {
                                // If we received more than 1 frame, latency has built up.
                                // Drastically reduce sleep to clear the buffer.
                                nextSleep = 10; // Aggressively low sleep
                                if (LOG_EMPTY_FRAMES) logEvent("Debug", `FRAME_LOCK: >1 frames, micro-sprint to ${nextSleep}ms.`);
                            } else { // received === 1
                                // Ideal state. Maintain a slightly slower "safe cruise" speed to avoid 0-frame race.
                                nextSleep = safeCruiseSpeed;
                                // if (LOG_EMPTY_FRAMES) logEvent("Debug", `FRAME_LOCK: 1 frame, cruising at ${nextSleep}ms.`);
                            }
                        } else if (SMART_ALGO_MODE === "SMOOTH_CONVERGENCE") {
                            // Weighted convergence to avoid oscillation
                            if (received === 0) {
                                nextSleep = Math.min(nextSleep * 1.1, tProd * 1.5);
                            } else if (received === 1) {
                                nextSleep = (nextSleep * 0.9) + (tProd * 0.1);
                            } else {
                                nextSleep = nextSleep * 0.85;
                            }
                        } else { // INVERSE_STEP (Legacy)
                            if (received === 1) nextSleep = tProd; 
                            else if (received > 1) nextSleep = nextSleep * (1 / received);
                            else nextSleep = tProd; // Reset on 0
                        }
                        
                        // Bounds Check (10ms to 1s)
                        nextSleep = Math.max(10, Math.min(nextSleep, 1000));
                    }
                    // Apply Manual Factor
                    scheduleNext(nextSleep * MANUAL_UPDATE_FACTOR);
                }

            } catch (e) {
                clearTimeout(timeoutId);
                logEvent("Error", "Network Error / Disconnected");
                handleDisconnect();
                scheduleNext(1000); // Retry slower on error
            }
        }

        function scheduleNext(delay) {
            state.activeInterval = delay;
            setTimeout(dataLoop, delay);
        }

        function handleConnectionSuccess() {
            if (!state.isConnected) {
                state.isConnected = true;
                if (!state.hasReceivedData) {
                    logEvent("System", "Bridge Connected. Receiving Telemetry.");
                    state.hasReceivedData = true;
                }
            }
        }

        function handleDisconnect() {
            state.isConnected = false;
            // Zero out display targets on disconnect
            state.target = { 
                gasPhys: 0, gasLog: 0, clutchPhys: 0, clutchLog: 0,
                lagTotal: 0, lagPed: 0, lagBrg: 0, lagDsh: 0 
            };
            state.frame = {}; // Clear frame to prevent stale telemetry in map
        }

        function processFrame(frame, startFetch, framesReceived) {
            state.frame = frame;
            
            // 1. Dash Metrics
            const dashLag = performance.now() - startFetch;
            frame.lagDash = dashLag; // Inject into frame for display
            frame.activeUpdateInterval = state.activeInterval;

            // 2. Latency Sum
            const pedLag = frame.fullLoopTime_ms || 0;
            const brgLag = frame.metricLoopProcessMs || 0;
            const httpLag = frame.metricHttpProcessMs || 0;
            const totalLag = pedLag + brgLag + httpLag + dashLag;
            frame.lagTotal = totalLag;

            // 3. Set Targets for Interpolation
            state.target.gasPhys = frame.gas_physical_pct || 0;
            state.target.gasLog = frame.gas_logical_pct || 0;
            state.target.clutchPhys = frame.clutch_physical_pct || 0;
            state.target.clutchLog = frame.clutch_logical_pct || 0;
            
            state.target.lagTotal = totalLag;
            state.target.lagPed = pedLag;
            // Merge Bridge Processing and HTTP Serialization for display
            state.target.lagBrg = brgLag + httpLag;
            state.target.lagDsh = dashLag;

            // 4. Events
            if (frame.gas_alert_triggered) logEvent("Alert", `Gas Drift: ${frame.percentReached}%`);
            if (frame.clutch_alert_triggered) logEvent("Warn", "Rudder Noise Detected");
            if (frame.gas_estimate_decreased) logEvent("Info", `Est. Deadzone: ${frame.best_estimate_percent}%`);
            if (frame.gas_auto_adjust_applied) logEvent("Info", "Auto-Adjust Applied");
            // Controller states
            if (frame.controller_disconnected) logEvent("Alert", "Controller Disconnected");
            if (frame.controller_reconnected) logEvent("Info", "Controller Reconnected");

            // 5. History
            pushHistory(state.lagHistory, {
                t: Date.now(),
                total: totalLag,
                ped: pedLag,
                brg: brgLag,
                dash: dashLag
            });
            calcAverages();

            pushHistory(state.pedalHistory, {
                t: Date.now(),
                gasP: frame.gas_physical_pct || 0,
                clutchP: frame.clutch_physical_pct || 0
            });
        }

        /**
         * RENDER LOOP (60fps Interpolated)
         */
        function renderLoop() {
            // Linear Interpolation (Lerp) factor (0.1 = smooth, 1.0 = instant)
            const lerp = 0.2; 
            
            // Interpolate values
            state.display.gasPhys += (state.target.gasPhys - state.display.gasPhys) * lerp;
            state.display.gasLog += (state.target.gasLog - state.display.gasLog) * lerp;
            state.display.clutchPhys += (state.target.clutchPhys - state.display.clutchPhys) * lerp;
            state.display.clutchLog += (state.target.clutchLog - state.display.clutchLog) * lerp;
            
            // Lags don't need heavy interpolation, maybe just direct for responsiveness or slight smoothing
            state.display.lagTotal = state.target.lagTotal; // Keep lags snappy
            state.display.lagPed = state.target.lagPed;
            state.display.lagBrg = state.target.lagBrg;
            state.display.lagDsh = state.target.lagDsh;

            renderUI();
            requestAnimationFrame(renderLoop);
        }

        function renderUI() {
            // Header
            if (state.isConnected) {
                els.brandStatus.textContent = "Online";
                els.brandStatus.style.color = "var(--neon-green)";
            } else {
                els.brandStatus.textContent = "Connecting...";
                els.brandStatus.style.color = "var(--text-muted)";
            }

            // Disconnect Indicator logic: Only show if network down (state.isConnected false)
            // or if controller sends disconnected flag.
            const ctrlDisc = state.frame.controller_disconnected === 1;
            const isDisc = !state.isConnected || ctrlDisc;
            
            if (isDisc) els.discInd.classList.add('active'); else els.discInd.classList.remove('active');

            // Header Metrics
            els.hdrTotal.textContent = state.display.lagTotal.toFixed(0);
            els.hdrPed.textContent = state.display.lagPed.toFixed(0);
            els.hdrBrg.textContent = state.display.lagBrg.toFixed(0);
            els.hdrDsh.textContent = state.display.lagDsh.toFixed(0);

            // Tabs
            if (state.currentTab === 'tab-racing') renderRacing();
            else if (state.currentTab === 'tab-lag') renderLag();
            else if (state.currentTab === 'tab-signals') renderSignals();
            else if (state.currentTab === 'tab-telemetry') renderTelemetry();
        }

        function renderRacing() {
            drawDualGauge(ctxGas, "GAS", state.display.gasPhys, state.display.gasLog);
            drawDualGauge(ctxClutch, "CLUTCH", state.display.clutchPhys, state.display.clutchLog);

            // Update Labels (use Display values for animation matching)
            els.lblGasPhys.textContent = state.display.gasPhys.toFixed(0) + "%";
            els.lblGasLog.textContent = state.display.gasLog.toFixed(0) + "%";
            els.lblClutchPhys.textContent = state.display.clutchPhys.toFixed(0) + "%";
            els.lblClutchLog.textContent = state.display.clutchLog.toFixed(0) + "%";

            // Status Chips
            const f = state.frame;
            toggleChip(els.stDrift, f.gas_alert_triggered, 'active-red');
            toggleChip(els.stNoise, f.clutch_alert_triggered, 'active-amber');
            toggleChip(els.stAuto, f.gas_auto_adjust_applied, 'active-blue');
            toggleChip(els.stRacing, f.isRacing, 'active-green');
        }

        function renderLag() {
            els.cardTotal.textContent = state.display.lagTotal.toFixed(0) + " ms";
            els.cardPed.textContent = state.display.lagPed.toFixed(0) + " ms";
            els.cardBrg.textContent = state.display.lagBrg.toFixed(0) + " ms";
            els.cardDsh.textContent = state.display.lagDsh.toFixed(0) + " ms";

            els.avgTotal.textContent = `Avg 3s: ${state.avgLagTotal.toFixed(1)}`;
            els.avgPed.textContent = `Avg 3s: ${state.avgLagPed.toFixed(1)}`;
            els.avgBrg.textContent = `Avg 3s: ${state.avgLagBrg.toFixed(1)}`;
            els.avgDsh.textContent = `Avg 3s: ${state.avgLagDash.toFixed(1)}`;

            resizeCanvas(els.cvsLag);
            drawHistoryChart(ctxLag, state.lagHistory, ['total', 'brg', 'dash', 'ped'], 
                             ['#ff3333', '#39ff14', '#ff00ff', '#00f3ff'], 
                             0, null, true);
        }

        function renderSignals() {
            resizeCanvas(els.cvsWaveGas);
            resizeCanvas(els.cvsWaveClutch);
            drawHistoryChart(ctxWaveGas, state.pedalHistory, ['gasP'], ['#00f3ff'], 0, 100, false);
            drawHistoryChart(ctxWaveClutch, state.pedalHistory, ['clutchP'], ['#39ff14'], 0, 100, false);
        }

        function renderTelemetry() {
            const f = state.frame;
            Object.keys(TELE_DEFS).forEach(key => {
                let val = f[key];
                if (typeof val === 'number') val = (val % 1 === 0) ? val : val.toFixed(1);
                if (val === undefined) val = "--";
                const el = document.getElementById(`tele-${key}`);
                if (el) el.textContent = val;
            });
        }

        // --- Canvas & Utils ---
        function toggleChip(el, active, activeClass) {
            if (active) el.classList.add(activeClass); else el.classList.remove(activeClass);
        }
        function resizeCanvas(cvs) {
            const rect = cvs.parentElement.getBoundingClientRect();
            const availHeight = rect.height - (cvs.previousElementSibling ? 30 : 0);
            if (cvs.width !== rect.width || cvs.height !== availHeight) {
                cvs.width = rect.width; cvs.height = availHeight; 
            }
        }
        function drawDualGauge(ctx, label, phys, log) {
            const w = ctx.canvas.width, h = ctx.canvas.height;
            const cx = w/2, cy = h/2, rOuter = (w/2)-15, rInner = rOuter-30;
            ctx.clearRect(0, 0, w, h);
            ctx.lineCap = 'round'; ctx.lineWidth = 20; ctx.strokeStyle = '#222';
            ctx.beginPath(); ctx.arc(cx, cy, rOuter, 0.75*Math.PI, 2.25*Math.PI); ctx.stroke();
            ctx.beginPath(); ctx.arc(cx, cy, rInner, 0.75*Math.PI, 2.25*Math.PI); ctx.stroke();
            const physAngle = 0.75*Math.PI + (1.5*Math.PI*(phys/100));
            ctx.lineWidth = 20; const grad = ctx.createLinearGradient(0,0,w,0);
            grad.addColorStop(0,'#00f3ff'); grad.addColorStop(1,'#0088aa');
            ctx.strokeStyle = phys>0 ? grad : '#222';
            if (phys>0) { ctx.beginPath(); ctx.arc(cx, cy, rOuter, 0.75*Math.PI, physAngle); ctx.stroke(); }
            const logAngle = 0.75*Math.PI + (1.5*Math.PI*(log/100));
            let innerColor = (log===0)?'#fff':(log>=99)?'#ff3333':'#39ff14';
            ctx.strokeStyle = innerColor; ctx.shadowBlur = 15; ctx.shadowColor = innerColor;
            ctx.beginPath(); ctx.arc(cx, cy, rInner, 0.75*Math.PI, logAngle); ctx.stroke();
            ctx.shadowBlur = 0;
            ctx.fillStyle = innerColor; ctx.font = "bold 80px monospace"; 
            ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText(Math.round(log), cx, cy);
            ctx.fillStyle = "#777"; ctx.font = "bold 32px sans-serif"; ctx.fillText(label, cx, cy+60);
        }
        function drawHistoryChart(ctx, history, keys, colors, minFixed, maxFixed, isMultiLine) {
            const w = ctx.canvas.width, h = ctx.canvas.height;
            ctx.clearRect(0, 0, w, h);
            if (history.length < 2) return;
            let minVal = minFixed!==null?minFixed:0;
            let maxVal = maxFixed;
            if (maxVal === null) {
                maxVal = 0;
                history.forEach(d => keys.forEach(k => {if (d[k]>maxVal) maxVal = d[k];}));
                maxVal = Math.max(maxVal, 10) * 1.1; 
            }
            const pL=40, pR=10, pT=10, pB=30;
            const mapX = (i) => pL + (i/(MAX_HISTORY-1))*(w-pL-pR);
            const mapY = (val) => h - pB - ((val-minVal)/(maxVal-minVal))*(h-pT-pB);
            
            ctx.strokeStyle = '#222'; ctx.lineWidth = 1; ctx.fillStyle = '#555';
            ctx.font = '12px monospace'; ctx.textAlign = 'right';
            for(let i=0; i<=4; i++) {
                const val = minVal+(maxVal-minVal)*(i/4);
                const y = mapY(val);
                ctx.beginPath(); ctx.moveTo(pL, y); ctx.lineTo(w-pR, y); ctx.stroke();
                ctx.fillText(val.toFixed(0), pL-5, y+4);
            }
            ctx.textAlign = 'center';
            for(let i=0; i<5; i++) {
                const x = mapX((MAX_HISTORY-1)*(i/4));
                const sec = (MAX_HISTORY*(state.activeInterval||50))/1000 * (1-(i/4));
                ctx.fillText(sec===0?"Now":`-${sec.toFixed(0)}s`, x, h-8);
                ctx.beginPath(); ctx.moveTo(x, h-pB); ctx.lineTo(x, h-pB+5); ctx.stroke();
            }
            keys.forEach((key, idx) => {
                ctx.beginPath(); ctx.strokeStyle = colors[idx]; ctx.lineWidth = 2;
                ctx.shadowBlur = isMultiLine?0:4; ctx.shadowColor = colors[idx];
                history.forEach((d, i) => {
                    const x = mapX(i), y = mapY(d[key]);
                    if (i===0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                });
                ctx.stroke();
            });
            ctx.shadowBlur = 0;
        }

        // --- Interaction ---
        function showHoverTip(e, text) { els.hoverTip.textContent = text; els.hoverTip.classList.add('visible'); moveHoverTip(e); }
        function moveHoverTip(e) { els.hoverTip.style.left = (e.clientX+15)+'px'; els.hoverTip.style.top = (e.clientY+15)+'px'; }
        function hideHoverTip() { els.hoverTip.classList.remove('visible'); }
        function showModal(title, desc) { els.modalTitle.textContent = title; els.modalDesc.textContent = desc; els.modalOverlay.classList.add('open'); }
        window.closeModal = () => els.modalOverlay.classList.remove('open');
        window.switchTab = (tabId) => {
            state.currentTab = tabId;
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelector(`button[onclick="switchTab('${tabId}')"]`).classList.add('active');
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.getElementById(tabId).classList.add('active');
            renderUI(); 
        };
        function updateEventDOM(evt) {
            const item = document.createElement('div'); item.className='ticker-item';
            item.innerHTML = `<span class="ticker-time">${evt.timeStr}</span><span class="ticker-msg">${evt.type}: ${evt.msg}</span>`;
            els.tickerList.prepend(item); if (els.tickerList.children.length>5) els.tickerList.lastElementChild.remove();
            const row = document.createElement('div'); row.className='event-row';
            let c = '#fff'; if(evt.type==='Alert')c='var(--neon-red)'; if(evt.type==='Warn')c='var(--neon-amber)';
            row.innerHTML = `<div>${evt.timeStr}</div><div style="color:${c}">${evt.type}</div><div>${evt.msg}</div>`;
            els.fullEventList.prepend(row); if (els.fullEventList.children.length>50) els.fullEventList.lastElementChild.remove();
        }

        logEvent("System", "Dashboard Initialized. Waiting for Bridge...");
        
        // Start Loops
        dataLoop();
        renderLoop();

    </script>
</body>
</html>
```
- However none of the algorithms in the previous source code version were able to accurately calculate the exact amount of time to sleep to obtain exactly 1 frame.  Some times it woke to soon and got 0 frames, some times 2 frames, and also some times 1 which is the target.

- So We implemented a lot of new features and improvements, for example, we added many new algorithms to try to predict the next update interval so we get exactly 1 frame.
- And now the dashboard doesn't work, the graphs are dead, etc and we get this in the export CSV log:

```
Time,Type,Message
20:36:45.523,Error,pushHistory is not defined
20:36:43.492,Error,pushHistory is not defined
20:36:41.456,Error,pushHistory is not defined
20:36:39.424,Error,pushHistory is not defined
20:36:37.394,Error,pushHistory is not defined
20:36:35.361,Error,pushHistory is not defined
20:36:33.328,Error,pushHistory is not defined
20:36:31.298,Error,pushHistory is not defined
20:36:29.257,Error,pushHistory is not defined
20:36:29.256,System,Bridge Connected.
20:36:28.220,Error,signal is aborted without reason
20:36:26.176,System,Initializing Dashboard...
```

- This is the source code of the latest version with all the improvements but that doesn't work

```
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PedDash Arcade - Production v18</title>
    <style>
        :root {
            --bg-color: #050508;
            --panel-bg: #0f0f16;
            --text-main: #e0e0e0;
            --text-muted: #777;
            --neon-cyan: #00f3ff;
            --neon-green: #39ff14;
            --neon-magenta: #ff00ff;
            --neon-amber: #ffbf00;
            --neon-red: #ff3333;
            --header-height: 70px;
            --tab-height: 45px;
        }

        * { box-sizing: border-box; }

        body {
            margin: 0; padding: 0;
            background-color: var(--bg-color);
            color: var(--text-main);
            font-family: "Segoe UI", Tahoma, sans-serif;
            overflow: hidden;
            width: 100vw; height: 100vh;
            display: flex; flex-direction: column;
            user-select: none;
        }

        /* --- Header --- */
        header {
            height: var(--header-height);
            background: linear-gradient(to bottom, #1a1a24, #0f0f16);
            border-bottom: 1px solid #333;
            display: flex; justify-content: space-between; align-items: center;
            padding: 0 20px; flex-shrink: 0;
        }

        .brand { font-weight: bold; letter-spacing: 1px; color: var(--neon-cyan); font-size: 1.2em; text-shadow: 0 0 5px rgba(0, 243, 255, 0.4); }
        .brand span { font-size: 0.7em; color: var(--text-muted); font-weight: normal; margin-left: 10px; }

        .center-status { width: 300px; text-align: center; }
        .pill { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 0.85em; font-weight: bold; opacity: 0; transition: opacity 0.2s; margin: 0 5px; }
        .pill.active { opacity: 1; animation: pulse 2s infinite; }
        .pill-ffw { background: rgba(255, 191, 0, 0.1); color: var(--neon-amber); border: 1px solid var(--neon-amber); }
        .pill-disc { background: rgba(255, 51, 51, 0.1); color: var(--neon-red); border: 1px solid var(--neon-red); }

        @keyframes pulse { 0% { box-shadow: 0 0 5px currentColor; } 50% { box-shadow: 0 0 15px currentColor; } 100% { box-shadow: 0 0 5px currentColor; } }

        .lag-summary { text-align: right; font-family: monospace; display: flex; flex-direction: column; justify-content: center; }
        .lag-main { font-size: 1.6em; color: var(--text-main); font-weight: bold; line-height: 1.1; }
        .lag-details { font-size: 1.1em; color: var(--text-muted); margin-top: 2px; }

        /* --- Navigation --- */
        nav { height: var(--tab-height); background-color: #0f0f16; display: flex; border-bottom: 1px solid #333; flex-shrink: 0; }
        .tab-btn { background: transparent; border: none; color: var(--text-muted); padding: 0 25px; font-size: 1em; cursor: pointer; border-right: 1px solid #222; transition: all 0.2s; }
        .tab-btn:hover { color: #fff; background: #161620; }
        .tab-btn.active { color: var(--neon-cyan); background: #1a1a24; box-shadow: inset 0 -3px 0 var(--neon-cyan); }

        /* --- Main Content --- */
        main { flex-grow: 1; position: relative; overflow: hidden; padding: 15px; }
        .tab-content { display: none; height: 100%; width: 100%; flex-direction: column; }
        .tab-content.active { display: flex; }

        /* --- Racing Tab --- */
        .gauges-container { display: flex; justify-content: center; align-items: center; gap: 60px; flex-grow: 1; padding-bottom: 20px; }
        .gauge-wrapper { display: flex; flex-direction: column; align-items: center; width: 320px; }
        .gauge-canvas { margin-bottom: 15px; }
        .gauge-labels { display: flex; justify-content: space-between; width: 100%; font-family: monospace; font-size: 1.8em; color: var(--text-muted); font-weight: bold; }
        .status-strip { display: flex; justify-content: center; gap: 15px; padding: 10px; background: #0f0f16; border-radius: 8px; border: 1px solid #333; margin-bottom: 15px; flex-shrink: 0; }
        .status-chip { padding: 5px 15px; border-radius: 4px; font-size: 0.9em; font-weight: bold; background: #222; color: #555; text-transform: uppercase; transition: all 0.2s; }
        .status-chip.active-red { background: rgba(255, 51, 51, 0.2); color: var(--neon-red); box-shadow: 0 0 8px var(--neon-red); border: 1px solid var(--neon-red); }
        .status-chip.active-amber { background: rgba(255, 191, 0, 0.2); color: var(--neon-amber); box-shadow: 0 0 8px var(--neon-amber); border: 1px solid var(--neon-amber); }
        .status-chip.active-blue { background: rgba(0, 243, 255, 0.2); color: var(--neon-cyan); box-shadow: 0 0 8px var(--neon-cyan); border: 1px solid var(--neon-cyan); }
        .status-chip.active-green { background: rgba(57, 255, 20, 0.2); color: var(--neon-green); box-shadow: 0 0 8px var(--neon-green); border: 1px solid var(--neon-green); }
        .ticker-container { height: 100px; background: #000; border: 1px solid #333; border-radius: 4px; padding: 10px; overflow-y: hidden; font-family: monospace; font-size: 1em; flex-shrink: 0; }
        .ticker-list { display: flex; flex-direction: column-reverse; }
        .ticker-item { margin-bottom: 4px; border-bottom: 1px solid #222; padding-bottom: 2px; }
        .ticker-time { color: var(--text-muted); margin-right: 10px; }

        /* --- Lag Tab --- */
        .lag-panel { display: grid; grid-template-rows: max-content 35vh; align-content: start; height: 100%; gap: 20px; }
        .lag-metrics-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; }
        .metric-card { background: #0f0f16; border: 1px solid #333; border-radius: 8px; padding: 15px; text-align: center; }
        .metric-card h3 { margin: 0 0 5px 0; font-size: 1em; color: var(--text-muted); }
        .metric-card .value { font-size: 1.8em; font-weight: bold; font-family: monospace; }
        .metric-avg { font-size: 0.8em; color: #555; margin-top: 5px; font-family: monospace; }
        .chart-container { background: #0f0f16; border: 1px solid #333; border-radius: 8px; padding: 15px; position: relative; overflow: hidden; }

        /* --- Signals Tab --- */
        .signals-layout { display: grid; grid-template-rows: 30vh 1fr; gap: 20px; height: 100%; }
        .waveforms-row { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; min-height: 0; }
        .waveform-card { background: #0f0f16; border: 1px solid #333; border-radius: 8px; padding: 10px; display: flex; flex-direction: column; position: relative; overflow: hidden; min-height: 0; }
        .waveform-card h4 { margin: 0 0 10px 0; color: var(--text-muted); font-size: 1.1em; flex-shrink: 0; }
        .events-table-container { background: #0f0f16; border: 1px solid #333; border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; min-height: 0; }
        .events-header { background: #1a1a24; padding: 10px; display: grid; grid-template-columns: 100px 150px 1fr 120px; font-weight: bold; font-size: 1em; border-bottom: 1px solid #333; flex-shrink: 0; align-items: center; }
        .events-list { overflow-y: auto; flex-grow: 1; font-family: monospace; font-size: 1em; }
        .event-row { display: grid; grid-template-columns: 100px 150px 1fr; padding: 6px 10px; border-bottom: 1px solid #222; }
        .btn-export { background: #222; border: 1px solid #555; color: #fff; padding: 6px 12px; cursor: pointer; border-radius: 4px; font-size: 0.85em; }
        .btn-export:hover { background: #333; border-color: var(--neon-cyan); }

        /* --- Telemetry Map --- */
        .tele-container { height: 100%; overflow-y: auto; padding: 10px; display: flex; flex-direction: column; gap: 30px; }
        .tele-group { display: flex; flex-direction: column; }
        .tele-group-header { color: var(--neon-cyan); border-bottom: 1px solid #333; padding-bottom: 5px; margin-bottom: 15px; font-size: 1.1em; text-transform: uppercase; font-weight: bold; }
        .tele-grid-section { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 15px; }
        .tele-card { background: #161620; border: 1px solid #333; border-radius: 6px; padding: 15px; cursor: pointer; transition: all 0.2s; }
        .tele-card:hover { border-color: var(--neon-cyan); background: #1a1a24; transform: translateY(-2px); }
        .tele-card h5 { margin: 0 0 5px 0; color: var(--text-muted); font-size: 0.85em; text-transform: uppercase; }
        .tele-card .tele-val { font-size: 1.4em; font-family: monospace; font-weight: bold; color: #fff; word-break: break-all; }
        .tele-val.warn-red { color: var(--neon-red); text-shadow: 0 0 5px var(--neon-red); }

        /* --- Config Tab --- */
        .config-panel { padding: 20px; display: grid; grid-template-columns: 1fr 1fr; gap: 40px; overflow-y: auto; }
        .config-group { background: #161620; border: 1px solid #333; border-radius: 8px; padding: 20px; }
        .config-group h3 { margin-top: 0; color: var(--neon-cyan); border-bottom: 1px solid #444; padding-bottom: 10px; }
        .form-row { margin-bottom: 15px; display: flex; flex-direction: column; }
        .form-row label { color: #aaa; font-size: 0.9em; margin-bottom: 5px; }
        .form-row input, .form-row select { background: #000; border: 1px solid #444; color: #fff; padding: 10px; font-family: monospace; font-size: 1em; }
        .form-row input[type="checkbox"] { width: 22px; height: 22px; cursor: pointer; }
        .row-inline { flex-direction: row; align-items: center; gap: 12px; }

        /* --- Modals/Tips --- */
        .hover-tip { position: fixed; background: rgba(0,0,0,0.95); border: 1px solid var(--neon-cyan); color: var(--neon-cyan); padding: 8px 12px; border-radius: 4px; font-size: 0.85em; pointer-events: none; z-index: 1000; opacity: 0; transition: opacity 0.1s; transform: translateY(-100%); margin-top: -10px; }
        .hover-tip.visible { opacity: 1; }
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.8); z-index: 2000; display: flex; justify-content: center; align-items: center; opacity: 0; pointer-events: none; transition: opacity 0.2s; }
        .modal-overlay.open { opacity: 1; pointer-events: auto; }
        .modal-card { background: #1a1a24; border: 1px solid var(--neon-cyan); box-shadow: 0 0 30px rgba(0, 243, 255, 0.3); width: 550px; max-width: 90%; padding: 25px; border-radius: 12px; position: relative; }
        .modal-card h2 { margin-top: 0; color: var(--neon-cyan); border-bottom: 1px solid #333; padding-bottom: 10px; }
        .modal-card p { color: #e0e0e0; line-height: 1.6; font-size: 1.05em; }
        .modal-close { position: absolute; top: 15px; right: 15px; background: none; border: none; color: #777; font-size: 2em; cursor: line-height: 1; }
        .modal-close:hover { color: #fff; }

        /* --- Error Handling UI --- */
        #global-error { position: fixed; bottom: 0; left: 0; width: 100%; background: #c00; color: #fff; padding: 15px; font-family: monospace; font-size: 12px; z-index: 9999; display: none; white-space: pre-wrap; overflow-y: auto; max-height: 200px; border-top: 2px solid #fff; }

        canvas { display: block; width: 100%; height: 100%; }
    </style>
    <script>
        // --- 0. EMERGENCY ERROR BOX ---
        window.onerror = function(msg, url, line, col, error) {
            const box = document.getElementById('global-error');
            if(box) {
                box.style.display = 'block';
                box.textContent += `[JS ERROR] ${msg}\nLine: ${line}, Col: ${col}\n${error ? error.stack : ''}\n\n`;
            }
            return false;
        };
    </script>
</head>
<body>
    <div id="global-error"></div>

    <header>
        <div class="brand">PedDash <span id="session-status">Telemetry Arcade</span></div>
        <div class="center-status">
            <div id="disc-indicator" class="pill pill-disc">⚠ DISCONNECTED</div>
            <div id="ffw-indicator" class="pill pill-ffw">⏩ FFW CATCH-UP</div>
        </div>
        <div class="lag-summary">
            <div class="lag-main">Latency: <span id="hdr-total-lag" class="txt-red">--</span> ms</div>
            <div class="lag-details">
                Ped: <span id="hdr-ped-lag">00</span> | Brg: <span id="hdr-brg-lag">00</span> | Dsh: <span id="hdr-dsh-lag">00</span>
            </div>
        </div>
    </header>

    <nav>
        <button class="tab-btn active" id="btn-racing" onclick="switchTab('tab-racing')">Racing</button>
        <button class="tab-btn" id="btn-lag" onclick="switchTab('tab-lag')">Lag & Timing</button>
        <button class="tab-btn" id="btn-signals" onclick="switchTab('tab-signals')">Signals & Events</button>
        <button class="tab-btn" id="btn-telemetry" onclick="switchTab('tab-telemetry')">Data Map</button>
        <button class="tab-btn" id="btn-config" onclick="switchTab('tab-config')">Configuration</button>
    </nav>

    <main>
        <!-- Tab 1: Racing -->
        <div id="tab-racing" class="tab-content active">
            <div class="gauges-container">
                <div class="gauge-wrapper">
                    <canvas id="canvas-gas" width="300" height="300" class="gauge-canvas"></canvas>
                    <div class="gauge-labels">
                        <span>PHYS: <span id="lbl-gas-phys">0%</span></span>
                        <span>LOG: <span id="lbl-gas-log">0%</span></span>
                    </div>
                </div>
                <div class="gauge-wrapper">
                    <canvas id="canvas-clutch" width="300" height="300" class="gauge-canvas"></canvas>
                    <div class="gauge-labels">
                        <span>PHYS: <span id="lbl-clutch-phys">0%</span></span>
                        <span>LOG: <span id="lbl-clutch-log">0%</span></span>
                    </div>
                </div>
            </div>
            <div class="status-strip">
                <div id="status-drift" class="status-chip">Drift Alert</div>
                <div id="status-noise" class="status-chip">Rudder Noise</div>
                <div id="status-auto" class="status-chip">Auto-Adjust</div>
                <div id="status-racing" class="status-chip">Racing</div>
            </div>
            <div class="ticker-container"><div id="ticker-list" class="ticker-list"></div></div>
        </div>

        <!-- Tab 2: Lag -->
        <div id="tab-lag" class="tab-content">
            <div class="lag-panel">
                <div class="lag-metrics-grid">
                    <div class="metric-card"><h3>Latency Total</h3><div class="value txt-red" id="card-total-lag">0 ms</div><div class="metric-avg" id="avg-total-lag">Avg: 0</div></div>
                    <div class="metric-card"><h3>PedMon (C)</h3><div class="value txt-cyan" id="card-ped-lag">0 ms</div><div class="metric-avg" id="avg-ped-lag">Avg: 0</div></div>
                    <div class="metric-card"><h3>Bridge (PS)</h3><div class="value txt-green" id="card-brg-lag">0 ms</div><div class="metric-avg" id="avg-brg-lag">Avg: 0</div></div>
                    <div class="metric-card"><h3>Dash (JS)</h3><div class="value txt-mag" id="card-dsh-lag">0 ms</div><div class="metric-avg" id="avg-dsh-lag">Avg: 0</div></div>
                </div>
                <div class="chart-container"><canvas id="canvas-lag-chart"></canvas></div>
            </div>
        </div>

        <!-- Tab 3: Signals -->
        <div id="tab-signals" class="tab-content">
            <div class="signals-layout">
                <div class="waveforms-row">
                    <div class="waveform-card"><h4>Gas Input History</h4><canvas id="canvas-wave-gas"></canvas></div>
                    <div class="waveform-card"><h4>Clutch Input History</h4><canvas id="canvas-wave-clutch"></canvas></div>
                </div>
                <div class="events-table-container">
                    <div class="events-header">
                        <div>Time</div><div>Type</div><div>Details</div>
                        <div style="text-align:right;"><button class="btn-export" onclick="exportLogs()">Export CSV</button></div>
                    </div>
                    <div id="full-event-list" class="events-list"></div>
                </div>
            </div>
        </div>

        <!-- Tab 4: Telemetry -->
        <div id="tab-telemetry" class="tab-content">
            <div id="tele-container" class="tele-container"></div>
        </div>

        <!-- Tab 5: Configuration -->
        <div id="tab-config" class="tab-content">
            <div class="config-panel">
                <div class="config-group">
                    <h3>Polling Control</h3>
                    <div class="form-row">
                        <label>Update Interval (ms) - Set 0 for Smart</label>
                        <input type="number" id="cfg-interval" value="50" onchange="updateConfig('UPDATE_INTERVAL_MS', this.value)">
                    </div>
                    <div class="form-row">
                        <label>Smart Algorithm Mode</label>
                        <select id="cfg-algo" onchange="updateConfig('ALGO_MODE', this.value)">
                            <option value="SMOOTH_CONVERGENCE" selected>SMOOTH_CONVERGENCE (Recommended)</option>
                            <option value="FRAME_LOCK">FRAME_LOCK</option>
                            <option value="ALGO_DIGITAL_PLL">ALGO_DIGITAL_PLL (ChatGPT)</option>
                            <option value="ALGO_INTEGRAL_FLOW">ALGO_INTEGRAL_FLOW</option>
                            <option value="ALGO_GROK_PI">ALGO_GROK_PI</option>
                            <option value="ALGO_DEEPSEEK_PI">ALGO_DEEPSEEK_PI</option>
                            <option value="ALGO_QWEN_HYSTERESIS">ALGO_QWEN_HYSTERESIS</option>
                            <option value="ALGO_CLAUDE_EWAP">ALGO_CLAUDE_EWAP</option>
                            <option value="ALGO_LEGACY">ALGO_LEGACY</option>
                        </select>
                    </div>
                    <div class="form-row">
                        <label>Manual Update Factor</label>
                        <input type="number" step="0.01" id="cfg-factor" value="1.00" onchange="updateConfig('MANUAL_UPDATE_FACTOR', this.value)">
                    </div>
                </div>
                <div class="config-group">
                    <h3>System & Debug</h3>
                    <div class="form-row row-inline"><input type="checkbox" id="cfg-bounds" checked onchange="updateConfig('USE_BOUNDS_CHECK', this.checked)"><label>Use Bounds Check</label></div>
                    <div class="form-row row-inline"><input type="checkbox" id="cfg-debug" checked onchange="updateConfig('ENABLE_ALGO_DEBUG', this.checked)"><label>Algorithm Debug Logging</label></div>
                    <div class="form-row row-inline"><input type="checkbox" id="cfg-empty" checked onchange="updateConfig('LOG_EMPTY_FRAMES', this.checked)"><label>Log Empty Frames</label></div>
                    <div class="form-row"><label>Max History (lines)</label><input type="number" id="cfg-history" value="1000" onchange="updateConfig('MAX_HISTORY_LINES', this.value)"></div>
                </div>
            </div>
        </div>
    </main>

    <script>
        /**
         * 1. CONFIGURATION
         */
        const config = {
            UPDATE_INTERVAL_MS: 50,
            ALGO_MODE: "SMOOTH_CONVERGENCE",
            MANUAL_UPDATE_FACTOR: 1.00,
            USE_BOUNDS_CHECK: true,
            ENABLE_ALGO_DEBUG: true,
            LOG_EMPTY_FRAMES: true,
            MAX_HISTORY_LINES: 1000
        };

        const BRIDGE_URL = "http://localhost:8181/";
        const MAX_CHART_HISTORY = 300;
        const AVG_WINDOW_S = 3;

        /**
         * 2. STATE
         */
        const state = {
            currentTab: 'tab-racing',
            isConnected: false,
            hasData: false,
            activeInterval: 50,
            getCounter: 0,
            frame: {},
            target: { gasP:0, gasL:0, clP:0, clL:0, lagT:0, lagP:0, lagB:0, lagD:0 },
            display: { gasP:0, gasL:0, clP:0, clL:0, lagT:0, lagP:0, lagB:0, lagD:0 },
            lagHistory: [], pedalHistory: [], events: [],
            avgLagT:0, avgLagP:0, avgLagB:0, avgLagD:0
        };

        const algoState = {
            integral: 0, history: [], nextTarget: NaN, mode: "ACQUIRE", holdBad: 0,
            errLP: 0, errInt: 0, ewap_ema: 1.0, ewap_int: 0, qwen_int: 0, qwen_dir: 0, flowAvg: 1.0
        };

        // UI Cache
        let els = {};

        /**
         * 3. TELEMETRY DEFINITIONS (UNABRIDGED)
         */
        const TELE_GROUPS = [
            { title: "Pedal Metrics", keys: ['gas_physical_pct', 'gas_logical_pct', 'clutch_physical_pct', 'clutch_logical_pct'] },
            { title: "Raw Inputs", keys: ['rawGas', 'gasValue', 'rawClutch', 'clutchValue', 'axisMax', 'axis_normalization_enabled', 'joy_ID', 'joy_Flags'] },
            { title: "Logic State", keys: ['isRacing', 'peakGasInWindow', 'best_estimate_percent', 'lastFullThrottleTime', 'lastGasActivityTime', 'repeatingClutchCount'] },
            { title: "Gas Tuning", keys: ['gas_deadzone_in', 'gas_deadzone_out', 'gas_min_usage_percent', 'gas_window', 'gas_timeout', 'auto_gas_deadzone_enabled'] },
            { title: "Latency (ms)", keys: ['lagTotal', 'fullLoopTime_ms', 'metricLoopProcessMs', 'metricHttpProcessMs', 'lagDash', 'activeUpdateInterval'] },
            { title: "Event Flags", keys: ['gas_alert_triggered', 'clutch_alert_triggered', 'gas_auto_adjust_applied', 'gas_estimate_decreased', 'controller_disconnected', 'controller_reconnected'] },
            { title: "Diagnostics", keys: ['pedDashGetCount', 'algoMode', 'framesReceivedLastFetch', 'telemetry_sequence', 'batchId', 'receivedAtUnixMs', 'currentTime'] }
        ];

        const TELE_DEFS = {
            gas_physical_pct: { label: "Gas Phys %", short: "gas_physical_pct: Raw Input", long: "Raw percentage of gas pedal physical travel. (Source: PedMon)" },
            gas_logical_pct: { label: "Gas Log %", short: "gas_logical_pct: Game Value", long: "Final input value sent to game after deadzones. (Source: PedMon)" },
            clutch_physical_pct: { label: "Clutch Phys %", short: "clutch_physical_pct: Raw Input", long: "Raw percentage of clutch physical travel. (Source: PedMon)" },
            clutch_logical_pct: { label: "Clutch Log %", short: "clutch_logical_pct: Game Value", long: "Final clutch value sent to the game. (Source: PedMon)" },
            rawGas: { label: "Gas Raw", short: "rawGas: Hardware units", long: "Direct value from joyGetPosEx. (Source: PedMon)" },
            gasValue: { label: "Gas Norm", short: "gasValue: Normalized units", long: "Hardware value after inversion correction. (Source: PedMon)" },
            rawClutch: { label: "Clutch Raw", short: "rawClutch: Hardware units", long: "Direct value from JoyAPI. (Source: PedMon)" },
            clutchValue: { label: "Clutch Norm", short: "clutchValue: Normalized units", long: "Hardware value after inversion. (Source: PedMon)" },
            axisMax: { label: "Axis Max", short: "axisMax: Scale", long: "The maximum range of the joystick axis. (Source: PedMon)" },
            axis_normalization_enabled: { label: "Norm Flag", short: "axis_normalization_enabled: Boolean flag", long: "If 1, PedMon mirrors inverted hardware signals. (Source: PedMon)" },
            joy_ID: { label: "Joy ID", short: "joy_ID: Integer ID", long: "Windows Joystick ID currently monitored. (Source: PedMon)" },
            joy_Flags: { label: "Joy Flags", short: "joy_Flags: Bitmask", long: "WinMM flags used for capturing data. (Source: PedMon)" },
            isRacing: { label: "Is Racing", short: "isRacing: Boolean flag", long: "Indicates if the user is currently driving. (Source: PedMon)" },
            peakGasInWindow: { label: "Peak Gas", short: "peakGasInWindow: Max", long: "Highest gas value reached in current window. (Source: PedMon)" },
            best_estimate_percent: { label: "Best Est %", short: "best_estimate_percent", long: "Suggested ideal deadzone for pedal health. (Source: PedMon)" },
            lastFullThrottleTime: { label: "Last Full T", short: "lastFullThrottleTime", long: "TickCount when full throttle was last hit. (Source: PedMon)" },
            lastGasActivityTime: { label: "Last Activity", short: "lastGasActivityTime", long: "TickCount of last pedal movement. (Source: PedMon)" },
            repeatingClutchCount: { label: "Noise Reps", short: "repeatingClutchCount", long: "Sequential frames of noise detected. (Source: PedMon)" },
            gas_deadzone_in: { label: "DZ In %", short: "gas_deadzone_in", long: "Percentage of travel treated as idle. (Source: PedMon)" },
            gas_deadzone_out: { label: "DZ Out %", short: "gas_deadzone_out", long: "Percentage of travel treated as 100%. (Source: PedMon)" },
            gas_min_usage_percent: { label: "Min Usage %", short: "gas_min_usage_percent", long: "Min travel needed to validate drift checks. (Source: PedMon)" },
            gas_window: { label: "Gas Window", short: "gas_window: Seconds", long: "Duration checked for full throttle events. (Source: PedMon)" },
            gas_timeout: { label: "Gas Timeout", short: "gas_timeout: Seconds", long: "Seconds of idle before assuming paused. (Source: PedMon)" },
            auto_gas_deadzone_enabled: { label: "Auto Adjust", short: "auto_gas_deadzone_enabled: Boolean", long: "If 1, PedMon lowers DZ Out automatically. (Source: PedMon)" },
            lagTotal: { label: "Total Latency", short: "lagTotal", long: "Total time across C, PS, and JS layers. (Source: PedDash)" },
            fullLoopTime_ms: { label: "C Loop", short: "fullLoopTime_ms", long: "Processing time of the C monitor loop. (Source: PedMon)" },
            metricLoopProcessMs: { label: "PS Loop", short: "metricLoopProcessMs", long: "Time PowerShell took to read shared memory. (Source: PedBridge)" },
            metricHttpProcessMs: { label: "PS HTTP", short: "metricHttpProcessMs", long: "Time Bridge took to serve JSON request. (Source: PedBridge)" },
            lagDash: { label: "JS Render", short: "lagDash: JS Time", long: "Time taken by browser to fetch and update UI. (Source: PedDash)" },
            activeUpdateInterval: { label: "Poll Interval", short: "activeUpdateInterval", long: "Current sleep time between fetches. (Source: PedDash)" },
            gas_alert_triggered: { label: "Evt: Gas", short: "gas_alert_triggered", long: "Fired when gas drift is detected. (Source: PedMon)" },
            clutch_alert_triggered: { label: "Evt: Clutch", short: "clutch_alert_triggered", long: "Fired when rudder noise is detected. (Source: PedMon)" },
            gas_auto_adjust_applied: { label: "Evt: AutoAdj", short: "gas_auto_adjust_applied", long: "Fired when deadzone was adjusted. (Source: PedMon)" },
            gas_estimate_decreased: { label: "Evt: EstDec", short: "gas_estimate_decreased", long: "Fired on new estimation discovery. (Source: PedMon)" },
            controller_disconnected: { label: "Evt: Disc", short: "controller_disconnected", long: "Fired when pedal device is lost. (Source: PedMon)" },
            controller_reconnected: { label: "Evt: Reconn", short: "controller_reconnected", long: "Fired when device is re-found. (Source: PedMon)" },
            pedDashGetCount: { label: "GET Count", short: "pedDashGetCount", long: "Total requests issued by the dashboard. (Source: PedDash)" },
            algoMode: { label: "Algo Mode", short: "algoMode", long: "The currently selected Smart Algorithm. (Source: PedDash)" },
            framesReceivedLastFetch: { label: "Frames Rx", short: "framesReceivedLastFetch", long: "Data points delivered in the last batch. (Source: PedDash)" },
            telemetry_sequence: { label: "Seq ID", short: "telemetry_sequence", long: "Increments per PedMon frame. (Source: PedMon)" },
            batchId: { label: "Batch ID", short: "batchId", long: "Increments per PedBridge response. (Source: PedBridge)" },
            receivedAtUnixMs: { label: "Bridge Rx", short: "receivedAtUnixMs", long: "Time bridge received data from C. (Source: PedBridge)" },
            currentTime: { label: "C Current", short: "currentTime", long: "Windows TickCount at capture. (Source: PedMon)" }
        };

        /**
         * 4. STRATEGIES
         */
        const AlgorithmStrategies = {
            "FRAME_LOCK": (rec, tP, current) => { const cruise = tP + 5; if (rec === 0) return tP; if (rec > 1) return 10; return cruise; },
            "SMOOTH_CONVERGENCE": (rec, tP, current) => { if (rec === 0) return Math.min(current * 1.1, tP * 1.5); if (rec === 1) return (current * 0.9) + (tP * 0.1); return current * 0.85; },
            "ALGO_DIGITAL_PLL": (rec, tP, current) => {
                const now = performance.now(); if (!Number.isFinite(algoState.nextTarget)) algoState.nextTarget = now;
                let e = (rec <= 0) ? 1 : (rec === 1 ? 0 : -(rec - 1)); algoState.errLP += 0.25 * (e - algoState.errLP); algoState.errInt = Math.max(-8, Math.min(8, algoState.errInt + algoState.errLP));
                let adjust = (6.0 * algoState.errLP) + (0.6 * algoState.errInt);
                if (algoState.mode === "ACQUIRE") { if (rec === 1) adjust -= 0.25; if (rec <= 0) { adjust += 5; algoState.mode = "HOLD"; algoState.holdBad = 0; algoState.errLP = 0; algoState.errInt = 0; } }
                else { if (rec !== 1) { if (++algoState.holdBad >= 2) { algoState.mode = "ACQUIRE"; algoState.holdBad = 0; algoState.errInt *= 0.5; } } else algoState.holdBad = 0; }
                adjust = Math.max(-25, Math.min(25, adjust)); const step = Math.max(tP*0.6, Math.min(tP*1.4, tP + adjust)); algoState.nextTarget += step;
                if (algoState.nextTarget < now + 2) { const def = (now + 2) - algoState.nextTarget; algoState.nextTarget += Math.ceil(def/step) * step; } return Math.max(0, algoState.nextTarget - now);
            },
            "ALGO_INTEGRAL_FLOW": (rec, tP, current) => { algoState.flowAvg = (0.2 * rec) + 0.8 * algoState.flowAvg; return current - ((algoState.flowAvg - 1.0) * 2.0); },
            "ALGO_GROK_PI": (rec, tP, current) => { const err = 1 - rec; algoState.integral = Math.max(-200, Math.min(200, algoState.integral + err)); return current + (10 * err) + (0.05 * algoState.integral); },
            "ALGO_DEEPSEEK_PI": (rec, tP, current) => {
                const err = 1.0 - rec; algoState.history.push(err); if (algoState.history.length > 5) algoState.history.shift();
                const smErr = algoState.history.reduce((a,b)=>a+b,0) / algoState.history.length; algoState.integral = Math.max(-200, Math.min(200, algoState.integral + smErr * 50));
                return (0.7 * current) + 0.3 * (tP + (15 * smErr) + (0.3 * algoState.integral));
            },
            "ALGO_QWEN_HYSTERESIS": (rec, tP, current) => { if (rec === 0) return Math.min(200, current * 1.15); const pErr = rec - 1; let adj = 8 * pErr; algoState.qwen_int = Math.max(-tP, Math.min(tP, algoState.qwen_int + pErr)); return current - (adj + 0.05 * algoState.qwen_int); },
            "ALGO_CLAUDE_EWAP": (rec, tP, current) => {
                algoState.ewap_ema = (0.3 * rec) + 0.7 * algoState.ewap_ema; const err = algoState.ewap_ema - 1.0; algoState.ewap_int = Math.max(-20, Math.min(20, algoState.ewap_int + err));
                let corr = (0.15 * err) + (0.02 * algoState.ewap_int); if (rec === 0 && algoState.ewap_ema < 0.5) corr = Math.min(corr, -0.05); if (rec >= 3) corr = Math.max(corr, 0.2); return current - (corr * tP);
            },
            "ALGO_LEGACY": (rec, tP, current) => { if (rec === 1) return tP; if (rec > 1) return current * (1 / rec); return tP; }
        };

        /**
         * 5. UTILS
         */
        function safeSetText(el, text) { if (el) el.textContent = text; }
        
        function switchTab(id) {
            state.currentTab = id;
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.id === 'btn-' + id.split('-')[1]));
            document.querySelectorAll('.tab-content').forEach(t => t.classList.toggle('active', t.id === id));
        }

        function updateConfig(k, v) {
            if (k === 'ALGO_MODE') { 
                logEvent("System", `Algo: ${v}`); 
                Object.keys(algoState).forEach(sk => algoState[sk] = (sk === 'mode' ? 'ACQUIRE' : (sk === 'history' ? [] : 0))); algoState.flowAvg = 1.0; algoState.ewap_ema = 1.0; 
            }
            config[k] = (typeof config[k] === 'number') ? parseFloat(v) : v;
        }

        function toggleChip(el, act, cls) { if (el) { if (act) el.classList.add(cls); else el.classList.remove(cls); } }

        function resizeCanvas(c) { if(!c) return; const r = c.parentElement.getBoundingClientRect(); const h = r.height - (c.previousElementSibling ? 30 : 0); if (c.width !== r.width || c.height !== h) { c.width = r.width; c.height = h; } }

        function calcAverages() { 
            const count = Math.max(1, (AVG_WINDOW_S * 1000) / (state.activeInterval || 50)); if (state.lagHistory.length === 0) return; 
            const recent = state.lagHistory.slice(-count); const len = recent.length; 
            state.avgLagT = recent.reduce((s,i) => s + i.total, 0) / len; state.avgLagP = recent.reduce((s,i) => s + i.ped, 0) / len; 
            state.avgLagB = recent.reduce((s,i) => s + i.brg, 0) / len; state.avgLagD = recent.reduce((s,i) => s + i.dash, 0) / len; 
        }

        function logEvent(t, m) { 
            if(state.events.length > 0 && state.events[0].msg === m && (Date.now() - state.events[0].ts) < 2000) return; 
            const d = new Date(); const ts = d.toLocaleTimeString('en-US',{hour12:false})+"."+String(d.getMilliseconds()).padStart(3,'0'); 
            const e = {ts:Date.now(),timeStr:ts,type:t,msg:m}; state.events.unshift(e); if (state.events.length > config.MAX_HISTORY_LINES) state.events.pop(); 
            const item = document.createElement('div'); item.className='ticker-item'; item.innerHTML=`<span class="ticker-time">${ts}</span><span>${t}: ${m}</span>`; 
            if (els.tickerList) { els.tickerList.prepend(item); if(els.tickerList.children.length > 5) els.tickerList.lastElementChild.remove(); }
            const row = document.createElement('div'); row.className='event-row'; let c='#fff'; if(t==='Alert') c='var(--neon-red)'; if(t==='Warn') c='var(--neon-amber)'; row.innerHTML=`<div>${ts}</div><div style="color:${c}">${t}</div><div>${m}</div>`; 
            if (els.fullEventList) { els.fullEventList.prepend(row); if(els.fullEventList.children.length > 100) els.fullEventList.lastElementChild.remove(); }
        }

        function exportLogs() { 
            const csv = "Time,Type,Message\n" + state.events.map(e => `${e.timeStr},${e.type},${e.msg}`).join("\n"); 
            const blob = new Blob([csv], { type: 'text/csv' }); const url = window.URL.createObjectURL(blob); 
            const a = document.createElement('a'); a.setAttribute('href', url); a.setAttribute('download', 'peddash_logs.csv'); document.body.appendChild(a); a.click(); document.body.removeChild(a); 
        }

        /**
         * 6. DRAWING
         */
        function drawDualGauge(ctx, label, phys, log) { 
            if (!ctx) return; const w=ctx.canvas.width, h=ctx.canvas.height, cx=w/2, cy=h/2, rO=(w/2)-15, rI=rO-30; 
            ctx.clearRect(0,0,w,h); ctx.lineCap='round'; ctx.lineWidth=20; ctx.strokeStyle='#222'; 
            ctx.beginPath(); ctx.arc(cx,cy,rO,0.75*Math.PI,2.25*Math.PI); ctx.stroke(); 
            ctx.beginPath(); ctx.arc(cx,cy,rI,0.75*Math.PI,2.25*Math.PI); ctx.stroke(); 
            const pA=0.75*Math.PI+(1.5*Math.PI*(phys/100)); const grad=ctx.createLinearGradient(0,0,w,0); grad.addColorStop(0,'#00f3ff'); grad.addColorStop(1,'#0088aa'); ctx.strokeStyle=phys>0?grad:'#222'; if(phys>0){ctx.beginPath(); ctx.arc(cx,cy,rO,0.75*Math.PI,pA); ctx.stroke();} 
            const lA=0.75*Math.PI+(1.5*Math.PI*(log/100)); let color=log===0?'#fff':log>=99?'#ff3333':'#39ff14'; ctx.strokeStyle=color; ctx.shadowBlur=15; ctx.shadowColor=color; ctx.beginPath(); ctx.arc(cx,cy,rI,0.75*Math.PI,lA); ctx.stroke(); ctx.shadowBlur=0; 
            ctx.fillStyle=color; ctx.font="bold 80px monospace"; ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText(Math.round(log),cx,cy); 
            ctx.fillStyle="#777"; ctx.font="bold 32px sans-serif"; ctx.fillText(label,cx,cy+60); 
        }

        function drawHistoryChart(ctx, data, keys, colors, min, max, multi) { 
            if (!ctx || !data || data.length < 2) return; 
            let mi=min!==null?min:0, ma=max; if(ma===null){ma=0; data.forEach(d=>keys.forEach(k=>{if(d[k]>ma)ma=d[k];})); ma=Math.max(ma,10)*1.1;} 
            const w=ctx.canvas.width, h=ctx.canvas.height, pL=40, pR=10, pT=10, pB=30; 
            const mX=(i)=>pL+(i/(MAX_CHART_HISTORY-1))*(w-pL-pR), mY=(v)=>h-pB-((v-mi)/(ma-mi))*(h-pT-pB); 
            ctx.strokeStyle='#222'; ctx.lineWidth=1; ctx.fillStyle='#555'; ctx.font='12px monospace'; ctx.textAlign='right'; 
            for(let i=0;i<=4;i++){ const v=mi+(ma-mi)*(i/4), y=mY(v); ctx.beginPath(); ctx.moveTo(pL,y); ctx.lineTo(w-pR,y); ctx.stroke(); ctx.fillText(v.toFixed(0),pL-5,y+4); } 
            ctx.textAlign='center'; for(let i=0;i<5;i++){ const x=mX((MAX_CHART_HISTORY-1)*(i/4)), s=((MAX_CHART_HISTORY*(state.activeInterval||50))/1000)*(1-(i/4)); ctx.fillText(s===0?"Now":`-${s.toFixed(0)}s`,x,h-8); ctx.beginPath(); ctx.moveTo(x,h-pB); ctx.lineTo(x,h-pB+5); ctx.stroke(); } 
            keys.forEach((k,idx)=>{ ctx.beginPath(); ctx.strokeStyle=colors[idx]; ctx.lineWidth=2; ctx.shadowBlur=multi?0:4; ctx.shadowColor=colors[idx]; data.forEach((d,i)=>{ const x=mX(i), y=mY(d[k]); if(i===0)ctx.moveTo(x,y); else ctx.lineTo(x,y); }); ctx.stroke(); }); ctx.shadowBlur=0; 
        }

        /**
         * 7. DATA LOOP
         */
        async function dataLoop() {
            const startFetch = performance.now();
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 2000);

            try {
                const res = await fetch(BRIDGE_URL, { signal: controller.signal });
                clearTimeout(timeoutId);
                const json = await res.json();
                state.getCounter++;

                if (!json || !json.frames || json.frames.length === 0) {
                    if (config.LOG_EMPTY_FRAMES) logEvent("Info", "Bridge: 0 frames received");
                    updateNonFrameMetrics(startFetch);
                    schedule(0, 100);
                    return;
                }

                const latest = json.frames[json.frames.length - 1];
                latest.framesReceivedLastFetch = json.frames.length;
                latest.pendingFrameCount = json.bridgeInfo.pendingFrameCount;
                latest.batchId = json.bridgeInfo.batchId;
                latest.receivedAtUnixMs = json.bridgeInfo.servedAtUnixMs;

                state.isConnected = true;
                if (!state.hasData) { logEvent("System", "Bridge Connected."); state.hasData = true; }
                processFrame(latest, startFetch);
                schedule(json.frames.length, (latest.sleep_Time || 100) + (latest.fullLoopTime_ms || 0));

            } catch (e) {
                clearTimeout(timeoutId);
                logEvent("Error", e.message);
                state.isConnected = false;
                state.target = { gasP:0, gasL:0, clP:0, clL:0, lagT:0, lagP:0, lagB:0, lagD:0 };
                setTimeout(dataLoop, 1000);
            }
        }

        function schedule(rec, tP) {
            let sleep = config.UPDATE_INTERVAL_MS;
            if (sleep === 0) {
                try { sleep = AlgorithmStrategies[config.ALGO_MODE](rec, tP, state.activeInterval); }
                catch(e) { sleep = 50; }
                sleep *= config.MANUAL_UPDATE_FACTOR;
                if (config.USE_BOUNDS_CHECK) sleep = Math.max(10, Math.min(sleep, 1000));
            }
            state.activeInterval = sleep;
            setTimeout(dataLoop, sleep);
        }

        function processFrame(f, start) {
            state.frame = f;
            const dLag = performance.now() - start;
            f.lagDash = dLag; f.activeUpdateInterval = state.activeInterval;
            f.pedDashGetCount = state.getCounter; f.algoMode = config.ALGO_MODE;
            const tLag = (f.fullLoopTime_ms||0) + (f.metricLoopProcessMs||0) + (f.metricHttpProcessMs||0) + dLag;
            f.lagTotal = tLag;
            state.target = { gasP: f.gas_physical_pct, gasL: f.gas_logical_pct, clP: f.clutch_physical_pct, clL: f.clutch_logical_pct, lagT: tLag, lagP: f.fullLoopTime_ms, lagB: f.metricLoopProcessMs+f.metricHttpProcessMs, lagD: dLag };
            if (f.gas_alert_triggered) logEvent("Alert", `Gas Drift: ${f.percentReached}%`);
            if (f.clutch_alert_triggered) logEvent("Warn", "Rudder Noise");
            if (f.controller_disconnected) logEvent("Alert", "Controller Lost");
            pushHistory(state.lagHistory, { t: Date.now(), total: tLag, ped: f.fullLoopTime_ms, brg: f.metricLoopProcessMs+f.metricHttpProcessMs, dash: dLag });
            pushHistory(state.pedalHistory, { t: Date.now(), gasP: f.gas_physical_pct, clP: f.clutch_physical_pct });
            calcAverages();
        }

        function updateNonFrameMetrics(start) {
            state.display.lagD = performance.now() - start;
            state.frame.pedDashGetCount = state.getCounter;
            renderTelemetry();
        }

        /**
         * 8. RENDERING
         */
        function renderLoop() {
            const l = 0.2;
            state.display.gasP += (state.target.gasP - state.display.gasP) * l;
            state.display.gasL += (state.target.gasL - state.display.gasL) * l;
            state.display.clP += (state.target.clP - state.display.clP) * l;
            state.display.clL += (state.target.clL - state.display.clL) * l;
            state.display.lagT = state.target.lagT;
            state.display.lagP = state.target.lagP;
            state.display.lagB = state.target.lagB;
            state.display.lagD = state.target.lagD;

            renderUI();
            requestAnimationFrame(renderLoop);
        }

        function renderUI() {
            // Header
            if (state.isConnected) { 
                safeSetText(els.brandStatus, "Online"); 
                if (els.brandStatus) els.brandStatus.style.color = "var(--neon-green)";
            } else { 
                safeSetText(els.brandStatus, "Connecting..."); 
                if (els.brandStatus) els.brandStatus.style.color = "#777"; 
            }

            const disc = !state.isConnected || (state.frame.controller_disconnected === 1);
            if (els.discInd) els.discInd.classList.toggle('active', disc);

            safeSetText(els.hdrTotal, state.display.lagT.toFixed(0));
            safeSetText(els.hdrPed, state.display.lagP.toFixed(0));
            safeSetText(els.hdrBrg, state.display.lagB.toFixed(0));
            safeSetText(els.hdrDsh, state.display.lagD.toFixed(0));

            if (state.currentTab === 'tab-racing') renderRacing();
            else if (state.currentTab === 'tab-lag') renderLag();
            else if (state.currentTab === 'tab-signals') renderSignals();
            else if (state.currentTab === 'tab-telemetry') renderTelemetry();
        }

        function renderRacing() {
            drawDualGauge(ctxGas, "GAS", state.display.gasP, state.display.gasL);
            drawDualGauge(ctxClutch, "CLUTCH", state.display.clP, state.display.clL);
            safeSetText(els.lblGasPhys, state.display.gasP.toFixed(0) + "%");
            safeSetText(els.lblGasLog, state.display.gasL.toFixed(0) + "%");
            safeSetText(els.lblClutchPhys, state.display.clP.toFixed(0) + "%");
            safeSetText(els.lblClutchLog, state.display.clL.toFixed(0) + "%");
            const f = state.frame;
            toggleChip(els.stDrift, f.gas_alert_triggered, 'active-red');
            toggleChip(els.stNoise, f.clutch_alert_triggered, 'active-amber');
            toggleChip(els.stAuto, f.gas_auto_adjust_applied, 'active-blue');
            toggleChip(els.stRacing, f.isRacing, 'active-green');
        }

        function renderLag() {
            safeSetText(els.cardTotal, state.display.lagT.toFixed(0) + " ms");
            safeSetText(els.cardPed, state.display.lagP.toFixed(0) + " ms");
            safeSetText(els.cardBrg, state.display.lagB.toFixed(0) + " ms");
            safeSetText(els.cardDsh, state.display.lagD.toFixed(0) + " ms");
            safeSetText(els.avgTotal, `Avg: ${state.avgLagT.toFixed(1)}`);
            safeSetText(els.avgPed, `Avg: ${state.avgLagP.toFixed(1)}`);
            safeSetText(els.avgBrg, `Avg: ${state.avgLagB.toFixed(1)}`);
            safeSetText(els.avgDsh, `Avg: ${state.avgLagD.toFixed(1)}`);
            resizeCanvas(els.cvsLag);
            drawHistoryChart(ctxLag, state.lagHistory, ['total', 'brg', 'dash', 'ped'], ['#ff3333', '#39ff14', '#ff00ff', '#00f3ff'], 0, null, true);
        }

        function renderSignals() {
            resizeCanvas(els.cvsWaveGas); resizeCanvas(els.cvsWaveClutch);
            drawHistoryChart(ctxWaveGas, state.pedalHistory, ['gasP'], ['#00f3ff'], 0, 100, false);
            drawHistoryChart(ctxWaveClutch, state.pedalHistory, ['clP'], ['#39ff14'], 0, 100, false);
        }

        function renderTelemetry() {
            const f = state.frame;
            Object.keys(TELE_DEFS).forEach(k => {
                let val = f[k];
                if (typeof val === 'number') val = (val % 1 === 0) ? val : val.toFixed(1);
                if (val === undefined) val = "--";
                const el = document.getElementById(`tele-${k}`);
                if (el) { 
                    el.textContent = val; 
                    if (k === 'framesReceivedLastFetch') el.classList.toggle('warn-red', val !== 1 && val !== "--");
                }
            });
        }

        function initTelemetryUI() {
            const container = document.getElementById('tele-container');
            if(!container) return;
            container.innerHTML = '';
            TELE_GROUPS.forEach(group => {
                const groupDiv = document.createElement('div'); groupDiv.className = 'tele-group';
                const header = document.createElement('div'); header.className = 'tele-group-header'; header.textContent = group.title;
                groupDiv.appendChild(header);
                const gridDiv = document.createElement('div'); gridDiv.className = 'tele-grid-section';
                group.keys.forEach(key => {
                    const def = TELE_DEFS[key] || { label: key, short: key, long: "" };
                    const card = document.createElement('div'); card.className = 'tele-card';
                    card.innerHTML = `<h5>${def.label}</h5><div class="tele-val" id="tele-${key}">--</div>`;
                    card.onmouseenter = (e) => { 
                        const tip = document.getElementById('hover-tip'); 
                        tip.textContent = def.short; tip.classList.add('visible'); 
                        tip.style.left = (e.clientX + 15) + 'px'; tip.style.top = (e.clientY + 15) + 'px';
                    };
                    card.onmouseleave = () => document.getElementById('hover-tip').classList.remove('visible');
                    card.onclick = () => {
                        document.getElementById('modal-title').textContent = def.label;
                        document.getElementById('modal-desc').textContent = def.long;
                        document.getElementById('modal-overlay').classList.add('open');
                    };
                    gridDiv.appendChild(card);
                });
                groupDiv.appendChild(gridDiv);
                container.appendChild(groupDiv);
            });
        }

        function showHoverTip(e, txt) { 
            const t = document.getElementById('hover-tip'); 
            if(!t) return;
            t.textContent = txt; t.classList.add('visible'); 
            t.style.left = (e.clientX + 15) + 'px'; t.style.top = (e.clientY + 15) + 'px'; 
        }
        function hideHoverTip() { const t = document.getElementById('hover-tip'); if(t) t.classList.remove('visible'); }
        function closeModal() { document.getElementById('modal-overlay').classList.remove('open'); }

        /**
         * 9. INITIALIZATION
         */
        window.onload = function() {
            // SAFE MAP DOM
            els = {
                brandStatus: document.getElementById('session-status'),
                discInd: document.getElementById('disc-indicator'),
                ffwInd: document.getElementById('ffw-indicator'),
                hdrTotal: document.getElementById('hdr-total-lag'),
                hdrPed: document.getElementById('hdr-ped-lag'),
                hdrBrg: document.getElementById('hdr-brg-lag'),
                hdrDsh: document.getElementById('hdr-dsh-lag'),
                cvsGas: document.getElementById('canvas-gas'),
                cvsClutch: document.getElementById('canvas-clutch'),
                lblGasPhys: document.getElementById('lbl-gas-phys'),
                lblGasLog: document.getElementById('lbl-gas-log'),
                lblClutchPhys: document.getElementById('lbl-clutch-phys'),
                lblClutchLog: document.getElementById('lbl-clutch-log'),
                stDrift: document.getElementById('status-drift'),
                stNoise: document.getElementById('status-noise'),
                stAuto: document.getElementById('status-auto'),
                stRacing: document.getElementById('status-racing'),
                tickerList: document.getElementById('ticker-list'),
                cardTotal: document.getElementById('card-total-lag'),
                cardPed: document.getElementById('card-ped-lag'),
                cardBrg: document.getElementById('card-brg-lag'),
                cardDsh: document.getElementById('card-dsh-lag'),
                avgTotal: document.getElementById('avg-total-lag'),
                avgPed: document.getElementById('avg-ped-lag'),
                avgBrg: document.getElementById('avg-brg-lag'),
                avgDsh: document.getElementById('avg-dsh-lag'),
                cvsLag: document.getElementById('canvas-lag-chart'),
                cvsWaveGas: document.getElementById('canvas-wave-gas'),
                cvsWaveClutch: document.getElementById('canvas-wave-clutch'),
                fullEventList: document.getElementById('full-event-list')
            };

            const ctxG = els.cvsGas ? els.cvsGas.getContext('2d') : null;
            const ctxC = els.cvsClutch ? els.cvsClutch.getContext('2d') : null;
            const ctxL = els.cvsLag ? els.cvsLag.getContext('2d') : null;
            const ctxWG = els.cvsWaveGas ? els.cvsWaveGas.getContext('2d') : null;
            const ctxWC = els.cvsWaveClutch ? els.cvsWaveClutch.getContext('2d') : null;

            // Globals used by drawing functions
            window.ctxGas = ctxG; window.ctxClutch = ctxC; window.ctxLag = ctxL;
            window.ctxWaveGas = ctxWG; window.ctxWaveClutch = ctxWC;

            initTelemetryUI();
            logEvent("System", "Initializing Dashboard...");
            renderLoop();
            dataLoop();
        };
    </script>
</body>
</html>
```
