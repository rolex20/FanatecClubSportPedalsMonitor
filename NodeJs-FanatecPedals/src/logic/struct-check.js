const { JOYINFOEX } = require('../ffi/joy');

function assertStruct() {
  if (!JOYINFOEX) throw new Error('JOYINFOEX struct missing');
  const size = JOYINFOEX.size;
  if (size !== 48) {
    throw new Error(`JOYINFOEX size mismatch: expected 48, got ${size}`);
  }
  console.log('JOYINFOEX size OK:', size);
}

try {
  assertStruct();
} catch (err) {
  console.error(err.message);
  process.exitCode = 1;
}
