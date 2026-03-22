using PedDash.Models;
using System;
using System.Diagnostics;
using System.Threading;

namespace PedDash.Services
{
    public sealed class SimulationPedalInputSource : IPedalInputSource
    {
        private readonly PedalConfig _config;
        private readonly Stopwatch _stopwatch = Stopwatch.StartNew();

        public SimulationPedalInputSource(PedalConfig config)
        {
            _config = config;
        }

        public string DisplayName => "Synthetic Simulation";

        public InputReadResult Read(CancellationToken cancellationToken)
        {
            long startUnix = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            long startTicks = Environment.TickCount64;
            double t = _stopwatch.Elapsed.TotalSeconds;
            uint axisMax = (_config.JoyFlags & 256) != 0 ? 1023u : 65535u;

            double gasNormPercent = ((Math.Sin(t * 0.9) + 1.0) * 0.5) * 100.0;
            double brakeNormPercent = ((Math.Sin(t * 1.35 + 1.0) + 1.0) * 0.5) * 100.0;
            double clutchNormPercent = ((Math.Sin(t * 0.55 + 2.2) + 1.0) * 0.5) * 100.0;

            uint gasNorm = (uint)Math.Round((gasNormPercent / 100.0) * axisMax);
            uint brakeNorm = (uint)Math.Round((brakeNormPercent / 100.0) * axisMax);
            uint clutchNorm = (uint)Math.Round((clutchNormPercent / 100.0) * axisMax);

            uint rawGas = _config.AxisNormalizationEnabled ? axisMax - gasNorm : gasNorm;
            uint rawBrake = _config.AxisNormalizationEnabled ? axisMax - brakeNorm : brakeNorm;
            uint rawClutch = _config.AxisNormalizationEnabled ? axisMax - clutchNorm : clutchNorm;

            return new InputReadResult
            {
                IsConnected = true,
                ConnectionChange = ConnectionChange.None,
                JoyId = (uint)Math.Max(_config.JoystickId, 0),
                JoyFlags = (uint)_config.JoyFlags,
                AxisMax = axisMax,
                DeviceName = DisplayName,
                DeviceReadStartUnixMs = startUnix,
                DeviceReadDurationMs = Math.Max(0, Environment.TickCount64 - startTicks),
                SampleUnixMs = startUnix,
                RawGas = rawGas,
                RawBrake = rawBrake,
                RawClutch = rawClutch
            };
        }

        public void Dispose()
        {
        }
    }
}
