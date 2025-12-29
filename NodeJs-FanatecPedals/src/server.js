const http = require('http');
const { WebSocketServer } = require('ws');
const yargs = require('yargs/yargs');
const { hideBin } = require('yargs/helpers');
const { TelemetryController } = require('./logic/telemetry');
const { TtsEngine } = require('./logic/tts');
const { loadConfig } = require('./config');
const { Logger } = require('./util/logger');

const argv = yargs(hideBin(process.argv)).option('configFile', { type: 'string' }).argv;
const config = loadConfig(argv);
const logger = new Logger(config.verbose);

logger.info('Starting NodeJs Fanatec Pedals bridge...');
const telemetryQueue = [];
let batchId = 0;

const ttsEngine = new TtsEngine(config.tts && !config.noTts, logger);
ttsEngine.start();

const telemetry = new TelemetryController(config, logger);
telemetry.on('frame', (frame) => {
  telemetryQueue.push(frame);
  if (telemetryQueue.length > 200) {
    telemetryQueue.splice(0, telemetryQueue.length - 200);
  }
  broadcastFrame(frame);
});
telemetry.start();

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(200, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': '*'
    });
    res.end();
    return;
  }

  if (req.url && req.url.includes('QUIT')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'quit received' }));
    shutdown();
    return;
  }

  const frames = telemetryQueue.splice(0, telemetryQueue.length);
  const payload = buildPayload(frames);
  const json = JSON.stringify(payload);
  res.writeHead(200, {
    'Access-Control-Allow-Origin': '*',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(json);
});

server.listen(config.httpPort, () => {
  logger.info(`HTTP telemetry endpoint listening on http://127.0.0.1:${config.httpPort}/`);
});

const wss = new WebSocketServer({ port: config.wsPort });
wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
});

function broadcastFrame(frame) {
  if (wss.clients.size === 0) return;
  const payload = buildPayload([frame]);
  const json = JSON.stringify(payload);
  wss.clients.forEach((client) => {
    if (client.readyState !== 1) return;
    if (client.bufferedAmount > (config.wsBackpressureLimit * json.length)) return;
    client.send(json);
  });
}

function buildPayload(frames) {
  batchId += 1;
  return {
    schemaVersion: 1,
    bridgeInfo: {
      batchId,
      servedAtUnixMs: Date.now(),
      pendingFrameCount: frames.length
    },
    frames
  };
}

function shutdown() {
  logger.info('Shutting down bridge...');
  telemetry.stop();
  ttsEngine.stop();
  server.close();
  wss.close();
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
