const ffi = require('ffi-napi');
const ref = require('ref-napi');
const StructType = require('ref-struct-di')(ref);

const DWORD = ref.types.uint32;

const JOYINFOEX = StructType({
  dwSize: DWORD,
  dwFlags: DWORD,
  dwXpos: DWORD,
  dwYpos: DWORD,
  dwZpos: DWORD,
  dwRpos: DWORD,
  dwUpos: DWORD,
  dwVpos: DWORD,
  dwButtons: DWORD,
  dwButtonNumber: DWORD,
  dwPOV: DWORD,
  dwReserved1: DWORD,
  dwReserved2: DWORD
});

const constants = {
  JOY_RETURNX: 0x0001,
  JOY_RETURNY: 0x0002,
  JOY_RETURNZ: 0x0004,
  JOY_RETURNR: 0x0008,
  JOY_RETURNU: 0x0010,
  JOY_RETURNV: 0x0020,
  JOY_RETURNPOV: 0x0040,
  JOY_RETURNBUTTONS: 0x0080,
  JOY_RETURNRAWDATA: 0x0100,
  JOY_RETURNPOVCTS: 0x0200,
  JOY_RETURNCENTERED: 0x0400,
  JOY_USEDEADZONE: 0x0800,
  JOY_RETURNALL: 0x00FF
};

let winmm;
try {
  winmm = ffi.Library('winmm', {
    joyGetPosEx: ['uint', ['uint', ref.refType(JOYINFOEX)]],
    joyGetNumDevs: ['uint', []]
  });
} catch (err) {
  // Allow module to load on non-Windows CI, but surface errors at runtime.
  winmm = null;
}

function pollJoystick(joyId, flags = constants.JOY_RETURNALL) {
  if (!winmm) throw new Error('winmm.dll not available');

  const info = new JOYINFOEX();
  info.dwSize = JOYINFOEX.size;
  info.dwFlags = flags;

  // Zeroed struct ensures TurboFan stable field offsets
  info.dwXpos = 0;
  info.dwYpos = 0;
  info.dwZpos = 0;
  info.dwRpos = 0;
  info.dwUpos = 0;
  info.dwVpos = 0;
  info.dwButtons = 0;
  info.dwButtonNumber = 0;
  info.dwPOV = 0;
  info.dwReserved1 = 0;
  info.dwReserved2 = 0;

  const res = winmm.joyGetPosEx(joyId >>> 0, info.ref());
  return { result: res >>> 0, info };
}

function getDeviceCount() {
  if (!winmm) return 0;
  return winmm.joyGetNumDevs();
}

module.exports = {
  pollJoystick,
  getDeviceCount,
  constants,
  JOYINFOEX
};
