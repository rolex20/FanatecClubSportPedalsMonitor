const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');
const { performance } = require('perf_hooks');
const EventEmitter = require('events');
const { pollJoystick, constants } = require('../ffi/joy');
const { Logger } = require('../util/logger');

function createFrameTemplate(axisMax) {
  // Stable object shape for TurboFan; properties match Fanatec.PedalMonState
  return {
    verbose_flag: 0,
    monitor_clutch: 0,
    monitor_gas: 0,
    gas_deadzone_in: 0,
    gas_deadzone_out: 0,
    brake_deadzone_in: 0,
    brake_deadzone_out: 0,
    clutch_deadzone_in: 0,
    clutch_deadzone_out: 0,
    gas_window: 0,
    gas_cooldown: 0,
    gas_timeout: 0,
    gas_min_usage_percent: 0,
    axis_normalization_enabled: 1,
    debug_raw_mode: 0,
    clutch_repeat_required: 0,
    estimate_gas_deadzone_enabled: 0,
    auto_gas_deadzone_enabled: 0,
    auto_gas_deadzone_minimum: -1,
    target_vendor_id: 0,
    target_product_id: 0,
    telemetry_enabled: 1,
    tts_enabled: 1,
    ipc_enabled: 0,
    no_console_banner: 0,

    gas_physical_pct: 0,
    clutch_physical_pct: 0,
    brake_physical_pct: 0,
    gas_logical_pct: 0,
    clutch_logical_pct: 0,
    brake_logical_pct: 0,

    joy_ID: 0,
    joy_Flags: constants.JOY_RETURNALL,
    iterations: 0,
    margin: 0,
    sleep_Time: 0,
    axisMax,
    axisMargin: 0,
    lastClutchValue: 0,
    repeatingClutchCount: 0,
    isRacing: 0,
    peakGasInWindow: 0,
    lastFullThrottleTime: 0,
    lastGasActivityTime: 0,
    lastGasAlertTime: 0,
    gasIdleMax: 0,
    gasFullMin: 0,
    brakeIdleMax: 0,
    brakeFullMin: 0,
    clutchIdleMax: 0,
    clutchFullMin: 0,
    gas_timeout_ms: 0,
    gas_window_ms: 0,
    gas_cooldown_ms: 0,

    best_estimate_percent: 100,
    last_printed_estimate: 100,
    estimate_window_peak_percent: 0,
    estimate_window_start_time: 0,
    last_estimate_print_time: 0,

    currentTime: 0,
    rawGas: 0,
    rawClutch: 0,
    rawBrake: 0,
    gasValue: 0,
    clutchValue: 0,
    brakeValue: 0,
    closure: 0,
    percentReached: 0,
    currentPercent: 0,
    iLoop: 0,

    producer_loop_start_ms: 0,
    producer_notify_ms: 0,
    fullLoopTime_ms: 0,
    telemetry_sequence: 0,

    receivedAtUnixMs: 0,
    metricHttpProcessMs: 0,
    metricTtsSpeakMs: 0,
    metricLoopProcessMs: 0,

    gas_alert_triggered: 0,
    clutch_alert_triggered: 0,
    controller_disconnected: 0,
    controller_reconnected: 0,
    gas_estimate_decreased: 0,
    gas_auto_adjust_applied: 0,

    last_disconnect_time_ms: 0,
    last_reconnect_time_ms: 0
  };
}

function updatePercentages(frame) {
  // Hot path: stable numeric operations for V8
  const gasRange = frame.gasFullMin > frame.gasIdleMax ? (frame.gasFullMin - frame.gasIdleMax) : 0;
  const clutchRange = frame.clutchFullMin > frame.clutchIdleMax ? (frame.clutchFullMin - frame.clutchIdleMax) : 0;
  const brakeRange = frame.brakeFullMin > frame.brakeIdleMax ? (frame.brakeFullMin - frame.brakeIdleMax) : 0;

  if (frame.axisMax > 0) {
    frame.gas_physical_pct = (100 * frame.gasValue / frame.axisMax) >>> 0;
    frame.clutch_physical_pct = (100 * frame.clutchValue / frame.axisMax) >>> 0;
    frame.brake_physical_pct = (100 * frame.brakeValue / frame.axisMax) >>> 0;
  } else {
    frame.gas_physical_pct = 0;
    frame.clutch_physical_pct = 0;
    frame.brake_physical_pct = 0;
  }

  if (gasRange === 0 || frame.gasValue <= frame.gasIdleMax) {
    frame.gas_logical_pct = 0;
  } else if (frame.gasValue >= frame.gasFullMin) {
    frame.gas_logical_pct = 100;
  } else {
    frame.gas_logical_pct = (100 * (frame.gasValue - frame.gasIdleMax) / gasRange) >>> 0;
  }

  if (clutchRange === 0 || frame.clutchValue <= frame.clutchIdleMax) {
    frame.clutch_logical_pct = 0;
  } else if (frame.clutchValue >= frame.clutchFullMin) {
    frame.clutch_logical_pct = 100;
  } else {
    frame.clutch_logical_pct = (100 * (frame.clutchValue - frame.clutchIdleMax) / clutchRange) >>> 0;
  }

  if (brakeRange === 0 || frame.brakeValue <= frame.brakeIdleMax) {
    frame.brake_logical_pct = 0;
  } else if (frame.brakeValue >= frame.brakeFullMin) {
    frame.brake_logical_pct = 100;
  } else {
    frame.brake_logical_pct = (100 * (frame.brakeValue - frame.brakeIdleMax) / brakeRange) >>> 0;
  }
}

