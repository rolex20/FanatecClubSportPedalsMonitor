using PedDash.Models;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI;

namespace PedDash.Services
{
    public readonly struct SignalsSnapshotResult
    {
        public SignalsSnapshotResult(int count, int sleepTime, bool copied, bool gasChanged, bool brakeChanged, bool clutchChanged)
        {
            Count = count;
            SleepTime = sleepTime;
            Copied = copied;
            GasChanged = gasChanged;
            BrakeChanged = brakeChanged;
            ClutchChanged = clutchChanged;
        }

        public int Count { get; }
        public int SleepTime { get; }
        public bool Copied { get; }
        public bool GasChanged { get; }
        public bool BrakeChanged { get; }
        public bool ClutchChanged { get; }
    }

    public readonly struct LagSnapshotResult
    {
        public LagSnapshotResult(int count, bool copied, double tickAverage, double readAverage, double computeAverage, double paintAverage, double maxLag)
        {
            Count = count;
            Copied = copied;
            TickAverage = tickAverage;
            ReadAverage = readAverage;
            ComputeAverage = computeAverage;
            PaintAverage = paintAverage;
            MaxLag = maxLag;
        }

        public int Count { get; }
        public bool Copied { get; }
        public double TickAverage { get; }
        public double ReadAverage { get; }
        public double ComputeAverage { get; }
        public double PaintAverage { get; }
        public double MaxLag { get; }
    }

    public sealed class PedalRuntimeService : IDisposable
    {
        private readonly object _gate = new();
        private TelemetryState[] _historyBuffer = Array.Empty<TelemetryState>();
        private int _historyStart;
        private int _historyCount;
        private EventLogItem[] _eventBuffer = Array.Empty<EventLogItem>();
        private int _eventStart;
        private int _eventCount;
        private readonly IniConfigStore _configStore = new();
        private readonly Stopwatch _runtimeClock = Stopwatch.StartNew();
        private readonly TelemetryState _stagingFrame = new();

        private CancellationTokenSource? _cts;
        private Task? _loopTask;
        private IPedalInputSource? _inputSource;
        private TtsService? _tts;
        private PedalMonitorEngine? _engine;
        private PedalConfig _config = new();
        private long _lastTickMs;
        private long _lastUiFrameUnixMs;
        private bool _restartRequired;
        private uint _lastPaintedSeq;

        public event Action<TelemetryState>? OnFrameReady;
        public event Action<EventLogItem>? OnEventLogged;

        public PedalConfig Config
        {
            get
            {
                lock (_gate)
                {
                    return _config.Clone();
                }
            }
        }

        public bool RestartRequired
        {
            get
            {
                lock (_gate)
                {
                    return _restartRequired;
                }
            }
        }

        public IReadOnlyList<TelemetryState> History => GetHistory();
        public IReadOnlyList<EventLogItem> Events => GetEvents();

        public void Start(string? configOverridePath)
        {
            Stop();

            lock (_gate)
            {
                _config = _configStore.Load(configOverridePath);
                _config.Normalize();
                ApplyProcessSettings(_config);
                _restartRequired = false;
                ResetHistoryUnsafe();
                ResetEventsUnsafe();
                _lastPaintedSeq = 0;
                _lastUiFrameUnixMs = 0;
            }

            _tts = new TtsService(_config);
            _inputSource = CreateInputSource(_config);
            _engine = new PedalMonitorEngine(_config, _tts);
            _lastTickMs = _runtimeClock.ElapsedMilliseconds;

            _cts = new CancellationTokenSource();
            _loopTask = Task.Run(() => RunLoop(_cts.Token));

            AddEvent(EventLogItem.Create("Info", $"{_config.InputMode} input ready", Microsoft.UI.Colors.LimeGreen));
        }

        public void Stop()
        {
            _cts?.Cancel();

            try
            {
                _loopTask?.Wait(TimeSpan.FromSeconds(2));
            }
            catch
            {
            }

            _loopTask = null;
            _cts?.Dispose();
            _cts = null;

            _inputSource?.Dispose();
            _inputSource = null;
            _tts?.Dispose();
            _tts = null;
            _engine = null;
        }

        public void Dispose()
        {
            Stop();
        }

        public IReadOnlyList<TelemetryState> GetHistory()
        {
            lock (_gate)
            {
                var history = new List<TelemetryState>(_historyCount);
                for (int i = 0; i < _historyCount; i++)
                {
                    history.Add(GetHistoryFrameUnsafe(i).Clone());
                }

                return history;
            }
        }

