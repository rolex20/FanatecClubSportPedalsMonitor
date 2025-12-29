const levels = ['debug', 'info', 'warn', 'error'];

function format(level, message) {
  const ts = new Date().toISOString();
  return `[${ts}] [${level.toUpperCase()}] ${message}`;
}

class Logger {
  constructor(verbose = false) {
    this.verbose = verbose;
  }

  debug(msg) {
    if (this.verbose) {
      console.debug(format('debug', msg));
    }
  }

  info(msg) {
    console.info(format('info', msg));
  }

  warn(msg) {
    console.warn(format('warn', msg));
  }

  error(msg) {
    console.error(format('error', msg));
  }
}

module.exports = { Logger, levels };
