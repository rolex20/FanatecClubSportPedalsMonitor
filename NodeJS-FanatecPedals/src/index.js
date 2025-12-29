/*
 * Node.js port of FanatecPedals.ps1
 * - Single-threaded polling loop using WinMM joyGetPosEx via koffi FFI
 * - WebSocket telemetry with one frame per poll (no batching)
 * - Field names and semantics follow Fanatec.PedalMonState and PedDash expectations
 */
const http = require('http');
const { WebSocketServer } = require('ws');
const yargs = require('yargs/yargs');
const { hideBin } = require('yargs/helpers');
const koffi = require('koffi');

// ------------------------------
// Axis mapping constants (editable)
// ------------------------------
const GAS_AXIS = 'Y';
const CLUTCH_AXIS = 'R';
const BRAKE_AXIS = 'X';

const BACKPRESSURE_BYTES = 5 * 1024 * 1024; // drop frames per-client when exceeded
const WS_PORT = 8181;
const WS_PATH = '/ws';

// ------------------------------
// CLI parsing (PowerShell parity)
// ------------------------------
const argv = yargs(hideBin(process.argv))
  .option('SleepTime', { alias: 's', type: 'number', default: 1000 })
  .option('Margin', { alias: 'm', type: 'number', default: 5 })
  .option('ClutchRepeat', { alias: 'clutch-repeat', type: 'number', default: 4 })
  .option('NoAxisNormalization', { type: 'boolean', default: false })
  .option('GasDeadzoneIn', { alias: 'gas-deadzone-in', type: 'number', default: 5 })
  .option('GasDeadzoneOut', { alias: 'gas-deadzone-out', type: 'number', default: 93 })
  .option('GasWindow', { alias: 'gas-window', type: 'number', default: 30 })
  .option('GasCooldown', { alias: 'gas-cooldown', type: 'number', default: 60 })
  .option('GasTimeout', { alias: 'gas-timeout', type: 'number', default: 10 })
  .option('GasMinUsage', { alias: 'gas-min-usage', type: 'number', default: 20 })
  .option('EstimateGasDeadzone', { alias: 'estimate-gas-deadzone-out', type: 'boolean', default: false })
  .option('AutoGasDeadzoneMin', { alias: 'adjust-deadzone-out-with-minimum', type: 'number', default: -1 })
  .option('JoystickID', { alias: 'j', type: 'number', default: 17 })
  .option('VendorId', { alias: 'v', type: 'string' })
  .option('ProductId', { alias: 'p', type: 'string' })
  .option('MonitorClutch', { type: 'boolean', default: false })
  .option('MonitorGas', { type: 'boolean', default: false })
  .option('Telemetry', { type: 'boolean', default: true })
  .option('Tts', { type: 'boolean', default: true })
  .option('NoTts', { type: 'boolean', default: false })
  .option('NoConsoleBanner', { type: 'boolean', default: false })
  .option('DebugRaw', { type: 'boolean', default: false })
  .option('Iterations', { alias: 'i', type: 'number', default: 0 })
  .option('JoyFlags', { alias: ['f', 'flags'], type: 'number', default: 255 })
  .option('Verbose', { type: 'boolean', default: false })
  .option('Help', { type: 'boolean', default: false })
  .help(false)
  .argv;

if (argv.Help) {
  console.log('Usage: node src/index.js [options]\nSee FanatecPedals.ps1 parameters for compatible switches.');
  process.exit(0);
}

