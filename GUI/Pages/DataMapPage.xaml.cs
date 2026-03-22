using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PedDash.Models;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace PedDash.Pages
{
    public sealed class TeleCard : INotifyPropertyChanged
    {
        public string Title { get; set; } = string.Empty;
        public string ShortDesc { get; set; } = string.Empty;

        private string _value = "--";
        public string Value
        {
            get => _value;
            set
            {
                if (_value != value)
                {
                    _value = value;
                    OnPropertyChanged();
                }
            }
        }

        private SolidColorBrush _valueColor = new SolidColorBrush(Colors.White);
        public SolidColorBrush ValueColor
        {
            get => _valueColor;
            set
            {
                if (_valueColor.Color != value.Color)
                {
                    _valueColor = value;
                    OnPropertyChanged();
                }
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        private void OnPropertyChanged([CallerMemberName] string? name = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
    }

    public sealed class TeleGroup
    {
        public string GroupName { get; set; } = string.Empty;
        public ObservableCollection<TeleCard> Cards { get; set; } = new();
    }

    public sealed partial class DataMapPage : Page
    {
        private readonly object _frameGate = new();
        private sealed class CardDefinition
        {
            public required string Group { get; init; }
            public required string Title { get; init; }
            public required string Description { get; init; }
            public required Func<TelemetryState, string> Getter { get; init; }
            public Func<TelemetryState, Windows.UI.Color>? ColorGetter { get; init; }
            public TeleCard? Card { get; set; }

            private SolidColorBrush? _cachedBrush;
            private Windows.UI.Color _cachedColor;
            private bool _hasCachedColor;

            public string GetValue(TelemetryState frame)
            {
                return Getter(frame);
            }

            public SolidColorBrush GetBrush(TelemetryState frame)
            {
                Windows.UI.Color color = ColorGetter?.Invoke(frame) ?? Colors.White;
                if (!_hasCachedColor || _cachedBrush is null || _cachedColor != color)
                {
                    _cachedColor = color;
                    _cachedBrush = new SolidColorBrush(color);
                    _hasCachedColor = true;
                }

                return _cachedBrush;
            }
        }

        private readonly List<CardDefinition> _definitions = new();
        private TelemetryState? _pendingFrame;
        private bool _frameUpdateQueued;
        public ObservableCollection<TeleGroup> Groups { get; } = new();

        public DataMapPage()
        {
            InitializeComponent();
            DataContext = this;
            BuildDefinitions();
            SetupGroups();
            Loaded += DataMapPage_Loaded;
            Unloaded += DataMapPage_Unloaded;
        }

        private void DataMapPage_Loaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady += Runtime_OnFrameReady;
        }

        private void DataMapPage_Unloaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady -= Runtime_OnFrameReady;
        }

        private void Card_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
        {
            if (sender is FrameworkElement element)
            {
                Microsoft.UI.Xaml.Controls.Primitives.FlyoutBase.ShowAttachedFlyout(element);
            }
        }

        private void SetupGroups()
        {
            foreach (string groupName in new[]
            {
                "Pedal Metrics",
                "Raw Inputs",
                "Logic State",
                "Pedal Tuning",
                "Latency (ms)",
                "Event Flags",
                "Diagnostics"
            })
            {
                var group = new TeleGroup { GroupName = groupName };
                foreach (CardDefinition definition in _definitions)
                {
                    if (definition.Group != groupName)
                    {
                        continue;
                    }

                    definition.Card = new TeleCard
                    {
                        Title = definition.Title,
                        ShortDesc = definition.Description
                    };
                    group.Cards.Add(definition.Card);
                }

                Groups.Add(group);
            }
        }

        private void Runtime_OnFrameReady(TelemetryState frame)
        {
            if (frame.UpdateKind == TelemetryUpdateKind.Paint)
            {
                return;
            }

            bool shouldQueue = false;
            lock (_frameGate)
            {
                _pendingFrame = frame;
                if (!_frameUpdateQueued)
                {
                    _frameUpdateQueued = true;
                    shouldQueue = true;
                }
            }

            if (shouldQueue)
            {
                DispatcherQueue.TryEnqueue(ProcessPendingFrame);
            }
        }

        private void ProcessPendingFrame()
        {
            while (true)
            {
                TelemetryState? frame;
                lock (_frameGate)
                {
                    frame = _pendingFrame;
                    if (frame is null)
                    {
                        _frameUpdateQueued = false;
                        return;
                    }

                    _pendingFrame = null;
                }

                foreach (CardDefinition definition in _definitions)
                {
                    if (definition.Card is null)
                    {
                        continue;
                    }

                    definition.Card.Value = definition.GetValue(frame);
                    definition.Card.ValueColor = definition.GetBrush(frame);
                }
            }
        }

        private void BuildDefinitions()
        {
            _definitions.AddRange(new[]
            {
                DefDouble1("Pedal Metrics", "GAS PHYS %", "Raw physical percentage of gas pedal travel.", frame => frame.GasPhysicalPct),
                DefDouble1("Pedal Metrics", "GAS GAME %", "Deadzone-mapped gas percentage delivered to the game.", frame => frame.GasLogicalPct),
                DefDouble1("Pedal Metrics", "BRAKE PHYS %", "Raw physical percentage of brake travel.", frame => frame.BrakePhysicalPct),
                DefDouble1("Pedal Metrics", "BRAKE GAME %", "Deadzone-mapped brake percentage delivered to the game.", frame => frame.BrakeLogicalPct),
                DefDouble1("Pedal Metrics", "CLUTCH PHYS %", "Raw physical percentage of clutch travel.", frame => frame.ClutchPhysicalPct),
                DefDouble1("Pedal Metrics", "CLUTCH GAME %", "Deadzone-mapped clutch percentage delivered to the game.", frame => frame.ClutchLogicalPct),

                DefUInt("Raw Inputs", "GAS RAW", "Raw WinMM gas axis units.", frame => frame.RawGas),
                DefUInt("Raw Inputs", "GAS NORM", "Normalized gas axis units used by the logic.", frame => frame.GasValue),
                DefUInt("Raw Inputs", "BRAKE RAW", "Raw WinMM brake axis units.", frame => frame.RawBrake),
                DefUInt("Raw Inputs", "BRAKE NORM", "Normalized brake axis units used by the logic.", frame => frame.BrakeValue),
                DefUInt("Raw Inputs", "CLUTCH RAW", "Raw WinMM clutch axis units.", frame => frame.RawClutch),
                DefUInt("Raw Inputs", "CLUTCH NORM", "Normalized clutch axis units used by the logic.", frame => frame.ClutchValue),
                DefUInt("Raw Inputs", "AXIS MAX", "Axis resolution max used for scaling.", frame => frame.AxisMax),
                DefUInt("Raw Inputs", "JOY ID", "Current joystick/device ID.", frame => frame.JoyID),
                DefUInt("Raw Inputs", "JOY FLAGS", "WinMM JOYINFOEX flag bitmask.", frame => frame.JoyFlags),
                DefBool("Raw Inputs", "NORM FLAG", "Whether the app inverts raw axes before logic.", frame => frame.AxisNormalizationEnabled),

                DefBool("Logic State", "IS RACING", "Driving activity state machine.", frame => frame.IsRacing),
                DefUInt("Logic State", "PEAK GAS", "Highest gas value observed in the current window.", frame => frame.PeakGasInWindow),
                DefUInt("Logic State", "BEST EST %", "Suggested best gas deadzone-out percentage.", frame => frame.BestEstimatePercent),
                DefUInt("Logic State", "LAST FULL T", "TickCount when full throttle was last reached.", frame => frame.LastFullThrottleTime),
                DefUInt("Logic State", "LAST ACTIVITY", "TickCount of last gas activity.", frame => frame.LastGasActivityTime),
                DefUInt("Logic State", "NOISE REPS", "Consecutive clutch repeat counter.", frame => frame.RepeatingClutchCount),
                DefUInt("Logic State", "PCT REACHED", "Percent reached in the current drift alert window.", frame => frame.PercentReached),
                DefUInt("Logic State", "CURRENT PCT", "Current gas percent used by estimator.", frame => frame.CurrentPercent),

                DefInt("Pedal Tuning", "GAS DZ IN", "Idle deadzone threshold for gas.", frame => frame.GasDeadzoneIn),
                DefInt("Pedal Tuning", "GAS DZ OUT", "Full-travel threshold for gas.", frame => frame.GasDeadzoneOut),
                DefInt("Pedal Tuning", "EFF GAS DZ", "Current effective gas deadzone-out after any auto-adjust.", frame => frame.EffectiveGasDeadzoneOut),
                DefInt("Pedal Tuning", "BRAKE DZ IN", "Idle deadzone threshold for brake.", frame => frame.BrakeDeadzoneIn),
                DefInt("Pedal Tuning", "BRAKE DZ OUT", "Full-travel threshold for brake.", frame => frame.BrakeDeadzoneOut),
                DefInt("Pedal Tuning", "CLUTCH DZ IN", "Idle deadzone threshold for clutch.", frame => frame.ClutchDeadzoneIn),
                DefInt("Pedal Tuning", "CLUTCH DZ OUT", "Full-travel threshold for clutch.", frame => frame.ClutchDeadzoneOut),
                DefInt("Pedal Tuning", "MIN USAGE %", "Minimum gas usage needed before drift alerts matter.", frame => frame.GasMinUsagePercent),
                DefInt("Pedal Tuning", "AUTO MIN %", "Configured lower bound for auto-adjust.", frame => frame.AutoGasDeadzoneMinimum),
                DefInt("Pedal Tuning", "GAS WINDOW", "Seconds before drift alert window expires.", frame => frame.GasWindow),
                DefInt("Pedal Tuning", "GAS COOLDOWN", "Seconds between drift alerts.", frame => frame.GasCooldown),
                DefInt("Pedal Tuning", "GAS TIMEOUT", "Seconds before auto-pause when idle.", frame => frame.GasTimeout),
                DefBool("Pedal Tuning", "AUTO ADJUST", "Whether gas deadzone auto-adjust is enabled.", frame => frame.AutoGasDeadzoneEnabled),

                DefDouble1("Latency (ms)", "TICK PERIOD", "Time between runtime loop ticks.", frame => frame.TickPeriodMs, frame => frame.TickPeriodMs > 350 ? Colors.Red : Colors.White),
                DefDouble1("Latency (ms)", "READ MS", "Time spent reading hardware or simulation input.", frame => frame.ReadMs),
                DefDouble1("Latency (ms)", "COMPUTE MS", "Time spent running monitoring logic.", frame => frame.ComputeMs),
                DefDouble1("Latency (ms)", "PAINT MS", "Time from sample to painted WinUI frame.", frame => frame.TickToPaintMs),
                DefDouble1("Latency (ms)", "LOOP EXEC", "Processing time of the previous loop iteration.", frame => frame.FullLoopTimeMs),
                DefDouble1("Latency (ms)", "LOOP PROC", "Current loop processing time up to publish.", frame => frame.MetricLoopProcessMs),
                DefDouble1("Latency (ms)", "TTS SPEAK", "Time spent invoking the most recent TTS utterance.", frame => frame.MetricTtsSpeakMs),

                DefBool("Event Flags", "EVT GAS", "One-shot gas drift flag.", frame => frame.GasAlertTriggered),
                DefBool("Event Flags", "EVT CLUTCH", "One-shot clutch/rudder flag.", frame => frame.ClutchAlertTriggered),
                DefBool("Event Flags", "EVT AUTO", "One-shot auto-adjust flag.", frame => frame.GasAutoAdjustApplied),
                DefBool("Event Flags", "EVT EST", "One-shot estimator decrease flag.", frame => frame.GasEstimateDecreased),
                DefBool("Event Flags", "EVT MIN", "One-shot minimum-breach warning flag.", frame => frame.GasDeadzoneMinimumBreached),
                DefBool("Event Flags", "DISCONNECTED", "Latched controller disconnect flag.", frame => frame.ControllerDisconnected),
                DefBool("Event Flags", "RECONNECTED", "One-shot controller reconnect flag.", frame => frame.ControllerReconnected),

                DefUInt("Diagnostics", "SEQ ID", "Monotonic runtime frame sequence number.", frame => frame.SeqId),
                DefText("Diagnostics", "INPUT MODE", "Current input source mode.", frame => frame.InputModeName),
                DefText("Diagnostics", "SOURCE", "Current source/provider name.", frame => frame.SourceName),
                DefLong("Diagnostics", "SAMPLE AT", "Unix milliseconds captured at sample time.", frame => frame.SampleUnixMs),
                DefLong("Diagnostics", "ENQUEUE AT", "Unix milliseconds when the frame was published.", frame => frame.EnqueueAtUnixMs),
                DefLong("Diagnostics", "READ START", "Unix milliseconds before input read.", frame => frame.DeviceReadStartUnixMs),
                DefLong("Diagnostics", "READ DUR", "Milliseconds spent in the input read call.", frame => frame.DeviceReadDurationMs),
                DefUInt("Diagnostics", "TICKCOUNT", "Current environment tick count.", frame => frame.CurrentTickCount),
                DefInt("Diagnostics", "LAST BREACH", "Most recent estimated deadzone that fell below the configured minimum.", frame => frame.LastBreachedEstimatePercent),
                DefUInt("Diagnostics", "DISC TICK", "TickCount when the controller last disconnected.", frame => frame.LastDisconnectTimeMs),
                DefUInt("Diagnostics", "RECONN TICK", "TickCount when the controller last reconnected.", frame => frame.LastReconnectTimeMs)
            });
        }

        private static CardDefinition DefText(string group, string title, string description, Func<TelemetryState, string> getter, Func<TelemetryState, Windows.UI.Color>? colorGetter = null)
        {
            return new CardDefinition
            {
                Group = group,
                Title = title,
                Description = description,
                Getter = getter,
                ColorGetter = colorGetter
            };
        }

        private static CardDefinition DefDouble1(string group, string title, string description, Func<TelemetryState, double> getter, Func<TelemetryState, Windows.UI.Color>? colorGetter = null)
        {
            return DefText(group, title, description, CreateFixedFormatter(getter), colorGetter);
        }

        private static CardDefinition DefUInt(string group, string title, string description, Func<TelemetryState, uint> getter, Func<TelemetryState, Windows.UI.Color>? colorGetter = null)
        {
            return DefText(group, title, description, CreateUnsignedFormatter(getter), colorGetter);
        }

        private static CardDefinition DefInt(string group, string title, string description, Func<TelemetryState, int> getter, Func<TelemetryState, Windows.UI.Color>? colorGetter = null)
        {
            return DefText(group, title, description, CreateSignedFormatter(getter), colorGetter);
        }

        private static CardDefinition DefLong(string group, string title, string description, Func<TelemetryState, long> getter, Func<TelemetryState, Windows.UI.Color>? colorGetter = null)
        {
            return DefText(group, title, description, CreateLongFormatter(getter), colorGetter);
        }

        private static CardDefinition DefBool(string group, string title, string description, Func<TelemetryState, bool> getter, Func<TelemetryState, Windows.UI.Color>? colorGetter = null)
        {
            return DefText(group, title, description, frame => getter(frame) ? "1" : "0", colorGetter);
        }

        private static Func<TelemetryState, string> CreateFixedFormatter(Func<TelemetryState, double> getter)
        {
            bool hasValue = false;
            int lastBucket = 0;
            string cachedText = string.Empty;
            return frame =>
            {
                double roundedValue = Math.Round(getter(frame), 1, MidpointRounding.ToEven);
                int bucket = (int)Math.Round(roundedValue * 10, 0, MidpointRounding.ToEven);
                if (!hasValue || bucket != lastBucket)
                {
                    hasValue = true;
                    lastBucket = bucket;
                    cachedText = roundedValue.ToString("F1", CultureInfo.CurrentCulture);
                }

                return cachedText;
            };
        }

        private static Func<TelemetryState, string> CreateUnsignedFormatter(Func<TelemetryState, uint> getter)
        {
            bool hasValue = false;
            uint lastValue = 0;
            string cachedText = string.Empty;
            return frame =>
            {
                uint value = getter(frame);
                if (!hasValue || value != lastValue)
                {
                    hasValue = true;
                    lastValue = value;
                    cachedText = value.ToString(CultureInfo.CurrentCulture);
                }

                return cachedText;
            };
        }

        private static Func<TelemetryState, string> CreateSignedFormatter(Func<TelemetryState, int> getter)
        {
            bool hasValue = false;
            int lastValue = 0;
            string cachedText = string.Empty;
            return frame =>
            {
                int value = getter(frame);
                if (!hasValue || value != lastValue)
                {
                    hasValue = true;
                    lastValue = value;
                    cachedText = value.ToString(CultureInfo.CurrentCulture);
                }

                return cachedText;
            };
        }

        private static Func<TelemetryState, string> CreateLongFormatter(Func<TelemetryState, long> getter)
        {
            bool hasValue = false;
            long lastValue = 0;
            string cachedText = string.Empty;
            return frame =>
            {
                long value = getter(frame);
                if (!hasValue || value != lastValue)
                {
                    hasValue = true;
                    lastValue = value;
                    cachedText = value.ToString(CultureInfo.CurrentCulture);
                }

                return cachedText;
            };
        }
    }
}
