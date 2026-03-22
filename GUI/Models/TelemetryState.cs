namespace PedDash.Models
{
    public enum TelemetryUpdateKind
    {
        Sample = 0,
        Paint = 1
    }

    public sealed class TelemetryState
    {
        private static readonly TelemetryState Empty = new();

        public string InputModeName { get; set; } = string.Empty;
        public string SourceName { get; set; } = string.Empty;

        public double GasPhysicalPct { get; set; }
        public double GasLogicalPct { get; set; }
        public double BrakePhysicalPct { get; set; }
        public double BrakeLogicalPct { get; set; }
        public double ClutchPhysicalPct { get; set; }
        public double ClutchLogicalPct { get; set; }

        public uint RawGas { get; set; }
        public uint GasValue { get; set; }
        public uint RawBrake { get; set; }
        public uint BrakeValue { get; set; }
        public uint RawClutch { get; set; }
        public uint ClutchValue { get; set; }

        public uint AxisMax { get; set; }
        public bool AxisNormalizationEnabled { get; set; }
        public uint JoyID { get; set; }
        public uint JoyFlags { get; set; }

        public bool VerboseFlag { get; set; }
        public bool MonitorClutch { get; set; }
        public bool MonitorGas { get; set; }
        public bool EstimateGasDeadzoneEnabled { get; set; }
        public bool AutoGasDeadzoneEnabled { get; set; }
        public int AutoGasDeadzoneMinimum { get; set; }
        public int Margin { get; set; }
        public int ClutchRepeatRequired { get; set; }
        public int Iterations { get; set; }

        public bool IsRacing { get; set; }
        public uint PeakGasInWindow { get; set; }
        public uint BestEstimatePercent { get; set; }
        public uint LastPrintedEstimate { get; set; }
        public uint EstimateWindowPeakPercent { get; set; }
        public uint EstimateWindowStartTime { get; set; }
        public uint LastEstimatePrintTime { get; set; }
        public uint LastFullThrottleTime { get; set; }
        public uint LastGasActivityTime { get; set; }
        public uint LastGasAlertTime { get; set; }
        public uint LastClutchValue { get; set; }
        public uint RepeatingClutchCount { get; set; }
        public uint PercentReached { get; set; }
        public uint CurrentPercent { get; set; }
        public int Closure { get; set; }

        public int GasDeadzoneIn { get; set; }
        public int GasDeadzoneOut { get; set; }
        public int BrakeDeadzoneIn { get; set; }
        public int BrakeDeadzoneOut { get; set; }
        public int ClutchDeadzoneIn { get; set; }
        public int ClutchDeadzoneOut { get; set; }
        public int GasMinUsagePercent { get; set; }
        public int GasWindow { get; set; }
        public int GasCooldown { get; set; }
        public int GasTimeout { get; set; }
        public uint GasIdleMax { get; set; }
        public uint GasFullMin { get; set; }
        public uint BrakeIdleMax { get; set; }
        public uint BrakeFullMin { get; set; }
        public uint ClutchIdleMax { get; set; }
        public uint ClutchFullMin { get; set; }
        public uint AxisMargin { get; set; }
        public uint GasTimeoutMs { get; set; }
        public uint GasWindowMs { get; set; }
        public uint GasCooldownMs { get; set; }

        public double TickPeriodMs { get; set; }
        public double ReadMs { get; set; }
        public double ComputeMs { get; set; }
        public double TickToPaintMs { get; set; }
        public double FullLoopTimeMs { get; set; }
        public double MetricLoopProcessMs { get; set; }
        public double MetricTtsSpeakMs { get; set; }

        public bool GasAlertTriggered { get; set; }
        public bool ClutchAlertTriggered { get; set; }
        public bool GasAutoAdjustApplied { get; set; }
        public bool GasEstimateDecreased { get; set; }
        public bool GasDeadzoneMinimumBreached { get; set; }
        public bool ControllerDisconnected { get; set; }
        public bool ControllerReconnected { get; set; }
        public int EffectiveGasDeadzoneOut { get; set; }
        public int LastBreachedEstimatePercent { get; set; }

        public uint SeqId { get; set; }
        public uint SeqGap { get; set; } = 1;
        public long DeviceReadStartUnixMs { get; set; }
        public long DeviceReadDurationMs { get; set; }
        public long SampleUnixMs { get; set; }
        public long EnqueueAtUnixMs { get; set; }
        public long ReceivedAtUnixMs { get; set; }
        public uint CurrentTickCount { get; set; }
        public uint ProducerLoopStartMs { get; set; }
        public uint ProducerNotifyMs { get; set; }
        public uint LastDisconnectTimeMs { get; set; }
        public uint LastReconnectTimeMs { get; set; }
        public TelemetryUpdateKind UpdateKind { get; set; }

        public void ResetForNextFrame()
        {
            CopyFrom(Empty);
        }

        public void CopyFrom(TelemetryState other)
        {
            InputModeName = other.InputModeName;
            SourceName = other.SourceName;

            GasPhysicalPct = other.GasPhysicalPct;
            GasLogicalPct = other.GasLogicalPct;
            BrakePhysicalPct = other.BrakePhysicalPct;
            BrakeLogicalPct = other.BrakeLogicalPct;
            ClutchPhysicalPct = other.ClutchPhysicalPct;
            ClutchLogicalPct = other.ClutchLogicalPct;

            RawGas = other.RawGas;
            GasValue = other.GasValue;
            RawBrake = other.RawBrake;
            BrakeValue = other.BrakeValue;
            RawClutch = other.RawClutch;
            ClutchValue = other.ClutchValue;

            AxisMax = other.AxisMax;
            AxisNormalizationEnabled = other.AxisNormalizationEnabled;
            JoyID = other.JoyID;
            JoyFlags = other.JoyFlags;

            VerboseFlag = other.VerboseFlag;
            MonitorClutch = other.MonitorClutch;
            MonitorGas = other.MonitorGas;
            EstimateGasDeadzoneEnabled = other.EstimateGasDeadzoneEnabled;
            AutoGasDeadzoneEnabled = other.AutoGasDeadzoneEnabled;
            AutoGasDeadzoneMinimum = other.AutoGasDeadzoneMinimum;
            Margin = other.Margin;
            ClutchRepeatRequired = other.ClutchRepeatRequired;
            Iterations = other.Iterations;

            IsRacing = other.IsRacing;
            PeakGasInWindow = other.PeakGasInWindow;
            BestEstimatePercent = other.BestEstimatePercent;
            LastPrintedEstimate = other.LastPrintedEstimate;
            EstimateWindowPeakPercent = other.EstimateWindowPeakPercent;
            EstimateWindowStartTime = other.EstimateWindowStartTime;
            LastEstimatePrintTime = other.LastEstimatePrintTime;
            LastFullThrottleTime = other.LastFullThrottleTime;
            LastGasActivityTime = other.LastGasActivityTime;
            LastGasAlertTime = other.LastGasAlertTime;
            LastClutchValue = other.LastClutchValue;
            RepeatingClutchCount = other.RepeatingClutchCount;
            PercentReached = other.PercentReached;
            CurrentPercent = other.CurrentPercent;
            Closure = other.Closure;

            GasDeadzoneIn = other.GasDeadzoneIn;
            GasDeadzoneOut = other.GasDeadzoneOut;
            BrakeDeadzoneIn = other.BrakeDeadzoneIn;
            BrakeDeadzoneOut = other.BrakeDeadzoneOut;
            ClutchDeadzoneIn = other.ClutchDeadzoneIn;
            ClutchDeadzoneOut = other.ClutchDeadzoneOut;
            GasMinUsagePercent = other.GasMinUsagePercent;
            GasWindow = other.GasWindow;
            GasCooldown = other.GasCooldown;
            GasTimeout = other.GasTimeout;
            GasIdleMax = other.GasIdleMax;
            GasFullMin = other.GasFullMin;
            BrakeIdleMax = other.BrakeIdleMax;
            BrakeFullMin = other.BrakeFullMin;
            ClutchIdleMax = other.ClutchIdleMax;
            ClutchFullMin = other.ClutchFullMin;
            AxisMargin = other.AxisMargin;
            GasTimeoutMs = other.GasTimeoutMs;
            GasWindowMs = other.GasWindowMs;
            GasCooldownMs = other.GasCooldownMs;

            TickPeriodMs = other.TickPeriodMs;
            ReadMs = other.ReadMs;
            ComputeMs = other.ComputeMs;
            TickToPaintMs = other.TickToPaintMs;
            FullLoopTimeMs = other.FullLoopTimeMs;
            MetricLoopProcessMs = other.MetricLoopProcessMs;
            MetricTtsSpeakMs = other.MetricTtsSpeakMs;

            GasAlertTriggered = other.GasAlertTriggered;
            ClutchAlertTriggered = other.ClutchAlertTriggered;
            GasAutoAdjustApplied = other.GasAutoAdjustApplied;
            GasEstimateDecreased = other.GasEstimateDecreased;
            GasDeadzoneMinimumBreached = other.GasDeadzoneMinimumBreached;
            ControllerDisconnected = other.ControllerDisconnected;
            ControllerReconnected = other.ControllerReconnected;
            EffectiveGasDeadzoneOut = other.EffectiveGasDeadzoneOut;
            LastBreachedEstimatePercent = other.LastBreachedEstimatePercent;

            SeqId = other.SeqId;
            SeqGap = other.SeqGap;
            DeviceReadStartUnixMs = other.DeviceReadStartUnixMs;
            DeviceReadDurationMs = other.DeviceReadDurationMs;
            SampleUnixMs = other.SampleUnixMs;
            EnqueueAtUnixMs = other.EnqueueAtUnixMs;
            ReceivedAtUnixMs = other.ReceivedAtUnixMs;
            CurrentTickCount = other.CurrentTickCount;
            ProducerLoopStartMs = other.ProducerLoopStartMs;
            ProducerNotifyMs = other.ProducerNotifyMs;
            LastDisconnectTimeMs = other.LastDisconnectTimeMs;
            LastReconnectTimeMs = other.LastReconnectTimeMs;
            UpdateKind = other.UpdateKind;
        }

        public TelemetryState Clone()
        {
            return (TelemetryState)MemberwiseClone();
        }
    }
}