// ------------------------------
// WinMM bindings via koffi
// ------------------------------
let winmm = null;
let joyGetNumDevs = null;
let joyGetDevCapsA = null;
let joyGetPosEx = null;
let JOYINFOEX = null;
let JOYCAPS = null;
try {
  winmm = koffi.load('winmm.dll');
  JOYINFOEX = koffi.struct('JOYINFOEX', {
    dwSize: 'uint32',
    dwFlags: 'uint32',
    dwXpos: 'uint32',
    dwYpos: 'uint32',
    dwZpos: 'uint32',
    dwRpos: 'uint32',
    dwUpos: 'uint32',
    dwVpos: 'uint32',
    dwButtons: 'uint32',
    dwButtonNumber: 'uint32',
    dwPOV: 'uint32',
    dwReserved1: 'uint32',
    dwReserved2: 'uint32'
  });

  JOYCAPS = koffi.struct('JOYCAPS', {
    wMid: 'uint16',
    wPid: 'uint16',
    szPname: 'char[32]',
    wXmin: 'uint32',
    wXmax: 'uint32',
    wYmin: 'uint32',
    wYmax: 'uint32',
    wZmin: 'uint32',
    wZmax: 'uint32',
    wNumButtons: 'uint32',
    wPeriodMin: 'uint32',
    wPeriodMax: 'uint32',
    wRmin: 'uint32',
    wRmax: 'uint32',
    wUmin: 'uint32',
    wUmax: 'uint32',
    wVmin: 'uint32',
    wVmax: 'uint32',
    wCaps: 'uint32',
    wMaxAxes: 'uint32',
    wNumAxes: 'uint32',
    wMaxButtons: 'uint32',
    szRegKey: 'char[32]',
    szOEMVxD: 'char[260]'
  });

  joyGetNumDevs = winmm.func('MMRESULT __stdcall joyGetNumDevs(void)');
  joyGetDevCapsA = winmm.func('MMRESULT __stdcall joyGetDevCapsA(uintptr_t uJoyID, JOYCAPS* pjc, uint32_t cbjc)');
  joyGetPosEx = winmm.func('MMRESULT __stdcall joyGetPosEx(uint32_t uJoyID, JOYINFOEX* pji)');
} catch (err) {
  console.error('Failed to load winmm.dll via koffi. This app must run on Windows with WinMM available.', err);
  process.exit(1);
}

// ------------------------------
// Utility helpers
// ------------------------------
const axisGetters = createAxisGetters();

function createAxisGetters() {
  const map = {
    X: (info) => info.dwXpos >>> 0,
    Y: (info) => info.dwYpos >>> 0,
    Z: (info) => info.dwZpos >>> 0,
    R: (info) => info.dwRpos >>> 0,
    U: (info) => info.dwUpos >>> 0,
    V: (info) => info.dwVpos >>> 0
  };
  return map;
}

function tick32() {
  return (Math.trunc(process.uptime() * 1000)) >>> 0;
}

function toHexInt(str) {
  if (!str) return 0;
  const parsed = parseInt(str, 16);
  return Number.isFinite(parsed) ? parsed : 0;
}

// ------------------------------
// Initial configuration
// ------------------------------
const targetVendorId = toHexInt(argv.VendorId);
const targetProductId = toHexInt(argv.ProductId);
const axisNormalizationEnabled = argv.NoAxisNormalization ? 0 : 1;
const ttsEnabledFlag = argv.NoTts ? 0 : (argv.Tts ? 1 : 0);
const telemetryEnabledFlag = argv.Telemetry ? 1 : 0;
const monitorClutchFlag = argv.MonitorClutch ? 1 : 0;
const monitorGasFlag = argv.MonitorGas ? 1 : 0;
const verboseFlag = argv.Verbose ? 1 : 0;
const debugRawFlag = argv.DebugRaw ? 1 : 0;
const noConsoleBannerFlag = argv.NoConsoleBanner ? 1 : 0;
const estimateGasDeadzoneFlag = argv.EstimateGasDeadzone ? 1 : 0;
const autoGasDeadzoneEnabled = argv.AutoGasDeadzoneMin >= 0 ? 1 : 0;

const axisMax = (argv.JoyFlags & 256) !== 0 ? 1023 >>> 0 : 65535 >>> 0;
const axisMargin = Math.trunc(axisMax * argv.Margin / 100) >>> 0;

let gasDeadzoneIn = argv.GasDeadzoneIn;
let gasDeadzoneOut = argv.GasDeadzoneOut;
let gasIdleMax = Math.trunc(axisMax * gasDeadzoneIn / 100) >>> 0;
let gasFullMin = Math.trunc(axisMax * gasDeadzoneOut / 100) >>> 0;
let clutchDeadzoneIn = argv.ClutchDeadzoneIn || argv.GasDeadzoneIn;
let clutchDeadzoneOut = argv.ClutchDeadzoneOut || argv.GasDeadzoneOut;
let clutchIdleMax = Math.trunc(axisMax * clutchDeadzoneIn / 100) >>> 0;
let clutchFullMin = Math.trunc(axisMax * clutchDeadzoneOut / 100) >>> 0;
let brakeDeadzoneIn = argv.BrakeDeadzoneIn || argv.GasDeadzoneIn;
let brakeDeadzoneOut = argv.BrakeDeadzoneOut || argv.GasDeadzoneOut;
let brakeIdleMax = Math.trunc(axisMax * brakeDeadzoneIn / 100) >>> 0;
let brakeFullMin = Math.trunc(axisMax * brakeDeadzoneOut / 100) >>> 0;

