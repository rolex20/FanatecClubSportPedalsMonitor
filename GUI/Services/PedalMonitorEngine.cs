using PedDash.Models;
using System;
using System.Collections.Generic;
using Microsoft.UI;

namespace PedDash.Services
{
    public sealed class PedalMonitorEngine
    {
        private const int ReconnectRetrySeconds = 30;
        private static readonly IReadOnlyList<EventLogItem> NoEvents = Array.Empty<EventLogItem>();

        private readonly PedalConfig _config;
        private readonly TtsService _tts;
        private readonly string _inputModeName;

        private uint _seqId;
        private double _previousLoopMs;

        private bool _isRacing;
        private bool _controllerDisconnected;
        private uint _lastFullThrottleTime;
        private uint _lastGasActivityTime;
        private uint _lastGasAlertTime;
        private uint _lastEstimatePrintTime;
        private uint _estimateWindowStartTime;
        private uint _bestEstimatePercent = 100;
        private uint _lastPrintedEstimate = 100;
        private uint _estimateWindowPeakPercent;
        private uint _peakGasInWindow;
        private uint _lastClutchValue;
        private uint _repeatingClutchCount;
        private uint _lastDisconnectTimeMs;
        private uint _lastReconnectTimeMs;
        private uint _currentPercent;
        private int _lastBreachedEstimatePercent;

        public PedalMonitorEngine(PedalConfig config, TtsService tts)
        {
            _config = config;
            _tts = tts;
            _inputModeName = _config.InputMode.ToString();
            ResetTransientState((uint)Environment.TickCount);
        }

