const { Worker } = require('worker_threads');
const { Logger } = require('../util/logger');

function createTtsWorker() {
  return new Worker(`
    const { parentPort } = require('worker_threads');
    const say = require('say');
    parentPort.on('message', (msg) => {
      if (msg?.type === 'speak' && msg.text) {
        say.speak(msg.text, undefined, msg.speed || 1.0, (err) => {
          if (err) parentPort.postMessage({ type: 'error', error: err.message });
          else parentPort.postMessage({ type: 'spoken' });
        });
      }
    });
  `, { eval: true });
}

class TtsEngine {
  constructor(enabled, logger = new Logger()) {
    this.enabled = enabled;
    this.logger = logger;
    this.worker = null;
  }

  start() {
    if (!this.enabled || this.worker) return;
    this.worker = createTtsWorker();
    this.worker.on('message', (msg) => {
      if (msg.type === 'error') this.logger.warn(`TTS error: ${msg.error}`);
    });
    this.worker.on('error', (err) => this.logger.warn(`TTS worker crashed: ${err.message}`));
  }

  speak(text, speed = 1.0) {
    if (!this.enabled || !this.worker) return;
    this.worker.postMessage({ type: 'speak', text, speed });
  }

  stop() {
    if (this.worker) this.worker.terminate();
    this.worker = null;
  }
}

module.exports = { TtsEngine };