const gasTimeoutMs = Math.trunc(argv.GasTimeout * 1000) >>> 0;
const gasWindowMs = Math.trunc(argv.GasWindow * 1000) >>> 0;
const gasCooldownMs = Math.trunc(argv.GasCooldown * 1000) >>> 0;

// Runtime variables
let joyId = argv.JoystickID >>> 0;
let controllerDisconnected = 0;
let lastDisconnectTimeMs = 0;
let lastReconnectTimeMs = 0;
let lastFullThrottleTime = 0;
let lastGasActivityTime = 0;
let peakGasInWindow = 0;
let lastGasAlertTime = 0;
let repeatingClutchCount = 0;
let lastClutchValue = 0;
let isRacing = 0;
let percentReached = 0;
let currentPercent = 0;
let bestEstimatePercent = 100;
let lastPrintedEstimate = 100;
let estimateWindowPeakPercent = 0;
let estimateWindowStartTime = 0;
let lastEstimatePrintTime = 0;
let lastLoopStart = tick32();
let fullLoopTimeMs = 0;
let telemetrySequence = 0 >>> 0;
let iLoop = 0 >>> 0;
let producerNotifyMs = 0;
let producerLoopStartMs = 0;
let currentDelay = argv.SleepTime;

let gasAlertTriggered = 0;
let clutchAlertTriggered = 0;
let gasEstimateDecreased = 0;
let gasAutoAdjustApplied = 0;
let controllerReconnected = 0;

// TTS stub (non-overlapping)
let ttsBusy = false;
let lastTtsDuration = 0;
function speak(text) {
  if (!ttsEnabledFlag) return;
  if (ttsBusy) return;
  ttsBusy = true;
  const start = performance.now();
  // Placeholder: integrate real TTS library on Windows if desired
  console.log(`[TTS] ${text}`);
  setTimeout(() => {
    lastTtsDuration = performance.now() - start;
    ttsBusy = false;
  }, 0);
}

// ------------------------------
// Stable telemetry frame template (monomorphic shape)
// ------------------------------
const frame = {
  verbose_flag: verboseFlag,
  monitor_clutch: monitorClutchFlag,
  monitor_gas: monitorGasFlag,
  gas_deadzone_in: gasDeadzoneIn,
  gas_deadzone_out: gasDeadzoneOut,
  gas_window: argv.GasWindow,
  gas_cooldown: argv.GasCooldown,
  gas_timeout: argv.GasTimeout,
  gas_min_usage_percent: argv.GasMinUsage,
  axis_normalization_enabled: axisNormalizationEnabled,
  debug_raw_mode: debugRawFlag,
  clutch_repeat_required: argv.ClutchRepeat,
  estimate_gas_deadzone_enabled: estimateGasDeadzoneFlag,
  auto_gas_deadzone_enabled: autoGasDeadzoneEnabled,
  auto_gas_deadzone_minimum: argv.AutoGasDeadzoneMin,
  target_vendor_id: targetVendorId,
  target_product_id: targetProductId,
  telemetry_enabled: telemetryEnabledFlag,
  tts_enabled: ttsEnabledFlag,
  ipc_enabled: 0,
  no_console_banner: noConsoleBannerFlag,
  gas_physical_pct: 0,
  clutch_physical_pct: 0,
  brake_physical_pct: 0,
  gas_logical_pct: 0,
  clutch_logical_pct: 0,
  brake_logical_pct: 0,
  joy_ID: joyId,
  joy_Flags: argv.JoyFlags >>> 0,
  iterations: argv.Iterations >>> 0,
  margin: argv.Margin >>> 0,
  sleep_Time: argv.SleepTime >>> 0,
  axisMax: axisMax,
  axisMargin: axisMargin,
  lastClutchValue: lastClutchValue,
  repeatingClutchCount: repeatingClutchCount,
  isRacing: isRacing,
  peakGasInWindow: peakGasInWindow,
  lastFullThrottleTime: lastFullThrottleTime,
  lastGasActivityTime: lastGasActivityTime,
  lastGasAlertTime: lastGasAlertTime,
  gasIdleMax: gasIdleMax,
  gasFullMin: gasFullMin,
  gas_timeout_ms: gasTimeoutMs,
  gas_window_ms: gasWindowMs,
  gas_cooldown_ms: gasCooldownMs,
  best_estimate_percent: bestEstimatePercent,
  last_printed_estimate: lastPrintedEstimate,
  estimate_window_peak_percent: estimateWindowPeakPercent,
  estimate_window_start_time: estimateWindowStartTime,
  last_estimate_print_time: lastEstimatePrintTime,
  currentTime: tick32(),
  rawGas: 0,
  rawClutch: 0,
  rawBrake: 0,
  gasValue: 0,
  clutchValue: 0,
  brakeValue: 0,
  closure: 0,
  percentReached: 0,
  currentPercent: 0,
  iLoop: iLoop,
  producer_loop_start_ms: producerLoopStartMs,
  producer_notify_ms: producerNotifyMs,
  fullLoopTime_ms: fullLoopTimeMs,
  telemetry_sequence: telemetrySequence,
  receivedAtUnixMs: 0,
  metricHttpProcessMs: 0,
  metricTtsSpeakMs: 0,
  metricLoopProcessMs: 0,
  gas_alert_triggered: 0,
  clutch_alert_triggered: 0,
  controller_disconnected: controllerDisconnected,
  controller_reconnected: controllerReconnected,
  gas_estimate_decreased: 0,
  gas_auto_adjust_applied: 0,
  last_disconnect_time_ms: lastDisconnectTimeMs,
  last_reconnect_time_ms: lastReconnectTimeMs
};

