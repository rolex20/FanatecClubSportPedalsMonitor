using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PedDash.Models;
using PedDash.Pages;
using PedDash.Services;
using System;
using System.Globalization;

namespace PedDash
{
    public sealed partial class MainWindow : Window
    {
        private sealed class MetricTextCache
        {
            private readonly string _format;
            private readonly CultureInfo _culture;
            private readonly int _width;
            private readonly string _suffix;
            private readonly int _scale;
            private int? _lastKey;
            private string _cachedText = string.Empty;

            public MetricTextCache(string format, CultureInfo culture, int width, string suffix, int decimals)
            {
                _format = format;
                _culture = culture;
                _width = width;
                _suffix = suffix;
                _scale = decimals switch
                {
                    0 => 1,
                    1 => 10,
                    2 => 100,
                    3 => 1000,
                    _ => (int)Math.Pow(10, decimals)
                };
            }

            public string Format(double value)
            {
                double rounded = Math.Round(value, _scale == 1 ? 0 : (int)Math.Log10(_scale), MidpointRounding.ToEven);
                int key = (int)Math.Round(rounded * _scale, 0, MidpointRounding.ToEven);
                if (_lastKey != key)
                {
                    _lastKey = key;
                    _cachedText = $"{rounded.ToString(_format, _culture)}{_suffix}".PadLeft(_width);
                }

                return _cachedText;
            }
        }

        public static PedalRuntimeService Runtime { get; } = new PedalRuntimeService();
        public static MainWindow? Instance { get; private set; }

        private readonly object _frameGate = new();
        private uint _pendingPaintSeq;
        private TelemetryState? _pendingFrame;
        private bool _frameUpdateQueued;
        private readonly MetricTextCache _lagTotalText = new("F0", CultureInfo.CurrentCulture, 7, " ms", 0);
        private readonly MetricTextCache _tickPeriodText = new("F1", CultureInfo.InvariantCulture, 6, string.Empty, 1);
        private readonly MetricTextCache _readText = new("F1", CultureInfo.InvariantCulture, 6, string.Empty, 1);
        private readonly MetricTextCache _computeText = new("F1", CultureInfo.InvariantCulture, 6, string.Empty, 1);
        private readonly MetricTextCache _paintText = new("F1", CultureInfo.InvariantCulture, 6, string.Empty, 1);

        public MainWindow()
        {
            InitializeComponent();
            Instance = this;

            ExtendsContentIntoTitleBar = true;
            SetTitleBar(null);

            Runtime.OnFrameReady += Runtime_OnFrameReady;
            CompositionTarget.Rendering += CompositionTarget_Rendering;
            Closed += MainWindow_Closed;
            Runtime.Start(App.LaunchOptions.ConfigPath);

            NavButton_Click(NavRacing, new RoutedEventArgs());
        }

        private void Runtime_OnFrameReady(TelemetryState frame)
        {
            if (frame.TickToPaintMs <= 0)
            {
                _pendingPaintSeq = frame.SeqId;
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

                SetText(RunLagTotal, _lagTotalText.Format(frame.TickToPaintMs > 0 ? frame.TickToPaintMs : frame.TickPeriodMs));
                SetText(RunTickPeriod, _tickPeriodText.Format(frame.TickPeriodMs));
                SetText(RunRead, _readText.Format(frame.ReadMs));
                SetText(RunCompute, _computeText.Format(frame.ComputeMs));
                SetText(RunPaint, _paintText.Format(frame.TickToPaintMs));
                SetVisibility(DiscPill, frame.ControllerDisconnected ? Visibility.Visible : Visibility.Collapsed);
            }
        }

        private void NavButton_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button btn)
            {
                return;
            }

            foreach (var child in NavPanel.Children)
            {
                if (child is not Button button)
                {
                    continue;
                }

                button.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 224, 224, 224));
                button.BorderBrush = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
            }

            btn.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0, 243, 255));
            btn.BorderBrush = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0, 243, 255));

            string target = btn.CommandParameter?.ToString() ?? string.Empty;
            switch (target)
            {
                case "Racing":
                    ContentFrame.Navigate(typeof(RacingPage));
                    break;
                case "Lag":
                    ContentFrame.Navigate(typeof(LagPage));
                    break;
                case "Signals":
                    ContentFrame.Navigate(typeof(SignalsPage));
                    break;
                case "DataMap":
                    ContentFrame.Navigate(typeof(DataMapPage));
                    break;
                case "Config":
                    ContentFrame.Navigate(typeof(ConfigPage));
                    break;
            }
        }

        private void Latency_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
        {
            if (sender is FrameworkElement element)
            {
                Microsoft.UI.Xaml.Controls.Primitives.FlyoutBase.ShowAttachedFlyout(element);
            }
        }

        private void CompositionTarget_Rendering(object? sender, object e)
        {
            if (_pendingPaintSeq == 0)
            {
                return;
            }

            Runtime.ReportPaint(_pendingPaintSeq);
            _pendingPaintSeq = 0;
        }

        private void MainWindow_Closed(object sender, WindowEventArgs args)
        {
            CompositionTarget.Rendering -= CompositionTarget_Rendering;
            Runtime.OnFrameReady -= Runtime_OnFrameReady;
            Runtime.Stop();
            App.ReleaseSingleInstanceGuard();
        }

        private static void SetText(TextBlock block, string value)
        {
            if (block.Text != value)
            {
                block.Text = value;
            }
        }

        private static void SetVisibility(UIElement element, Visibility visibility)
        {
            if (element.Visibility != visibility)
            {
                element.Visibility = visibility;
            }
        }
    }
}
