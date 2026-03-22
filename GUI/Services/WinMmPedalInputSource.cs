using PedDash.Models;
using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

namespace PedDash.Services
{
    public sealed class WinMmPedalInputSource : IPedalInputSource
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct JOYCAPS
        {
            public ushort wMid;
            public ushort wPid;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
            public uint wXmin;
            public uint wXmax;
            public uint wYmin;
            public uint wYmax;
            public uint wZmin;
            public uint wZmax;
            public uint wNumButtons;
            public uint wPeriodMin;
            public uint wPeriodMax;
            public uint wRmin;
            public uint wRmax;
            public uint wUmin;
            public uint wUmax;
            public uint wVmin;
            public uint wVmax;
            public uint wCaps;
            public uint wMaxAxes;
            public uint wNumAxes;
            public uint wMaxButtons;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOYINFOEX
        {
            public uint dwSize;
            public uint dwFlags;
            public uint dwXpos;
            public uint dwYpos;
            public uint dwZpos;
            public uint dwRpos;
            public uint dwUpos;
            public uint dwVpos;
            public uint dwButtons;
            public uint dwButtonNumber;
            public uint dwPOV;
            public uint dwReserved1;
            public uint dwReserved2;
        }

        [DllImport("winmm.dll")]
        private static extern uint joyGetNumDevs();

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern uint joyGetDevCaps(uint uJoyID, out JOYCAPS pjc, uint cbjc);

        [DllImport("winmm.dll")]
        private static extern uint joyGetPosEx(uint uJoyID, ref JOYINFOEX pji);

        private const uint JOYERR_NOERROR = 0;

        private readonly PedalConfig _config;
        private readonly int _targetVendorId;
        private readonly int _targetProductId;
        private readonly bool _hasReconnectTarget;
        private bool _isDisconnected;
        private long _nextScanUnixMs;
        private uint _currentJoyId;
        private string _deviceName = "Fanatec Pedals";
        private bool _deviceNameInitialized;

        public WinMmPedalInputSource(PedalConfig config)
        {
            _config = config;
            _targetVendorId = ParseHex(config.VendorId);
            _targetProductId = ParseHex(config.ProductId);
            _hasReconnectTarget = _targetVendorId != 0 && _targetProductId != 0;
            _currentJoyId = (uint)Math.Max(config.JoystickId, 0);

            if (_currentJoyId >= 16 && _hasReconnectTarget)
            {
                int found = FindFanatecDevice();
                if (found >= 0)
                {
                    _currentJoyId = (uint)found;
                }
            }
            else
            {
                UpdateDeviceName(_currentJoyId);
            }
        }

        public string DisplayName => _deviceName;

        public InputReadResult Read(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();

            long startUnix = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            long readStartTimestamp = Stopwatch.GetTimestamp();

            if (_isDisconnected && _hasReconnectTarget && startUnix >= _nextScanUnixMs)
            {
                int found = FindFanatecDevice();
                if (found >= 0)
                {
                    _currentJoyId = (uint)found;
                    _isDisconnected = false;
                }
                else
                {
                    _nextScanUnixMs = startUnix + 30_000;
                }
            }

            JOYINFOEX info = new JOYINFOEX
            {
                dwSize = (uint)Marshal.SizeOf<JOYINFOEX>(),
                dwFlags = (uint)_config.JoyFlags
            };

            uint result = joyGetPosEx(_currentJoyId, ref info);
            TimeSpan readElapsed = Stopwatch.GetElapsedTime(readStartTimestamp);

            if (result != JOYERR_NOERROR)
            {
                if (!_hasReconnectTarget)
                {
                    cancellationToken.WaitHandle.WaitOne(1000);
                    cancellationToken.ThrowIfCancellationRequested();
                }

                ConnectionChange change = _isDisconnected ? ConnectionChange.None : ConnectionChange.Disconnected;
                _isDisconnected = _hasReconnectTarget;
                _nextScanUnixMs = startUnix + (_hasReconnectTarget ? 30_000 : 1_000);

                return new InputReadResult
                {
                    IsConnected = false,
                    ConnectionChange = change,
                    JoyId = _currentJoyId,
                    JoyFlags = (uint)_config.JoyFlags,
                    AxisMax = (_config.JoyFlags & 256) != 0 ? 1023u : 65535u,
                    DeviceName = _deviceName,
                    DeviceReadStartUnixMs = startUnix,
                    DeviceReadDurationMs = (long)readElapsed.TotalMilliseconds,
                    SampleUnixMs = startUnix
                };
            }

            ConnectionChange stateChange = ConnectionChange.None;
            if (_isDisconnected)
            {
                _isDisconnected = false;
                stateChange = ConnectionChange.Reconnected;
            }

            if (!_deviceNameInitialized || stateChange == ConnectionChange.Reconnected)
            {
                UpdateDeviceName(_currentJoyId);
            }

            return new InputReadResult
            {
                IsConnected = true,
                ConnectionChange = stateChange,
                JoyId = _currentJoyId,
                JoyFlags = (uint)_config.JoyFlags,
                AxisMax = (_config.JoyFlags & 256) != 0 ? 1023u : 65535u,
                DeviceName = _deviceName,
                DeviceReadStartUnixMs = startUnix,
                DeviceReadDurationMs = (long)readElapsed.TotalMilliseconds,
                SampleUnixMs = startUnix,
                RawBrake = info.dwXpos,
                RawGas = info.dwYpos,
                RawClutch = info.dwRpos
            };
        }

        public void Dispose()
        {
        }

        private int FindFanatecDevice()
        {
            uint count = joyGetNumDevs();
            for (uint id = 0; id < count; id++)
            {
                if (!CheckDevice(id, _targetVendorId, _targetProductId))
                {
                    continue;
                }

                UpdateDeviceName(id);
                return (int)id;
            }

            return -1;
        }

        private static bool CheckDevice(uint id, int vendorId, int productId)
        {
            if (joyGetDevCaps(id, out JOYCAPS caps, (uint)Marshal.SizeOf<JOYCAPS>()) != JOYERR_NOERROR)
            {
                return false;
            }

            return caps.wMid == vendorId && caps.wPid == productId;
        }

        private static bool TryGetDeviceName(uint id, out string name)
        {
            if (joyGetDevCaps(id, out JOYCAPS caps, (uint)Marshal.SizeOf<JOYCAPS>()) == JOYERR_NOERROR)
            {
                name = string.IsNullOrWhiteSpace(caps.szPname) ? "Fanatec Pedals" : caps.szPname.Trim();
                return true;
            }

            name = "Fanatec Pedals";
            return false;
        }

        private void UpdateDeviceName(uint id)
        {
            if (TryGetDeviceName(id, out string name))
            {
                _deviceName = name;
                _deviceNameInitialized = true;
            }
        }

        private static int ParseHex(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return 0;
            }

            return int.TryParse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int parsed) ? parsed : 0;
        }
    }
}