// ------------------------------
// Device detection helpers
// ------------------------------
function findDeviceByVidPid(vid, pid) {
  const max = joyGetNumDevs();
  for (let i = 0; i < max; i += 1) {
    const caps = new JOYCAPS();
    const res = joyGetDevCapsA(i, caps, JOYCAPS.sizeof);
    if (res !== 0) continue;
    const mid = caps.wMid >>> 0;
    const pidVal = caps.wPid >>> 0;
    if (mid === vid && pidVal === pid) {
      return i;
    }
  }
  return -1;
}

function refreshAxisDerived() {
  gasIdleMax = Math.trunc(axisMax * gasDeadzoneIn / 100) >>> 0;
  gasFullMin = Math.trunc(axisMax * gasDeadzoneOut / 100) >>> 0;
  clutchIdleMax = Math.trunc(axisMax * clutchDeadzoneIn / 100) >>> 0;
  clutchFullMin = Math.trunc(axisMax * clutchDeadzoneOut / 100) >>> 0;
  brakeIdleMax = Math.trunc(axisMax * brakeDeadzoneIn / 100) >>> 0;
  brakeFullMin = Math.trunc(axisMax * brakeDeadzoneOut / 100) >>> 0;
  frame.gas_deadzone_out = gasDeadzoneOut;
  frame.gasIdleMax = gasIdleMax;
  frame.gasFullMin = gasFullMin;
}

// ------------------------------
// Networking (HTTP + WebSocket)
// ------------------------------
const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/QUIT') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Shutting down');
    shutdown();
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, path: WS_PATH });
wss.on('connection', (ws) => {
  ws.on('error', () => {});
});

server.listen(WS_PORT, 'localhost', () => {
  if (!noConsoleBannerFlag) {
    console.log(`Fanatec pedals WS telemetry on ws://localhost:${WS_PORT}${WS_PATH}`);
  }
});

process.on('SIGINT', () => {
  shutdown();
});

function shutdown() {
  running = false;
  try { wss.close(); } catch (e) { /* noop */ }
  try { server.close(); } catch (e) { /* noop */ }
  process.exit(0);
}

let running = true;

