namespace PedDash.Models
{
    public sealed class PedalConfig
    {
        public string ConfigPath { get; set; } = string.Empty;
        public InputMode InputMode { get; set; } = InputMode.Simulation;

        public int SleepTime { get; set; } = 100;
        public int Margin { get; set; } = 5;
        public int ClutchRepeat { get; set; } = 4;
        public bool NoAxisNormalization { get; set; }

        public int GasDeadzoneIn { get; set; } = 5;
        public int GasDeadzoneOut { get; set; } = 93;
        public int BrakeDeadzoneIn { get; set; } = 5;
        public int BrakeDeadzoneOut { get; set; } = 93;
        public int ClutchDeadzoneIn { get; set; } = 5;
        public int ClutchDeadzoneOut { get; set; } = 93;
        public int GasWindow { get; set; } = 30;
        public int GasCooldown { get; set; } = 60;
        public int GasTimeout { get; set; } = 10;
        public int GasMinUsage { get; set; } = 20;

        public bool EstimateGasDeadzone { get; set; }
        public int AutoGasDeadzoneMin { get; set; } = -1;

        public int JoystickId { get; set; } = 17;
        public string VendorId { get; set; } = "0EB7";
        public string ProductId { get; set; } = "1839";

        public bool MonitorClutch { get; set; }
        public bool MonitorGas { get; set; } = true;
        public bool Telemetry { get; set; } = true;
        public bool Tts { get; set; } = true;
        public bool NoTts { get; set; }
        public bool NoConsoleBanner { get; set; }
        public bool DebugRaw { get; set; }
        public int Iterations { get; set; }
        public int JoyFlags { get; set; } = 255;
        public bool Idle { get; set; }
        public bool BelowNormal { get; set; }
        public string AffinityMask { get; set; } = string.Empty;
        public bool Verbose { get; set; }

        public int MaxHistory { get; set; } = 500;
        public string RenderSmoothingMode { get; set; } = "SmoothConvergence";
        public string RenderFpsCap { get; set; } = "Auto";
        public int SignalsWaveformHeightPercent { get; set; } = 100;
        public bool SignalsHideBrake { get; set; }
        public bool BrakeDeadzoneInExplicit { get; set; }
        public bool BrakeDeadzoneOutExplicit { get; set; }
        public bool ClutchDeadzoneInExplicit { get; set; }
        public bool ClutchDeadzoneOutExplicit { get; set; }

        public bool AxisNormalizationEnabled => !NoAxisNormalization;
        public bool EffectiveTtsEnabled => Tts && !NoTts;
        public bool AutoGasAdjustEnabled => AutoGasDeadzoneMin >= 0;

        public PedalConfig Clone()
        {
            return (PedalConfig)MemberwiseClone();
        }

        public void Normalize()
        {
            if (SleepTime < 1) SleepTime = 1;
            if (MaxHistory < 50) MaxHistory = 50;
            if (MaxHistory > 5000) MaxHistory = 5000;
            if (ClutchRepeat < 0) ClutchRepeat = 0;

            if (!BrakeDeadzoneInExplicit || BrakeDeadzoneIn < 0) BrakeDeadzoneIn = GasDeadzoneIn;
            if (!BrakeDeadzoneOutExplicit || BrakeDeadzoneOut < 0) BrakeDeadzoneOut = GasDeadzoneOut;
            if (!ClutchDeadzoneInExplicit || ClutchDeadzoneIn < 0) ClutchDeadzoneIn = GasDeadzoneIn;
            if (!ClutchDeadzoneOutExplicit || ClutchDeadzoneOut < 0) ClutchDeadzoneOut = GasDeadzoneOut;

            if (string.IsNullOrWhiteSpace(RenderSmoothingMode))
            {
                RenderSmoothingMode = "SmoothConvergence";
            }

            if (string.IsNullOrWhiteSpace(RenderFpsCap))
            {
                RenderFpsCap = "Auto";
            }

            SignalsWaveformHeightPercent = NormalizeSignalsWaveformHeightPercent(SignalsWaveformHeightPercent);
        }

        public static int NormalizeSignalsWaveformHeightPercent(int value)
        {
            int clamped = value;
            if (clamped < 70) clamped = 70;
            if (clamped > 140) clamped = 140;

            int normalized = ((clamped + 5) / 10) * 10;
            if (normalized < 70) normalized = 70;
            if (normalized > 140) normalized = 140;

            return normalized;
        }

        public int EffectiveRenderFps
        {
            get
            {
                if (string.Equals(RenderFpsCap, "Auto", System.StringComparison.OrdinalIgnoreCase))
                {
                    return 30;
                }

                return int.TryParse(RenderFpsCap, out int parsed) && parsed > 0 ? parsed : 30;
            }
        }
    }
}