        public IReadOnlyList<EventLogItem> GetEvents()
        {
            lock (_gate)
            {
                var events = new List<EventLogItem>(_eventCount);
                for (int i = _eventCount - 1; i >= 0; i--)
                {
                    events.Add(GetEventUnsafe(i));
                }

                return events;
            }
        }

        public SignalsSnapshotResult CopySignalsSnapshot(double[] gasBuffer, double[] brakeBuffer, double[] clutchBuffer)
        {
            lock (_gate)
            {
                int count = _historyCount;
                int sleepTime = Math.Max(1, _config.SleepTime);
                if (gasBuffer.Length < count || brakeBuffer.Length < count || clutchBuffer.Length < count)
                {
                    return new SignalsSnapshotResult(count, sleepTime, false, false, false, false);
                }

                bool gasChanged = false;
                bool brakeChanged = false;
                bool clutchChanged = false;

                for (int i = 0; i < count; i++)
                {
                    TelemetryState frame = GetHistoryFrameUnsafe(i);
                    double gas = frame.GasPhysicalPct;
                    double brake = frame.BrakePhysicalPct;
                    double clutch = frame.ClutchPhysicalPct;

                    if (gasBuffer[i] != gas)
                    {
                        gasBuffer[i] = gas;
                        gasChanged = true;
                    }

                    if (brakeBuffer[i] != brake)
                    {
                        brakeBuffer[i] = brake;
                        brakeChanged = true;
                    }

                    if (clutchBuffer[i] != clutch)
                    {
                        clutchBuffer[i] = clutch;
                        clutchChanged = true;
                    }
                }

                return new SignalsSnapshotResult(count, sleepTime, true, gasChanged, brakeChanged, clutchChanged);
            }
        }

        public LagSnapshotResult CopyLagSnapshot(double[] tickBuffer, double[] readBuffer, double[] computeBuffer, double[] paintBuffer)
        {
            lock (_gate)
            {
                int count = _historyCount;
                if (tickBuffer.Length < count || readBuffer.Length < count || computeBuffer.Length < count || paintBuffer.Length < count)
                {
                    return new LagSnapshotResult(count, false, 0, 0, 0, 0, 10);
                }

                double tickSum = 0;
                double readSum = 0;
                double computeSum = 0;
                double paintSum = 0;
                double maxLag = 10;

                for (int i = 0; i < count; i++)
                {
                    TelemetryState frame = GetHistoryFrameUnsafe(i);
                    double tick = frame.TickPeriodMs;
                    double read = frame.ReadMs;
                    double compute = frame.ComputeMs;
                    double paint = frame.TickToPaintMs;

                    tickBuffer[i] = tick;
                    readBuffer[i] = read;
                    computeBuffer[i] = compute;
                    paintBuffer[i] = paint;

                    tickSum += tick;
                    readSum += read;
                    computeSum += compute;
                    paintSum += paint;
                    if (tick > maxLag)
                    {
                        maxLag = tick;
                    }
                }

                if (count == 0)
                {
                    return new LagSnapshotResult(0, true, 0, 0, 0, 0, maxLag);
                }

                return new LagSnapshotResult(
                    count,
                    true,
                    tickSum / count,
                    readSum / count,
                    computeSum / count,
                    paintSum / count,
                    maxLag);
            }
        }

        public void ReportPaint(uint seqId)
        {
            TelemetryState? clone = null;

            lock (_gate)
            {
                if (seqId == 0 || seqId == _lastPaintedSeq)
                {
                    return;
                }

                TelemetryState? frame = null;
                for (int i = _historyCount - 1; i >= 0; i--)
                {
                    TelemetryState candidate = GetHistoryFrameUnsafe(i);
                    if (candidate.SeqId == seqId)
                    {
                        frame = candidate;
                        break;
                    }
                }

                if (frame is null || frame.TickToPaintMs > 0 || frame.SampleUnixMs <= 0)
                {
                    return;
                }

                frame.TickToPaintMs = Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - frame.SampleUnixMs);
                _lastPaintedSeq = seqId;
                clone = frame.Clone();
                clone.UpdateKind = TelemetryUpdateKind.Paint;
            }

            if (clone is not null)
            {
                OnFrameReady?.Invoke(clone);
            }
        }

