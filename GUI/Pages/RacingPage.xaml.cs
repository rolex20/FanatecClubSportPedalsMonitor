using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PedDash.Models;
using System.Linq;

namespace PedDash.Pages
{
    public sealed partial class RacingPage : Page
    {
        private sealed class PillBrushSet
        {
            public PillBrushSet(Windows.UI.Color neonColor)
            {
                ActiveBackground = new SolidColorBrush(ColorHelper.FromArgb(51, neonColor.R, neonColor.G, neonColor.B));
                ActiveBorder = new SolidColorBrush(neonColor);
                ActiveForeground = new SolidColorBrush(neonColor);
            }

            public SolidColorBrush ActiveBackground { get; }
            public SolidColorBrush ActiveBorder { get; }
            public SolidColorBrush ActiveForeground { get; }
        }

        private static readonly SolidColorBrush InactiveBackgroundBrush = new(ColorHelper.FromArgb(255, 34, 34, 34));
        private static readonly SolidColorBrush InactiveBorderBrush = new(ColorHelper.FromArgb(255, 34, 34, 34));
        private static readonly SolidColorBrush InactiveForegroundBrush = new(ColorHelper.FromArgb(255, 85, 85, 85));

        private readonly object _frameGate = new();
        private TelemetryState? _pendingFrame;
        private bool _frameUpdateQueued;
        private readonly PillBrushSet _driftBrushes = new(ColorHelper.FromArgb(255, 255, 51, 51));
        private readonly PillBrushSet _noiseBrushes = new(ColorHelper.FromArgb(255, 255, 191, 0));
        private readonly PillBrushSet _autoBrushes = new(ColorHelper.FromArgb(255, 0, 243, 255));
        private readonly PillBrushSet _racingBrushes = new(ColorHelper.FromArgb(255, 57, 255, 20));
        private bool? _driftActive;
        private bool? _noiseActive;
        private bool? _autoActive;
        private bool? _racingActive;

        public RacingPage()
        {
            InitializeComponent();
            Loaded += RacingPage_Loaded;
            Unloaded += RacingPage_Unloaded;
        }

        private void RacingPage_Loaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady += Runtime_OnFrameReady;
            MainWindow.Runtime.OnEventLogged += Runtime_OnEventLogged;

            LvEvents.Items.Clear();
            foreach (EventLogItem item in MainWindow.Runtime.Events.Reverse())
            {
                LvEvents.Items.Insert(0, CreateEventRow(item));
            }
        }

        private void RacingPage_Unloaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady -= Runtime_OnFrameReady;
            MainWindow.Runtime.OnEventLogged -= Runtime_OnEventLogged;
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

                GaugeGas.PhysicalValue = frame.GasPhysicalPct;
                GaugeGas.LogicalValue = frame.GasLogicalPct;

                GaugeBrake.PhysicalValue = frame.BrakePhysicalPct;
                GaugeBrake.LogicalValue = frame.BrakeLogicalPct;

                GaugeClutch.PhysicalValue = frame.ClutchPhysicalPct;
                GaugeClutch.LogicalValue = frame.ClutchLogicalPct;

                UpdatePill(PillDrift, _driftBrushes, frame.GasAlertTriggered, ref _driftActive);
                UpdatePill(PillNoise, _noiseBrushes, frame.ClutchAlertTriggered, ref _noiseActive);
                UpdatePill(PillAuto, _autoBrushes, frame.GasAutoAdjustApplied, ref _autoActive);
                UpdatePill(PillRacing, _racingBrushes, frame.IsRacing, ref _racingActive);
            }
        }

        private void Runtime_OnEventLogged(EventLogItem item)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                LvEvents.Items.Insert(0, CreateEventRow(item));
                if (LvEvents.Items.Count > 100)
                {
                    LvEvents.Items.RemoveAt(LvEvents.Items.Count - 1);
                }
            });
        }

        private void UpdatePill(Border border, PillBrushSet brushes, bool isActive, ref bool? lastState)
        {
            if (lastState == isActive)
            {
                return;
            }

            lastState = isActive;
            if (isActive)
            {
                border.Background = brushes.ActiveBackground;
                border.BorderBrush = brushes.ActiveBorder;
                if (border.Child is TextBlock text)
                {
                    text.Foreground = brushes.ActiveForeground;
                }
            }
            else
            {
                border.Background = InactiveBackgroundBrush;
                border.BorderBrush = InactiveBorderBrush;
                if (border.Child is TextBlock text)
                {
                    text.Foreground = InactiveForegroundBrush;
                }
            }
        }

        private static StackPanel CreateEventRow(EventLogItem item)
        {
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 15,
                Margin = new Thickness(0, 2, 0, 2)
            };

            row.Children.Add(new TextBlock
            {
                Text = item.Time,
                Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 85, 85, 85)),
                FontFamily = new FontFamily("Consolas"),
                Width = 100
            });

            row.Children.Add(new Border
            {
                Background = new SolidColorBrush(item.TypeColor),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(6, 2, 6, 2),
                Child = new TextBlock
                {
                    Text = item.Type,
                    Foreground = new SolidColorBrush(Colors.Black),
                    FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                    FontSize = 11
                }
            });

            row.Children.Add(new TextBlock
            {
                Text = item.Details,
                Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 204, 204, 204)),
                FontFamily = new FontFamily("Consolas")
            });

            return row;
        }
    }
}
