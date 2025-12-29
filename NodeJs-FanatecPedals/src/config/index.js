const fs = require('fs');
const path = require('path');
const ini = require('ini');

const defaultConfig = {
  pollIntervalMs: 10, // target >=100Hz for WebSocket streaming
  margin: 5,
  clutchRepeat: 4,
  axisNormalization: true,
  gasDeadzoneIn: 5,
  gasDeadzoneOut: 93,
  brakeDeadzoneIn: 5,
  brakeDeadzoneOut: 93,
  clutchDeadzoneIn: 5,
  clutchDeadzoneOut: 93,
  gasWindow: 30,
  gasCooldown: 60,
  gasTimeout: 10,
  gasMinUsage: 20,
  estimateGasDeadzone: false,
  autoGasDeadzoneMin: -1,
  joystickId: 17,
  vendorId: null,
  productId: null,
  monitorClutch: false,
  monitorGas: false,
  telemetry: true,
  tts: true,
  noTts: false,
  noConsoleBanner: false,
  debugRaw: false,
  iterations: 0,
  joyFlags: 255,
  idlePriority: false,
  belowNormalPriority: false,
  affinityMask: null,
  wsPort: 8182,
  httpPort: 8181,
  wsBackpressureLimit: 2,
  verbose: false,
  configFile: null
};

function normalizeBoolean(val) {
  if (typeof val === 'boolean') return val;
  if (typeof val === 'string') {
    const lowered = val.trim().toLowerCase();
    if (['1', 'true', 'yes', 'y', 'on'].includes(lowered)) return true;
    if (['0', 'false', 'no', 'n', 'off'].includes(lowered)) return false;
  }
  return Boolean(val);
}

function applyIniConfig(base, filePath) {
  if (!filePath) return base;
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) return base;

  const parsed = ini.parse(fs.readFileSync(resolved, 'utf-8'));
  const map = {
    sleeptime: 'pollIntervalMs',
    margin: 'margin',
    clutchrepeat: 'clutchRepeat',
    noaxisnormalization: 'axisNormalization',
    gasdeadzonein: 'gasDeadzoneIn',
    gasdeadzoneout: 'gasDeadzoneOut',
    brakedeadzonein: 'brakeDeadzoneIn',
    brakedeadzoneout: 'brakeDeadzoneOut',
    clutchdeadzonein: 'clutchDeadzoneIn',
    clutchdeadzoneout: 'clutchDeadzoneOut',
    gaswindow: 'gasWindow',
    gascooldown: 'gasCooldown',
    gastimeout: 'gasTimeout',
    gasminusage: 'gasMinUsage',
    estimategasdeadzone: 'estimateGasDeadzone',
    autogasdeadzonemin: 'autoGasDeadzoneMin',
    joystickid: 'joystickId',
    vendorid: 'vendorId',
    productid: 'productId',
    monitorclutch: 'monitorClutch',
    monitorgas: 'monitorGas',
    telemetry: 'telemetry',
    tts: 'tts',
    notts: 'noTts',
    noconsolebanner: 'noConsoleBanner',
    debugraw: 'debugRaw',
    iterations: 'iterations',
    joyflags: 'joyFlags',
    idle: 'idlePriority',
    belownormal: 'belowNormalPriority',
    affinitymask: 'affinityMask',
    verbose: 'verbose'
  };

  const next = { ...base };
  Object.entries(parsed).forEach(([key, value]) => {
    const normalizedKey = String(key).trim().toLowerCase();
    const target = map[normalizedKey];
    if (!target) return;
    if (typeof next[target] === 'boolean') {
      next[target] = normalizeBoolean(value);
    } else if (typeof next[target] === 'number') {
      const num = Number(value);
      if (!Number.isNaN(num)) next[target] = num;
    } else {
      next[target] = value;
    }
  });
  return next;
}

function loadConfig(argv = {}) {
  const config = { ...defaultConfig };
  const apply = (key, val) => {
    if (val === undefined || val === null) return;
    if (typeof config[key] === 'boolean') {
      config[key] = normalizeBoolean(val);
    } else if (typeof config[key] === 'number') {
      const num = Number(val);
      if (!Number.isNaN(num)) config[key] = num;
    } else {
      config[key] = val;
    }
  };

  // CLI overrides
  Object.entries(argv).forEach(([k, v]) => {
    if (k in config) apply(k, v);
  });

  // ENV overrides
  apply('pollIntervalMs', process.env.SLEEPTIME);
  apply('margin', process.env.MARGIN);
  apply('clutchRepeat', process.env.CLUTCHREPEAT);
  apply('gasDeadzoneIn', process.env.GASDEADZONEIN);
  apply('gasDeadzoneOut', process.env.GASDEADZONEOUT);
  apply('brakeDeadzoneIn', process.env.BRAKEDEADZONEIN);
  apply('brakeDeadzoneOut', process.env.BRAKEDEADZONEOUT);
  apply('clutchDeadzoneIn', process.env.CLUTCHDEADZONEIN);
  apply('clutchDeadzoneOut', process.env.CLUTCHDEADZONEOUT);
  apply('gasWindow', process.env.GASWINDOW);
  apply('gasCooldown', process.env.GASCOOLDOWN);
  apply('gasTimeout', process.env.GASTIMEOUT);
  apply('gasMinUsage', process.env.GASMINUSAGE);
  apply('estimateGasDeadzone', process.env.ESTIMATEGASDEADZONE);
  apply('autoGasDeadzoneMin', process.env.AUTOGASDEADZONEMIN);
  apply('joystickId', process.env.JOYSTICKID);
  apply('vendorId', process.env.VENDORID);
  apply('productId', process.env.PRODUCTID);
  apply('monitorClutch', process.env.MONITORCLUTCH);
  apply('monitorGas', process.env.MONITORGAS);
  apply('telemetry', process.env.TELEMETRY);
  apply('tts', process.env.TTS);
  apply('noTts', process.env.NOTTS);
  apply('noConsoleBanner', process.env.NOCONSOLEBANNER);
  apply('debugRaw', process.env.DEBUGRAW);
  apply('iterations', process.env.ITERATIONS);
  apply('joyFlags', process.env.JOYFLAGS);
  apply('idlePriority', process.env.IDLE);
  apply('belowNormalPriority', process.env.BELOWNORMAL);
  apply('affinityMask', process.env.AFFINITYMASK);
  apply('verbose', process.env.VERBOSE);
  apply('wsPort', process.env.WS_PORT);
  apply('httpPort', process.env.HTTP_PORT);

  if (argv.configFile || process.env.CONFIGFILE) {
    config.configFile = argv.configFile || process.env.CONFIGFILE;
    return applyIniConfig(config, config.configFile);
  }

  return config;
}

module.exports = { defaultConfig, loadConfig };