        public void UpdateConfig(Action<PedalConfig> updater, bool requiresRestart)
        {
            lock (_gate)
            {
                updater(_config);
                _config.Normalize();
                _configStore.Save(_config);
                _tts?.ApplyConfig(_config);
                if (requiresRestart)
                {
                    _restartRequired = true;
                }
            }

            if (requiresRestart)
            {
                AddEvent(EventLogItem.Create("Info", "Restart required for hardware/process changes", Microsoft.UI.Colors.Gold));
            }
        }

        public void ChangeMaxHistory(int newMax)
        {
            UpdateConfig(config => config.MaxHistory = newMax, false);

            lock (_gate)
            {
                ResizeHistoryBufferUnsafe(GetHistoryCapacityUnsafe());
                TrimHistoryUnsafe();
                ResizeEventBufferUnsafe(GetEventCapacityUnsafe());
                TrimEventsUnsafe();
            }
        }

        public string BuildEventsCsv()
        {
            var builder = new StringBuilder();
            builder.AppendLine("Time,Type,Message");

            foreach (EventLogItem item in GetEvents())
            {
                builder.AppendLine($"{EscapeCsv(item.Time)},{EscapeCsv(item.Type)},{EscapeCsv(item.Details)}");
            }

            return builder.ToString();
        }

        public string BuildTelemetryCsv()
        {
            var builder = new StringBuilder();
            builder.AppendLine("Seq,Mode,Source,GasPhys,GasLog,BrakePhys,BrakeLog,ClutchPhys,ClutchLog,TickMs,ReadMs,ComputeMs,PaintMs,Connected");

            foreach (TelemetryState frame in GetHistory())
            {
                builder.AppendLine(string.Join(",",
                    frame.SeqId.ToString(CultureInfo.InvariantCulture),
                    EscapeCsv(frame.InputModeName),
                    EscapeCsv(frame.SourceName),
                    frame.GasPhysicalPct.ToString("F2", CultureInfo.InvariantCulture),
                    frame.GasLogicalPct.ToString("F2", CultureInfo.InvariantCulture),
                    frame.BrakePhysicalPct.ToString("F2", CultureInfo.InvariantCulture),
                    frame.BrakeLogicalPct.ToString("F2", CultureInfo.InvariantCulture),
                    frame.ClutchPhysicalPct.ToString("F2", CultureInfo.InvariantCulture),
                    frame.ClutchLogicalPct.ToString("F2", CultureInfo.InvariantCulture),
                    frame.TickPeriodMs.ToString("F2", CultureInfo.InvariantCulture),
                    frame.ReadMs.ToString("F2", CultureInfo.InvariantCulture),
                    frame.ComputeMs.ToString("F2", CultureInfo.InvariantCulture),
                    frame.TickToPaintMs.ToString("F2", CultureInfo.InvariantCulture),
                    (!frame.ControllerDisconnected).ToString()));
            }

            return builder.ToString();
        }

        private async Task RunLoop(CancellationToken cancellationToken)
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                TelemetryState? frame = null;
                IReadOnlyList<EventLogItem> events = Array.Empty<EventLogItem>();
                bool persistConfig = false;

                try
                {
                    long nowMs = _runtimeClock.ElapsedMilliseconds;
                    double tickPeriodMs = nowMs - _lastTickMs;
                    _lastTickMs = nowMs;

                    long readStartTimestamp = Stopwatch.GetTimestamp();
                    InputReadResult input = _inputSource!.Read(cancellationToken);
                    TimeSpan readElapsed = Stopwatch.GetElapsedTime(readStartTimestamp);

                    long computeStartTimestamp = Stopwatch.GetTimestamp();
                    MonitorFrameResult result = _engine!.ProcessInput(input, tickPeriodMs, _stagingFrame);
                    TimeSpan computeElapsed = Stopwatch.GetElapsedTime(computeStartTimestamp);

                    frame = _stagingFrame;
                    frame.ReadMs = readElapsed.TotalMilliseconds > 0
                        ? readElapsed.TotalMilliseconds
                        : input.DeviceReadDurationMs;
                    frame.ComputeMs = computeElapsed.TotalMilliseconds;
                    
                    if (frame.ControllerReconnected)
                    {
                        lock (_gate)
                        {
                            var reloaded = _configStore.Load(_config.ConfigPath);
                            // Reset ONLY the dynamic deadzones back to their baseline 
                            // to avoid replacing the entire complex object reference graph.
                            // The PedalMonitorEngine holds a reference to _config and reads it continuously.
                            _config.GasDeadzoneOut = reloaded.GasDeadzoneOut;
                            _config.GasDeadzoneIn = reloaded.GasDeadzoneIn;
                            _config.BrakeDeadzoneOut = reloaded.BrakeDeadzoneOut;
                            _config.BrakeDeadzoneIn = reloaded.BrakeDeadzoneIn;
                            _config.ClutchDeadzoneOut = reloaded.ClutchDeadzoneOut;
                            _config.ClutchDeadzoneIn = reloaded.ClutchDeadzoneIn;
                            _config.AutoGasDeadzoneMin = reloaded.AutoGasDeadzoneMin;
                        }
                        
                        AddEvent(EventLogItem.Create("Info", "Baseline Config (Deadzones) reloaded", Microsoft.UI.Colors.DeepSkyBlue));
                    }

                    persistConfig = result.ShouldPersistConfig;
                    events = result.Events;
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    AddEvent(EventLogItem.Create("Alert", $"Runtime error: {ex.Message}", Microsoft.UI.Colors.Red));
                }