        public MonitorFrameResult ProcessInput(InputReadResult input, double tickPeriodMs, TelemetryState frame)
        {
            List<EventLogItem>? events = null;
            long computeStartUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            uint nowTick = (uint)Environment.TickCount;

            frame.ResetForNextFrame();
            frame.SeqId = ++_seqId;
            frame.SeqGap = 1;
            frame.InputModeName = _inputModeName;
            frame.SourceName = input.DeviceName;
            frame.VerboseFlag = _config.Verbose;
            frame.MonitorClutch = _config.MonitorClutch;
            frame.MonitorGas = _config.MonitorGas;
            frame.EstimateGasDeadzoneEnabled = _config.EstimateGasDeadzone;
            frame.AutoGasDeadzoneEnabled = _config.AutoGasAdjustEnabled;
            frame.AutoGasDeadzoneMinimum = _config.AutoGasDeadzoneMin;
            frame.Margin = _config.Margin;
            frame.ClutchRepeatRequired = _config.ClutchRepeat;
            frame.Iterations = _config.Iterations;
            frame.GasDeadzoneIn = _config.GasDeadzoneIn;
            frame.GasDeadzoneOut = _config.GasDeadzoneOut;
            frame.BrakeDeadzoneIn = _config.BrakeDeadzoneIn;
            frame.BrakeDeadzoneOut = _config.BrakeDeadzoneOut;
            frame.ClutchDeadzoneIn = _config.ClutchDeadzoneIn;
            frame.ClutchDeadzoneOut = _config.ClutchDeadzoneOut;
            frame.GasMinUsagePercent = _config.GasMinUsage;
            frame.GasWindow = _config.GasWindow;
            frame.GasCooldown = _config.GasCooldown;
            frame.GasTimeout = _config.GasTimeout;
            frame.EffectiveGasDeadzoneOut = _config.GasDeadzoneOut;
            frame.AxisNormalizationEnabled = _config.AxisNormalizationEnabled;
            frame.JoyID = input.JoyId;
            frame.JoyFlags = input.JoyFlags;
            frame.AxisMax = input.AxisMax;
            frame.TickPeriodMs = tickPeriodMs;
            frame.DeviceReadStartUnixMs = input.DeviceReadStartUnixMs;
            frame.DeviceReadDurationMs = input.DeviceReadDurationMs;
            frame.SampleUnixMs = input.SampleUnixMs;
            frame.CurrentTickCount = nowTick;
            frame.ProducerLoopStartMs = nowTick;

            RecalculateThresholds(frame);
            frame.FullLoopTimeMs = _previousLoopMs;

            if (!input.IsConnected)
            {
                frame.ControllerDisconnected = true;

                if (!_controllerDisconnected || input.ConnectionChange == ConnectionChange.Disconnected)
                {
                    _controllerDisconnected = true;
                    _lastDisconnectTimeMs = nowTick;
                    frame.LastDisconnectTimeMs = _lastDisconnectTimeMs;
                    frame.MetricTtsSpeakMs = _tts.SpeakAsync("Controller disconnected. Waiting...");
                    string detail = HasReconnectScan()
                        ? $"Controller Lost. Retrying every {ReconnectRetrySeconds} seconds."
                        : "Controller Lost";
                    AddEvent(ref events, EventLogItem.Create("Alert", detail, Microsoft.UI.Colors.Red));
                }

                MirrorRuntimeState(frame);
                frame.ReceivedAtUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                frame.EnqueueAtUnixMs = frame.ReceivedAtUnixMs;
                frame.MetricLoopProcessMs = Math.Max(0, frame.EnqueueAtUnixMs - computeStartUnixMs);
                _previousLoopMs = frame.MetricLoopProcessMs;
                return new MonitorFrameResult(events ?? NoEvents, false);
            }

            if (_controllerDisconnected || input.ConnectionChange == ConnectionChange.Reconnected)
            {
                _controllerDisconnected = false;
                _lastReconnectTimeMs = nowTick;
                frame.ControllerReconnected = true;
                frame.LastReconnectTimeMs = _lastReconnectTimeMs;
                ResetTransientState(nowTick);
                AddEvent(ref events, EventLogItem.Create("Info", "Controller Reconnected", Microsoft.UI.Colors.LimeGreen));
                frame.MetricTtsSpeakMs = _tts.SpeakAsync("Controller connected.");
            }

            frame.RawGas = input.RawGas;
            frame.RawBrake = input.RawBrake;
            frame.RawClutch = input.RawClutch;

            if (frame.AxisNormalizationEnabled)
            {
                frame.GasValue = frame.AxisMax - frame.RawGas;
                frame.BrakeValue = frame.AxisMax - frame.RawBrake;
                frame.ClutchValue = frame.AxisMax - frame.RawClutch;
            }
            else
            {
                frame.GasValue = frame.RawGas;
                frame.BrakeValue = frame.RawBrake;
                frame.ClutchValue = frame.RawClutch;
            }

            UpdatePercentages(frame);

            if (_config.MonitorClutch)
            {
                ProcessClutchLogic(frame, ref events);
            }

            bool shouldPersistConfig = false;
            if (_config.MonitorGas)
            {
                shouldPersistConfig = ProcessGasLogic(frame, ref events);
            }

            MirrorRuntimeState(frame);
            frame.ReceivedAtUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            frame.EnqueueAtUnixMs = frame.ReceivedAtUnixMs;
            frame.ProducerNotifyMs = (uint)Environment.TickCount;
            frame.MetricLoopProcessMs = Math.Max(0, frame.EnqueueAtUnixMs - computeStartUnixMs);
            _previousLoopMs = frame.MetricLoopProcessMs;
            return new MonitorFrameResult(events ?? NoEvents, shouldPersistConfig);
        }

        private void ProcessClutchLogic(TelemetryState frame, ref List<EventLogItem>? events)
        {
            if (frame.GasValue <= frame.GasIdleMax && frame.ClutchValue > 0)
            {
                uint diff = frame.ClutchValue > _lastClutchValue
                    ? frame.ClutchValue - _lastClutchValue
                    : _lastClutchValue - frame.ClutchValue;

                frame.Closure = (int)diff;
                if (diff <= frame.AxisMargin)
                {
                    _repeatingClutchCount++;
                }
                else
                {
                    _repeatingClutchCount = 0;
                }
            }
            else
            {
                _repeatingClutchCount = 0;
            }

            _lastClutchValue = frame.ClutchValue;
            if (_repeatingClutchCount < (uint)_config.ClutchRepeat)
            {
                return;
            }

            frame.ClutchAlertTriggered = true;
            frame.MetricTtsSpeakMs = _tts.SpeakAsync("Rudder.");
            AddEvent(ref events, EventLogItem.Create("Warn", "Rudder Noise Issue", Microsoft.UI.Colors.Orange));
            _repeatingClutchCount = 0;
        }