function normalizeAxis(raw, axisMax, normalize) {
  if (!normalize) return raw >>> 0;
  // Fanatec pedals invert gas by default; align with PS behavior
  return (axisMax - raw) >>> 0;
}

function buildFrame(config, state) {
  const axisMax = state.axisMax;
  const frame = { ...state.template };
  frame.verbose_flag = config.verbose ? 1 : 0;
  frame.monitor_clutch = config.monitorClutch ? 1 : 0;
  frame.monitor_gas = config.monitorGas ? 1 : 0;
  frame.gas_deadzone_in = config.gasDeadzoneIn;
  frame.gas_deadzone_out = config.gasDeadzoneOut;
  frame.brake_deadzone_in = config.brakeDeadzoneIn;
  frame.brake_deadzone_out = config.brakeDeadzoneOut;
  frame.clutch_deadzone_in = config.clutchDeadzoneIn;
  frame.clutch_deadzone_out = config.clutchDeadzoneOut;
  frame.gas_window = config.gasWindow;
  frame.gas_cooldown = config.gasCooldown;
  frame.gas_timeout = config.gasTimeout;
  frame.gas_min_usage_percent = config.gasMinUsage;
  frame.axis_normalization_enabled = config.axisNormalization ? 1 : 0;
  frame.debug_raw_mode = config.debugRaw ? 1 : 0;
  frame.clutch_repeat_required = config.clutchRepeat;
  frame.estimate_gas_deadzone_enabled = config.estimateGasDeadzone ? 1 : 0;
  frame.auto_gas_deadzone_enabled = config.autoGasDeadzoneMin > -1 ? 1 : 0;
  frame.auto_gas_deadzone_minimum = config.autoGasDeadzoneMin;
  frame.telemetry_enabled = config.telemetry ? 1 : 0;
  frame.tts_enabled = config.noTts ? 0 : (config.tts ? 1 : 0);
  frame.no_console_banner = config.noConsoleBanner ? 1 : 0;
  frame.target_vendor_id = config.vendorId ? parseInt(config.vendorId, 16) || 0 : 0;
  frame.target_product_id = config.productId ? parseInt(config.productId, 16) || 0 : 0;
  frame.joy_ID = config.joystickId >>> 0;
  frame.joy_Flags = config.joyFlags >>> 0;
  frame.iterations = config.iterations >>> 0;
  frame.margin = config.margin >>> 0;
  frame.sleep_Time = config.pollIntervalMs >>> 0;
  frame.axisMax = axisMax >>> 0;
  frame.axisMargin = ((axisMax * config.margin) / 100) >>> 0;
  frame.gasIdleMax = ((axisMax * config.gasDeadzoneIn) / 100) >>> 0;
  frame.gasFullMin = ((axisMax * config.gasDeadzoneOut) / 100) >>> 0;
  frame.brakeIdleMax = ((axisMax * config.brakeDeadzoneIn) / 100) >>> 0;
  frame.brakeFullMin = ((axisMax * config.brakeDeadzoneOut) / 100) >>> 0;
  frame.clutchIdleMax = ((axisMax * config.clutchDeadzoneIn) / 100) >>> 0;
  frame.clutchFullMin = ((axisMax * config.clutchDeadzoneOut) / 100) >>> 0;
  frame.gas_timeout_ms = (config.gasTimeout * 1000) >>> 0;
  frame.gas_window_ms = (config.gasWindow * 1000) >>> 0;
  frame.gas_cooldown_ms = (config.gasCooldown * 1000) >>> 0;
  frame.best_estimate_percent = 100;
  frame.last_printed_estimate = 100;
  frame.estimate_window_peak_percent = 0;
  frame.estimate_window_start_time = 0;
  frame.last_estimate_print_time = 0;
  return frame;
}