// ------------------------------
// Polling loop
// ------------------------------
function pollLoop() {
  if (!running) return;
  const loopStart = tick32();
  producerLoopStartMs = loopStart;
  frame.producer_loop_start_ms = producerLoopStartMs;
  const hrStart = performance.now();

  gasAlertTriggered = 0;
  clutchAlertTriggered = 0;
  gasEstimateDecreased = 0;
  gasAutoAdjustApplied = 0;
  controllerReconnected = 0;
  percentReached = 0;
  currentPercent = 0;
  frame.gas_alert_triggered = 0;
  frame.clutch_alert_triggered = 0;
  frame.gas_estimate_decreased = 0;
  frame.gas_auto_adjust_applied = 0;
  frame.controller_reconnected = 0;

  let delayNext = currentDelay;
  const info = new JOYINFOEX();
  info.dwSize = JOYINFOEX.sizeof >>> 0;
  info.dwFlags = argv.JoyFlags >>> 0;

  let connectedThisLoop = true;
  const joyRes = joyGetPosEx(joyId, info);
  if (joyRes !== 0) {
    connectedThisLoop = false;
    if (controllerDisconnected === 0 && targetVendorId && targetProductId) {
      controllerDisconnected = 1;
      lastDisconnectTimeMs = tick32();
      frame.controller_disconnected = controllerDisconnected;
      frame.last_disconnect_time_ms = lastDisconnectTimeMs;
      speak('Controller disconnected. Waiting...');
      publishFrame(Date.now());
    }

    if (targetVendorId && targetProductId) {
      delayNext = 60000; // rescan cadence
      const found = findDeviceByVidPid(targetVendorId, targetProductId);
      if (found !== -1) {
        joyId = found >>> 0;
        controllerDisconnected = 0;
        controllerReconnected = 1;
        lastReconnectTimeMs = tick32();
        frame.controller_disconnected = controllerDisconnected;
        frame.controller_reconnected = controllerReconnected;
        frame.last_reconnect_time_ms = lastReconnectTimeMs;
        resetGasRuntime();
        publishFrame(Date.now());
        delayNext = argv.SleepTime;
      }
    } else {
      delayNext = 1000;
    }
  }

  if (connectedThisLoop) {
    controllerDisconnected = 0;
    frame.controller_disconnected = 0;

    // Raw values
    const rawGas = axisGetters[GAS_AXIS](info);
    const rawClutch = axisGetters[CLUTCH_AXIS](info);
    const rawBrake = axisGetters[BRAKE_AXIS](info);

    // Normalization
    const gasValue = axisNormalizationEnabled ? (axisMax - rawGas) >>> 0 : rawGas >>> 0;
    const clutchValue = axisNormalizationEnabled ? (axisMax - rawClutch) >>> 0 : rawClutch >>> 0;
    const brakeValue = axisNormalizationEnabled ? (axisMax - rawBrake) >>> 0 : rawBrake >>> 0;

    const gasPhysicalPct = Math.trunc(100 * gasValue / axisMax) >>> 0;
    const clutchPhysicalPct = Math.trunc(100 * clutchValue / axisMax) >>> 0;
    const brakePhysicalPct = Math.trunc(100 * brakeValue / axisMax) >>> 0;

    const gasLogicalPct = computeLogicalPct(gasValue);
    const clutchLogicalPct = computeLogicalPct(clutchValue);
    const brakeLogicalPct = computeLogicalPct(brakeValue);

    frame.rawGas = rawGas >>> 0;
    frame.rawClutch = rawClutch >>> 0;
    frame.rawBrake = rawBrake >>> 0;
    frame.gasValue = gasValue;
    frame.clutchValue = clutchValue;
    frame.brakeValue = brakeValue;
    frame.gas_physical_pct = gasPhysicalPct;
    frame.clutch_physical_pct = clutchPhysicalPct;
    frame.brake_physical_pct = brakePhysicalPct;
    frame.gas_logical_pct = gasLogicalPct;
    frame.clutch_logical_pct = clutchLogicalPct;
    frame.brake_logical_pct = brakeLogicalPct;

    // Clutch monitoring
    if (monitorClutchFlag && gasValue <= gasIdleMax && clutchValue > 0) {
      const diff = Math.abs(clutchValue - lastClutchValue);
      frame.closure = diff;
      if (diff <= axisMargin) {
        repeatingClutchCount += 1;
      } else {
        repeatingClutchCount = 0;
      }
    } else {
      repeatingClutchCount = 0;
      frame.closure = 0;
    }
    if (repeatingClutchCount >= argv.ClutchRepeat) {
      clutchAlertTriggered = 1;
      repeatingClutchCount = 0;
      speak('Rudder.');
    }
    lastClutchValue = clutchValue;

    // Gas monitoring
    const nowTick = tick32();
    if (monitorGasFlag) {
      if (gasValue > gasIdleMax) {
        if (isRacing === 0) {
          lastFullThrottleTime = nowTick;
          peakGasInWindow = 0;
          if (estimateGasDeadzoneFlag) {
            estimateWindowStartTime = nowTick;
            estimateWindowPeakPercent = 0;
          }
          isRacing = 1;
        }
        lastGasActivityTime = nowTick;
      } else if (isRacing === 1 && ((nowTick - lastGasActivityTime) >>> 0) > gasTimeoutMs) {
        isRacing = 0;
      }

      if (isRacing === 1) {
        if (gasValue > peakGasInWindow) peakGasInWindow = gasValue;
        if (gasValue >= gasFullMin) {
          lastFullThrottleTime = nowTick;
          peakGasInWindow = 0;
        } else if (((nowTick - lastFullThrottleTime) >>> 0) > gasWindowMs) {
          if (((nowTick - lastGasAlertTime) >>> 0) > gasCooldownMs) {
            percentReached = Math.trunc(peakGasInWindow * 100 / axisMax) >>> 0;
            if (percentReached > argv.GasMinUsage) {
              gasAlertTriggered = 1;
              lastGasAlertTime = nowTick;
              speak(`Gas ${percentReached} percent.`);
            }
          }
        }
      }
    }

    // Deadzone estimator
    if (monitorGasFlag && estimateGasDeadzoneFlag) {
      if (gasValue > gasIdleMax) {
        currentPercent = Math.trunc(gasValue * 100 / axisMax) >>> 0;
        if (currentPercent > estimateWindowPeakPercent) estimateWindowPeakPercent = currentPercent;
      }
      if (((nowTick - estimateWindowStartTime) >>> 0) >= gasCooldownMs) {
        if (estimateWindowPeakPercent >= argv.GasMinUsage) {
          if (estimateWindowPeakPercent < bestEstimatePercent) {
            bestEstimatePercent = estimateWindowPeakPercent;
            gasEstimateDecreased = 1;
            const timeSincePrint = (nowTick - lastEstimatePrintTime) >>> 0;
            if (timeSincePrint >= gasCooldownMs) {
              lastEstimatePrintTime = nowTick;
              lastPrintedEstimate = bestEstimatePercent;
              speak(`New deadzone estimation ${bestEstimatePercent} percent.`);
            }
            if (autoGasDeadzoneEnabled && bestEstimatePercent < gasDeadzoneOut && bestEstimatePercent >= argv.AutoGasDeadzoneMin) {
              gasDeadzoneOut = bestEstimatePercent;
              gasAutoAdjustApplied = 1;
              speak(`Auto adjusted deadzone to ${gasDeadzoneOut} percent.`);
              refreshAxisDerived();
            }
          }
        }
        estimateWindowStartTime = nowTick;
        estimateWindowPeakPercent = 0;
      }
    }
  }

  // copy runtime state into frame
  frame.verbose_flag = verboseFlag;
  frame.monitor_clutch = monitorClutchFlag;
  frame.monitor_gas = monitorGasFlag;
  frame.gas_deadzone_in = gasDeadzoneIn;
  frame.gas_deadzone_out = gasDeadzoneOut;
  frame.gas_window = argv.GasWindow;
  frame.gas_cooldown = argv.GasCooldown;
  frame.gas_timeout = argv.GasTimeout;
  frame.gas_min_usage_percent = argv.GasMinUsage;
  frame.axis_normalization_enabled = axisNormalizationEnabled;
  frame.debug_raw_mode = debugRawFlag;
  frame.clutch_repeat_required = argv.ClutchRepeat;
  frame.estimate_gas_deadzone_enabled = estimateGasDeadzoneFlag;
  frame.auto_gas_deadzone_enabled = autoGasDeadzoneEnabled;
  frame.auto_gas_deadzone_minimum = argv.AutoGasDeadzoneMin;
  frame.target_vendor_id = targetVendorId;
  frame.target_product_id = targetProductId;
  frame.telemetry_enabled = telemetryEnabledFlag;
  frame.tts_enabled = ttsEnabledFlag;
  frame.no_console_banner = noConsoleBannerFlag;
  frame.joy_ID = joyId;
  frame.iterations = argv.Iterations >>> 0;
  frame.margin = argv.Margin >>> 0;
  frame.sleep_Time = argv.SleepTime >>> 0;
  frame.axisMax = axisMax;
  frame.axisMargin = axisMargin;
  frame.lastClutchValue = lastClutchValue;
  frame.repeatingClutchCount = repeatingClutchCount;
  frame.isRacing = isRacing;
  frame.peakGasInWindow = peakGasInWindow;
  frame.lastFullThrottleTime = lastFullThrottleTime;
  frame.lastGasActivityTime = lastGasActivityTime;
  frame.lastGasAlertTime = lastGasAlertTime;
  frame.gasIdleMax = gasIdleMax;
  frame.gasFullMin = gasFullMin;
  frame.gas_timeout_ms = gasTimeoutMs;
  frame.gas_window_ms = gasWindowMs;
  frame.gas_cooldown_ms = gasCooldownMs;
  frame.best_estimate_percent = bestEstimatePercent;
  frame.last_printed_estimate = lastPrintedEstimate;
  frame.estimate_window_peak_percent = estimateWindowPeakPercent;
  frame.estimate_window_start_time = estimateWindowStartTime;
  frame.last_estimate_print_time = lastEstimatePrintTime;
  frame.percentReached = percentReached >>> 0;
  frame.currentPercent = currentPercent >>> 0;
  frame.telemetry_sequence = telemetrySequence = (telemetrySequence + 1) >>> 0;
  frame.receivedAtUnixMs = 0;
  frame.metricTtsSpeakMs = lastTtsDuration;
  frame.gas_alert_triggered = gasAlertTriggered;
  frame.clutch_alert_triggered = clutchAlertTriggered;
  frame.controller_disconnected = controllerDisconnected;
  frame.controller_reconnected = controllerReconnected;
  frame.gas_estimate_decreased = gasEstimateDecreased;
  frame.gas_auto_adjust_applied = gasAutoAdjustApplied;
  frame.last_disconnect_time_ms = lastDisconnectTimeMs;
  frame.last_reconnect_time_ms = lastReconnectTimeMs;
  frame.iLoop = iLoop;
  frame.currentTime = tick32();
  frame.producer_notify_ms = producerNotifyMs = tick32();
  frame.fullLoopTime_ms = fullLoopTimeMs;

  const loopProcessDuration = performance.now() - hrStart;
  frame.metricLoopProcessMs = loopProcessDuration;

  if (wss.clients.size > 0 && telemetryEnabledFlag) {
    const httpStart = performance.now();
    frame.receivedAtUnixMs = Date.now();
    const payload = JSON.stringify(frame);
    let sent = false;
    wss.clients.forEach((ws) => {
      if (ws.readyState !== ws.OPEN) return;
      if (ws.bufferedAmount > BACKPRESSURE_BYTES) return;
      ws.send(payload);
      sent = true;
    });
    frame.metricHttpProcessMs = performance.now() - httpStart;
    if (!sent) frame.receivedAtUnixMs = 0;
  } else {
    frame.metricHttpProcessMs = 0;
  }

  const loopEndTick = tick32();
  fullLoopTimeMs = (loopEndTick - lastLoopStart) >>> 0;
  lastLoopStart = loopStart;

  iLoop = (iLoop + 1) >>> 0;
  frame.iLoop = iLoop;

  const shouldContinue = argv.Iterations === 0 || iLoop < argv.Iterations;
  if (shouldContinue) {
    currentDelay = delayNext;
    setTimeout(pollLoop, delayNext);
  } else {
    shutdown();
  }
}

function computeLogicalPct(value) {
  if (value <= gasIdleMax) return 0;
  if (value >= gasFullMin) return 100;
  if (gasFullMin <= gasIdleMax) return 0;
  const delta = gasFullMin - gasIdleMax;
  return Math.trunc((value - gasIdleMax) * 100 / delta) >>> 0;
}

function resetGasRuntime() {
  isRacing = 0;
  peakGasInWindow = 0;
  lastGasAlertTime = 0;
  lastFullThrottleTime = 0;
  lastGasActivityTime = 0;
  estimateWindowStartTime = tick32();
  estimateWindowPeakPercent = 0;
}

// Startup auto-detect
if (joyId >= 16 && targetVendorId && targetProductId) {
  const found = findDeviceByVidPid(targetVendorId, targetProductId);
  if (found !== -1) {
    joyId = found >>> 0;
  } else {
    console.error(`Device Vendor-Id=${argv.VendorId}, ProductId=${argv.ProductId} not found at startup.`);
    process.exit(1);
  }
}

// Start loop
setTimeout(pollLoop, currentDelay);