        private bool ProcessGasLogic(TelemetryState frame, ref List<EventLogItem>? events)
        {
            bool saveConfig = false;
            uint now = frame.CurrentTickCount;

            if (frame.GasValue > frame.GasIdleMax)
            {
                if (!_isRacing)
                {
                    _lastFullThrottleTime = now;
                    _peakGasInWindow = 0;

                    if (_config.EstimateGasDeadzone)
                    {
                        _estimateWindowStartTime = now;
                        _estimateWindowPeakPercent = 0;
                    }

                    _isRacing = true;
                }

                _lastGasActivityTime = now;
            }
            else if (_isRacing && unchecked(now - _lastGasActivityTime) > frame.GasTimeoutMs)
            {
                _isRacing = false;

                if (_config.EstimateGasDeadzone)
                {
                    _estimateWindowStartTime = now;
                    _estimateWindowPeakPercent = 0;
                }
            }

            if (!_isRacing)
            {
                return false;
            }

            if (frame.GasValue > _peakGasInWindow)
            {
                _peakGasInWindow = frame.GasValue;
            }

            if (frame.GasValue >= frame.GasFullMin)
            {
                _lastFullThrottleTime = now;
                _peakGasInWindow = 0;
            }
            else if (unchecked(now - _lastFullThrottleTime) > frame.GasWindowMs)
            {
                if (unchecked(now - _lastGasAlertTime) > frame.GasCooldownMs)
                {
                    uint percentReached = frame.AxisMax == 0 ? 0 : (uint)(100 * _peakGasInWindow / frame.AxisMax);
                    frame.PercentReached = percentReached;
                    if (percentReached > (uint)_config.GasMinUsage)
                    {
                        frame.GasAlertTriggered = true;
                        frame.MetricTtsSpeakMs = _tts.SpeakAsync($"Gas {percentReached} percent.");
                        AddEvent(ref events, EventLogItem.Create("Alert", $"Gas Pedal Only Reached {percentReached}% (Drift Issue)", Microsoft.UI.Colors.Red));
                        _lastGasAlertTime = now;
                    }
                }
            }

            if (!_config.EstimateGasDeadzone)
            {
                return false;
            }

            if (frame.GasValue > frame.GasIdleMax)
            {
                uint currentPercent = frame.AxisMax == 0 ? 0 : (uint)Math.Floor(frame.GasValue * 100.0 / frame.AxisMax);
                _currentPercent = currentPercent;
                frame.CurrentPercent = currentPercent;
                if (currentPercent > _estimateWindowPeakPercent)
                {
                    _estimateWindowPeakPercent = currentPercent;
                }
            }

            if (unchecked(now - _estimateWindowStartTime) < frame.GasCooldownMs)
            {
                return false;
            }

            if (_estimateWindowPeakPercent >= (uint)_config.GasMinUsage)
            {
                uint candidate = _estimateWindowPeakPercent;
                bool bestEstimateImproved = false;
                if (candidate < _bestEstimatePercent)
                {
                    _bestEstimatePercent = candidate;
                    bestEstimateImproved = true;
                }

                if (_bestEstimatePercent < _lastPrintedEstimate && unchecked(now - _lastEstimatePrintTime) >= frame.GasCooldownMs)
                {
                    frame.GasEstimateDecreased = true;
                    frame.MetricTtsSpeakMs = _tts.SpeakAsync($"New deadzone estimation {_bestEstimatePercent} percent.");
                    AddEvent(ref events, EventLogItem.Create("Warn", $"New deadzone estimation: {_bestEstimatePercent}%", Microsoft.UI.Colors.DeepSkyBlue));
                    _lastPrintedEstimate = _bestEstimatePercent;
                    _lastEstimatePrintTime = now;
                }

                if (_config.AutoGasAdjustEnabled &&
                    bestEstimateImproved &&
                    _bestEstimatePercent < (uint)_config.GasDeadzoneOut)
                {
                    if (_bestEstimatePercent >= (uint)_config.AutoGasDeadzoneMin)
                    {
                        _config.GasDeadzoneOut = (int)_bestEstimatePercent;
                        frame.GasDeadzoneOut = _config.GasDeadzoneOut;
                        frame.EffectiveGasDeadzoneOut = _config.GasDeadzoneOut;
                        frame.GasAutoAdjustApplied = true;
                        frame.MetricTtsSpeakMs = _tts.SpeakAsync($"Auto adjusted deadzone to {_config.GasDeadzoneOut} percent.");
                        AddEvent(ref events, EventLogItem.Create("Info", $"Auto-adjust applied: DZ Out -> {_config.GasDeadzoneOut}%", Microsoft.UI.Colors.DeepSkyBlue));
                        RecalculateThresholds(frame);
                        
                        // AUTHORITATIVE OVERRIDE:
                        // We deliberately DO NOT set "saveConfig = true" here anymore.
                        // We DO NOT want the background telemetry thread to overwrite the user's .ini file
                        // dynamically. The .ini establishes the baseline deadzone on startup/reconnect, and
                        // runtime auto-adjustments remain strictly in-memory for the duration of the session.
                        // DO NOT REINTRODUCE AUTO-SAVING TO DISK ON THIS THREAD.
                    }
                    else
                    {
                        string warning = $"WARNING: Estimated deadzone {_bestEstimatePercent} percent, below minimum {_config.AutoGasDeadzoneMin}. Raise deadzone in game or reconnect controller.";
                        frame.GasDeadzoneMinimumBreached = true;
                        frame.LastBreachedEstimatePercent = (int)_bestEstimatePercent;
                        frame.EffectiveGasDeadzoneOut = _config.GasDeadzoneOut;
                        frame.MetricTtsSpeakMs = _tts.SpeakAsync(warning);
                        AddEvent(ref events, EventLogItem.Create("Warn", warning, Microsoft.UI.Colors.Gold));
                        _lastBreachedEstimatePercent = (int)_bestEstimatePercent;
                    }
                }
            }

            _estimateWindowStartTime = now;
            _estimateWindowPeakPercent = 0;
            return saveConfig;
        }