function telemetryWorkerMain() {
  const { config } = workerData;
  const logger = new Logger(config.verbose);
  const axisMax = (config.joyFlags & constants.JOY_RETURNRAWDATA) ? 1023 : 65535;
  const state = {
    axisMax,
    template: createFrameTemplate(axisMax),
    lastFullThrottleTime: performance.now(),
    lastGasActivityTime: performance.now(),
    lastGasAlertTime: 0,
    lastClutch: 0,
    repeating: 0,
    seq: 0,
    prevLoopMs: 0,
    controllerDisconnected: false
  };

  const frameBase = buildFrame(config, state);

  const poll = () => {
    const loopStart = performance.now();
    const tickStart = Date.now();
    const frame = { ...frameBase };
    frame.producer_loop_start_ms = tickStart >>> 0;
    frame.fullLoopTime_ms = state.prevLoopMs >>> 0;
    frame.gas_alert_triggered = 0;
    frame.clutch_alert_triggered = 0;
    frame.gas_estimate_decreased = 0;
    frame.gas_auto_adjust_applied = 0;
    frame.controller_reconnected = 0;
    frame.telemetry_sequence = (++state.seq) >>> 0;

    let res;
    try {
      res = pollJoystick(config.joystickId >>> 0, config.joyFlags >>> 0);
    } catch (err) {
      frame.controller_disconnected = 1;
      frame.last_disconnect_time_ms = tickStart >>> 0;
      parentPort.postMessage({ type: 'frame', frame });
      state.prevLoopMs = performance.now() - loopStart;
      return schedule();
    }

    const info = res.info;
    const joyResult = res.result;
    if (joyResult !== 0) {
      if (!state.controllerDisconnected) {
        frame.controller_disconnected = 1;
        frame.last_disconnect_time_ms = tickStart >>> 0;
        state.controllerDisconnected = true;
        parentPort.postMessage({ type: 'frame', frame });
      }
      state.prevLoopMs = performance.now() - loopStart;
      return schedule();
    }

    if (state.controllerDisconnected) {
      frame.controller_reconnected = 1;
      frame.controller_disconnected = 0;
      frame.last_reconnect_time_ms = tickStart >>> 0;
      state.controllerDisconnected = false;
    }

    frame.rawBrake = info.dwXpos >>> 0;
    frame.rawGas = info.dwYpos >>> 0;
    frame.rawClutch = info.dwRpos >>> 0;

    frame.brakeValue = normalizeAxis(frame.rawBrake, state.axisMax, config.axisNormalization);
    frame.gasValue = normalizeAxis(frame.rawGas, state.axisMax, config.axisNormalization);
    frame.clutchValue = normalizeAxis(frame.rawClutch, state.axisMax, config.axisNormalization);

    updatePercentages(frame);
    frame.currentPercent = frame.gas_logical_pct;

    // Gas drift detection
    const now = performance.now();
    if (frame.gas_logical_pct > config.gasMinUsage) {
      state.lastGasActivityTime = now;
      if (frame.gas_logical_pct >= 99) state.lastFullThrottleTime = now;
    } else if ((now - state.lastFullThrottleTime) > (config.gasWindow * 1000)) {
      const sinceAlert = now - state.lastGasAlertTime;
      if (sinceAlert > (config.gasCooldown * 1000)) {
        frame.gas_alert_triggered = 1;
        frame.percentReached = frame.gas_logical_pct;
        state.lastGasAlertTime = now;
      }
    }

    // Clutch noise detection
    const diff = Math.abs(frame.clutchValue - state.lastClutch);
    if (diff <= frame.axisMargin) {
      state.repeating += 1;
      if (state.repeating >= config.clutchRepeat && config.monitorClutch) {
        frame.clutch_alert_triggered = 1;
        state.repeating = 0;
      }
    } else {
      state.repeating = 0;
    }
    state.lastClutch = frame.clutchValue;

    frame.peakGasInWindow = frame.gas_logical_pct > frame.peakGasInWindow ? frame.gas_logical_pct : frame.peakGasInWindow;
    frame.isRacing = frame.gas_logical_pct > 5 ? 1 : 0;

    frame.receivedAtUnixMs = Date.now();
    frame.metricLoopProcessMs = performance.now() - loopStart;
    frame.producer_notify_ms = Date.now() >>> 0;

    parentPort.postMessage({ type: 'frame', frame });
    state.prevLoopMs = performance.now() - loopStart;
    schedule();
  };

  const schedule = () => {
    setTimeout(poll, Math.max(0, config.pollIntervalMs));
  };

  schedule();
}

class TelemetryController extends EventEmitter {
  constructor(config, logger = new Logger()) {
    super();
    this.config = config;
    this.logger = logger;
    this.worker = null;
  }

  start() {
    if (this.worker) return;
    this.worker = new Worker(__filename, { workerData: { config: this.config } });
    this.worker.on('message', (msg) => {
      if (msg.type === 'frame') this.emit('frame', msg.frame);
    });
    this.worker.on('error', (err) => {
      this.logger.error(`Telemetry worker crashed: ${err.message}`);
    });
    this.worker.on('exit', (code) => {
      if (code !== 0) {
        this.logger.warn(`Telemetry worker exited with code ${code}`);
      }
    });
    this.logger.info('Telemetry worker started');
  }

  stop() {
    if (!this.worker) return;
    this.worker.terminate();
    this.worker = null;
  }
}

if (!isMainThread) {
  telemetryWorkerMain();
}

module.exports = { TelemetryController };