                if (frame is not null)
                {
                    PublishFrame(frame, events);
                    if (persistConfig)
                    {
                        lock (_gate)
                        {
                            _configStore.Save(_config);
                        }
                    }
                }

                int sleepTime;
                lock (_gate)
                {
                    sleepTime = Math.Max(1, _config.SleepTime);
                }

                await Task.Delay(sleepTime, cancellationToken);
            }
        }

        private void PublishFrame(TelemetryState frame, IReadOnlyList<EventLogItem> events)
        {
            frame.UpdateKind = TelemetryUpdateKind.Sample;

            lock (_gate)
            {
                AppendHistoryFrameUnsafe(frame);
            }

            foreach (EventLogItem item in events)
            {
                AddEvent(item);
            }

            if (ShouldNotifyUi(frame))
            {
                OnFrameReady?.Invoke(frame.Clone());
            }
        }

        private bool ShouldNotifyUi(TelemetryState frame)
        {
            lock (_gate)
            {
                long now = frame.SampleUnixMs > 0 ? frame.SampleUnixMs : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                double minIntervalMs = 1000.0 / Math.Max(1, _config.EffectiveRenderFps);
                if (_lastUiFrameUnixMs == 0 || now - _lastUiFrameUnixMs >= minIntervalMs)
                {
                    _lastUiFrameUnixMs = now;
                    return true;
                }

                return false;
            }
        }

        private void AddEvent(EventLogItem item)
        {
            lock (_gate)
            {
                EventLogItem? latest = _eventCount > 0 ? GetLatestEventUnsafe() : null;
                if (latest is not null &&
                    latest.Details == item.Details &&
                    (item.Timestamp - latest.Timestamp).TotalSeconds < 2)
                {
                    return;
                }

                AppendEventUnsafe(item);
            }

            OnEventLogged?.Invoke(item);
        }

        private void TrimHistoryUnsafe()
        {
            int max = GetHistoryCapacityUnsafe();
            while (_historyCount > max)
            {
                _historyStart = (_historyStart + 1) % _historyBuffer.Length;
                _historyCount--;
            }
        }

        private int GetHistoryCapacityUnsafe()
        {
            return Math.Max(_config.MaxHistory, 50);
        }

        private int GetEventCapacityUnsafe()
        {
            return Math.Max(_config.MaxHistory, 200);
        }

        private void ResetHistoryUnsafe()
        {
            ResizeHistoryBufferUnsafe(GetHistoryCapacityUnsafe());
            _historyStart = 0;
            _historyCount = 0;
        }

        private void ResetEventsUnsafe()
        {
            ResizeEventBufferUnsafe(GetEventCapacityUnsafe());
            _eventStart = 0;
            _eventCount = 0;
        }

        private void ResizeHistoryBufferUnsafe(int newCapacity)
        {
            if (newCapacity < 1)
            {
                newCapacity = 1;
            }

            if (_historyBuffer.Length == newCapacity)
            {
                return;
            }

            var newBuffer = CreateHistoryBuffer(newCapacity);
            int copiedCount = Math.Min(_historyCount, newCapacity);
            int sourceStart = Math.Max(0, _historyCount - copiedCount);
            for (int i = 0; i < copiedCount; i++)
            {
                newBuffer[i].CopyFrom(GetHistoryFrameUnsafe(sourceStart + i));
            }

            _historyBuffer = newBuffer;
            _historyStart = 0;
            _historyCount = copiedCount;
        }

        private void ResizeEventBufferUnsafe(int newCapacity)
        {
            if (newCapacity < 1)
            {
                newCapacity = 1;
            }

            if (_eventBuffer.Length == newCapacity)
            {
                return;
            }

            var newBuffer = new EventLogItem[newCapacity];
            int copiedCount = Math.Min(_eventCount, newCapacity);
            int sourceStart = Math.Max(0, _eventCount - copiedCount);
            for (int i = 0; i < copiedCount; i++)
            {
                newBuffer[i] = GetEventUnsafe(sourceStart + i);
            }

            _eventBuffer = newBuffer;
            _eventStart = 0;
            _eventCount = copiedCount;
        }

        private void AppendHistoryFrameUnsafe(TelemetryState frame)
        {
            if (_historyBuffer.Length == 0)
            {
                _historyBuffer = CreateHistoryBuffer(GetHistoryCapacityUnsafe());
            }

            if (_historyCount < _historyBuffer.Length)
            {
                int writeIndex = (_historyStart + _historyCount) % _historyBuffer.Length;
                _historyBuffer[writeIndex].CopyFrom(frame);
                _historyCount++;
                return;
            }

            _historyBuffer[_historyStart].CopyFrom(frame);
            _historyStart = (_historyStart + 1) % _historyBuffer.Length;
        }

        private void AppendEventUnsafe(EventLogItem item)
        {
            if (_eventBuffer.Length == 0)
            {
                _eventBuffer = new EventLogItem[GetEventCapacityUnsafe()];
            }

            if (_eventCount < _eventBuffer.Length)
            {
                int writeIndex = (_eventStart + _eventCount) % _eventBuffer.Length;
                _eventBuffer[writeIndex] = item;
                _eventCount++;
                return;
            }

            _eventBuffer[_eventStart] = item;
            _eventStart = (_eventStart + 1) % _eventBuffer.Length;
        }

        private TelemetryState GetHistoryFrameUnsafe(int logicalIndex)
        {
            int physicalIndex = (_historyStart + logicalIndex) % _historyBuffer.Length;
            return _historyBuffer[physicalIndex];
        }

        private EventLogItem GetEventUnsafe(int logicalIndex)
        {
            int physicalIndex = (_eventStart + logicalIndex) % _eventBuffer.Length;
            return _eventBuffer[physicalIndex];
        }

        private EventLogItem GetLatestEventUnsafe()
        {
            return GetEventUnsafe(_eventCount - 1);
        }

        private void TrimEventsUnsafe()
        {
            int max = GetEventCapacityUnsafe();
            while (_eventCount > max)
            {
                _eventStart = (_eventStart + 1) % _eventBuffer.Length;
                _eventCount--;
            }
        }

        private static TelemetryState[] CreateHistoryBuffer(int capacity)
        {
            var buffer = new TelemetryState[capacity];
            for (int i = 0; i < capacity; i++)
            {
                buffer[i] = new TelemetryState();
            }

            return buffer;
        }

        private static IPedalInputSource CreateInputSource(PedalConfig config)
        {
            return config.InputMode == InputMode.Hardware
                ? new WinMmPedalInputSource(config)
                : new SimulationPedalInputSource(config);
        }

        private static string EscapeCsv(string value)
        {
            if (value.Contains('"') || value.Contains(',') || value.Contains('\n'))
            {
                return $"\"{value.Replace("\"", "\"\"")}\"";
            }

            return value;
        }

        private static void ApplyProcessSettings(PedalConfig config)
        {
            try
            {
                Process process = Process.GetCurrentProcess();
                if (config.Idle)
                {
                    process.PriorityClass = ProcessPriorityClass.Idle;
                }
                else if (config.BelowNormal)
                {
                    process.PriorityClass = ProcessPriorityClass.BelowNormal;
                }

                if (!string.IsNullOrWhiteSpace(config.AffinityMask))
                {
                    string text = config.AffinityMask.Trim();
                    ulong mask = text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                        ? ulong.Parse(text[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture)
                        : ulong.Parse(text, CultureInfo.InvariantCulture);
                    if (mask != 0)
                    {
                        process.ProcessorAffinity = (IntPtr)(long)mask;
                    }
                }
            }
            catch
            {
            }
        }
    }
}