        private static void AddEvent(ref List<EventLogItem>? events, EventLogItem item)
        {
            (events ??= new List<EventLogItem>()).Add(item);
        }

        private static void UpdatePercentages(TelemetryState frame)
        {
            if (frame.AxisMax == 0)
            {
                return;
            }

            frame.GasPhysicalPct = 100.0 * frame.GasValue / frame.AxisMax;
            frame.BrakePhysicalPct = 100.0 * frame.BrakeValue / frame.AxisMax;
            frame.ClutchPhysicalPct = 100.0 * frame.ClutchValue / frame.AxisMax;

            frame.GasLogicalPct = ComputeLogicalPct(frame.GasValue, frame.GasIdleMax, frame.GasFullMin);
            frame.BrakeLogicalPct = ComputeLogicalPct(frame.BrakeValue, frame.BrakeIdleMax, frame.BrakeFullMin);
            frame.ClutchLogicalPct = ComputeLogicalPct(frame.ClutchValue, frame.ClutchIdleMax, frame.ClutchFullMin);
        }

        private static double ComputeLogicalPct(uint value, uint idleMax, uint fullMin)
        {
            if (value <= idleMax || fullMin <= idleMax) return 0;
            if (value >= fullMin) return 100;
            return 100.0 * (value - idleMax) / (fullMin - idleMax);
        }

        private void RecalculateThresholds(TelemetryState frame)
        {
            frame.GasIdleMax = (uint)(frame.AxisMax * Math.Max(_config.GasDeadzoneIn, 0) / 100);
            frame.GasFullMin = (uint)Math.Floor(frame.AxisMax * Math.Max(_config.GasDeadzoneOut, 0) / 100.0);
            frame.BrakeIdleMax = (uint)(frame.AxisMax * Math.Max(_config.BrakeDeadzoneIn, 0) / 100);
            frame.BrakeFullMin = (uint)Math.Floor(frame.AxisMax * Math.Max(_config.BrakeDeadzoneOut, 0) / 100.0);
            frame.ClutchIdleMax = (uint)(frame.AxisMax * Math.Max(_config.ClutchDeadzoneIn, 0) / 100);
            frame.ClutchFullMin = (uint)Math.Floor(frame.AxisMax * Math.Max(_config.ClutchDeadzoneOut, 0) / 100.0);
            frame.AxisMargin = (uint)(frame.AxisMax * Math.Max(_config.Margin, 0) / 100);
            frame.GasTimeoutMs = (uint)(Math.Max(_config.GasTimeout, 0) * 1000);
            frame.GasWindowMs = (uint)(Math.Max(_config.GasWindow, 0) * 1000);
            frame.GasCooldownMs = (uint)(Math.Max(_config.GasCooldown, 0) * 1000);
        }

        private void MirrorRuntimeState(TelemetryState frame)
        {
            frame.IsRacing = _isRacing;
            frame.PeakGasInWindow = _peakGasInWindow;
            frame.BestEstimatePercent = _bestEstimatePercent;
            frame.LastPrintedEstimate = _lastPrintedEstimate;
            frame.EstimateWindowPeakPercent = _estimateWindowPeakPercent;
            frame.EstimateWindowStartTime = _estimateWindowStartTime;
            frame.LastEstimatePrintTime = _lastEstimatePrintTime;
            frame.LastFullThrottleTime = _lastFullThrottleTime;
            frame.LastGasActivityTime = _lastGasActivityTime;
            frame.LastGasAlertTime = _lastGasAlertTime;
            frame.LastClutchValue = _lastClutchValue;
            frame.RepeatingClutchCount = _repeatingClutchCount;
            frame.LastDisconnectTimeMs = _lastDisconnectTimeMs;
            frame.LastReconnectTimeMs = _lastReconnectTimeMs;
            frame.CurrentPercent = _currentPercent;
            frame.EffectiveGasDeadzoneOut = _config.GasDeadzoneOut;
            frame.LastBreachedEstimatePercent = _lastBreachedEstimatePercent;
            frame.ControllerDisconnected = _controllerDisconnected || frame.ControllerDisconnected;
        }

        private void ResetTransientState(uint now)
        {
            _isRacing = false;
            _lastFullThrottleTime = now;
            _lastGasActivityTime = now;
            _lastGasAlertTime = 0;
            _lastEstimatePrintTime = 0;
            _estimateWindowStartTime = now;
            _bestEstimatePercent = 100;
            _lastPrintedEstimate = 100;
            _estimateWindowPeakPercent = 0;
            _peakGasInWindow = 0;
            _lastClutchValue = 0;
            _repeatingClutchCount = 0;
            _currentPercent = 0;
            _lastBreachedEstimatePercent = 0;
        }

        private bool HasReconnectScan()
        {
            return _config.InputMode == InputMode.Hardware &&
                   !string.IsNullOrWhiteSpace(_config.VendorId) &&
                   !string.IsNullOrWhiteSpace(_config.ProductId);
        }
    }

    public readonly struct MonitorFrameResult
    {
        public MonitorFrameResult(IReadOnlyList<EventLogItem> events, bool shouldPersistConfig)
        {
            Events = events;
            ShouldPersistConfig = shouldPersistConfig;
        }

        public IReadOnlyList<EventLogItem> Events { get; }
        public bool ShouldPersistConfig { get; }
    }
}
