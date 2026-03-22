using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PedDash.Models;
using PedDash.Services;
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;

namespace PedDash.Pages
{
    public sealed partial class SignalsPage : Page
    {
        private const int WaveformHeightStepPercent = 10;
        private const int MinWaveformHeightPercent = 70;
        private const int MaxWaveformHeightPercent = 140;
        private const double ThreeChartBaseHeight = 220.0;
        private const double TwoChartBaseHeight = 280.0;

        private double[] _gasBuffer = Array.Empty<double>();
        private double[] _brakeBuffer = Array.Empty<double>();
        private double[] _clutchBuffer = Array.Empty<double>();
        private int _gasCount;
        private int _brakeCount;
        private int _clutchCount;
        private ulong _gasRevision;
        private ulong _brakeRevision;
        private ulong _clutchRevision;
        private int _waveformHeightPercent = 100;
        private int _lastSleepTime = -1;
        private readonly object _frameGate = new();
        private TelemetryState? _pendingFrame;
        private bool _frameUpdateQueued;

        public SignalsPage()
        {
            InitializeComponent();
            Loaded += SignalsPage_Loaded;
            Unloaded += SignalsPage_Unloaded;
        }

        private void SignalsPage_Loaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady += Runtime_OnFrameReady;
            MainWindow.Runtime.OnEventLogged += Runtime_OnEventLogged;

            PedalConfig config = MainWindow.Runtime.Config;
            _waveformHeightPercent = PedalConfig.NormalizeSignalsWaveformHeightPercent(config.SignalsWaveformHeightPercent);
            _lastSleepTime = Math.Max(1, config.SleepTime);
            UpdateWaveformHeightUi();
            ApplyChartLayout();

            LvEvents.Items.Clear();
            foreach (EventLogItem item in MainWindow.Runtime.Events.Reverse())
            {
                LvEvents.Items.Insert(0, CreateEventRow(item));
            }

            RefreshChartsFromRuntime();
        }

        private void SignalsPage_Unloaded(object sender, RoutedEventArgs e)
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
                lock (_frameGate)
                {
                    if (_pendingFrame is null)
                    {
                        _frameUpdateQueued = false;
                        return;
                    }

                    _pendingFrame = null;
                }

                RefreshChartsFromRuntime();
            }
        }

        private void Runtime_OnEventLogged(EventLogItem item)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                LvEvents.Items.Insert(0, CreateEventRow(item));
                if (LvEvents.Items.Count > 200)
                {
                    LvEvents.Items.RemoveAt(LvEvents.Items.Count - 1);
                }
            });
        }

        private static Grid CreateEventRow(EventLogItem item)
        {
            var row = new Grid
            {
                Padding = new Thickness(15, 10, 15, 10),
                BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(255, 34, 34, 34)),
                BorderThickness = new Thickness(0, 0, 0, 1)
            };

            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            row.Children.Add(new TextBlock
            {
                Text = item.Time,
                Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 119, 119, 119)),
                FontFamily = new FontFamily("Consolas"),
                Margin = new Thickness(0, 0, 1, 0) // Adds 1px of "breathing room" on the right    
            });

            var typeText = new TextBlock
            {
                Text = item.Type,
                Foreground = new SolidColorBrush(item.TypeColor),
                FontWeight = Microsoft.UI.Text.FontWeights.Bold
            };
            Grid.SetColumn(typeText, 1);
            row.Children.Add(typeText);

            var details = new TextBlock
            {
                Text = item.Details,
                Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 224, 224, 224)),
                TextWrapping = TextWrapping.Wrap
            };
            Grid.SetColumn(details, 2);
            row.Children.Add(details);

            return row;
        }

        private void TglHideBrake_Toggled(object sender, RoutedEventArgs e)
        {
            ApplyChartLayout();
        }

        private void BtnWaveHeightDown_Click(object sender, RoutedEventArgs e)
        {
            ChangeWaveformHeight(-WaveformHeightStepPercent);
        }

        private void BtnWaveHeightUp_Click(object sender, RoutedEventArgs e)
        {
            ChangeWaveformHeight(WaveformHeightStepPercent);
        }

        private void RefreshChartsFromRuntime()
        {
            SignalsSnapshotResult snapshot = MainWindow.Runtime.CopySignalsSnapshot(_gasBuffer, _brakeBuffer, _clutchBuffer);
            if (!snapshot.Copied)
            {
                EnsureBufferLength(snapshot.Count);
                snapshot = MainWindow.Runtime.CopySignalsSnapshot(_gasBuffer, _brakeBuffer, _clutchBuffer);
            }

            UpdateCharts(snapshot);
        }

        private void UpdateCharts(SignalsSnapshotResult snapshot)
        {
            int normalizedSleepTime = Math.Max(1, snapshot.SleepTime);
            bool forceRefresh = normalizedSleepTime != _lastSleepTime;
            _lastSleepTime = normalizedSleepTime;

            bool gasCountChanged = _gasCount != snapshot.Count;
            bool brakeCountChanged = _brakeCount != snapshot.Count;
            bool clutchCountChanged = _clutchCount != snapshot.Count;
            _gasCount = snapshot.Count;
            _brakeCount = snapshot.Count;
            _clutchCount = snapshot.Count;

            if (forceRefresh || gasCountChanged || snapshot.GasChanged)
            {
                _gasRevision++;
                ChartGas.SetValues(_gasBuffer, _gasCount, _gasRevision);
            }

            if (forceRefresh || brakeCountChanged || snapshot.BrakeChanged)
            {
                _brakeRevision++;
                ChartBrake.SetValues(_brakeBuffer, _brakeCount, _brakeRevision);
            }

            if (forceRefresh || clutchCountChanged || snapshot.ClutchChanged)
            {
                _clutchRevision++;
                ChartClutch.SetValues(_clutchBuffer, _clutchCount, _clutchRevision);
            }
        }

        private void EnsureBufferLength(int count)
        {
            if (_gasBuffer.Length < count)
            {
                _gasBuffer = new double[count];
            }

            if (_brakeBuffer.Length < count)
            {
                _brakeBuffer = new double[count];
            }

            if (_clutchBuffer.Length < count)
            {
                _clutchBuffer = new double[count];
            }
        }

        private void ChangeWaveformHeight(int delta)
        {
            int next = _waveformHeightPercent + delta;
            if (next < MinWaveformHeightPercent) next = MinWaveformHeightPercent;
            if (next > MaxWaveformHeightPercent) next = MaxWaveformHeightPercent;
            next = PedalConfig.NormalizeSignalsWaveformHeightPercent(next);

            if (next == _waveformHeightPercent)
            {
                UpdateWaveformHeightUi();
                return;
            }

            _waveformHeightPercent = next;
            UpdateWaveformHeightUi();
            ApplyChartLayout();

            MainWindow.Runtime.UpdateConfig(config => config.SignalsWaveformHeightPercent = _waveformHeightPercent, false);
        }

        private void UpdateWaveformHeightUi()
        {
            TxtWaveHeight.Text = $"{_waveformHeightPercent}%";
            BtnWaveHeightDown.IsEnabled = _waveformHeightPercent > MinWaveformHeightPercent;
            BtnWaveHeightUp.IsEnabled = _waveformHeightPercent < MaxWaveformHeightPercent;
        }

        private void ApplyChartLayout()
        {
            if (TglHideBrake.IsOn)
            {
                TxtBrakeTitle.Visibility = Visibility.Collapsed;
                ChartBrake.Visibility = Visibility.Collapsed;
                double height = ScaleChartHeight(TwoChartBaseHeight);
                ChartGas.Height = height;
                ChartClutch.Height = height;
            }
            else
            {
                TxtBrakeTitle.Visibility = Visibility.Visible;
                ChartBrake.Visibility = Visibility.Visible;
                double height = ScaleChartHeight(ThreeChartBaseHeight);
                ChartGas.Height = height;
                ChartBrake.Height = height;
                ChartClutch.Height = height;
            }
        }

        private double ScaleChartHeight(double baseHeight)
        {
            return Math.Round(baseHeight * (_waveformHeightPercent / 100.0), 0, MidpointRounding.AwayFromZero);
        }

        private async void ExportEvents_Click(object sender, RoutedEventArgs e)
        {
            await SaveTextAsync("events", MainWindow.Runtime.BuildEventsCsv());
        }

        private async void ExportTelemetry_Click(object sender, RoutedEventArgs e)
        {
            await SaveTextAsync("telemetry", MainWindow.Runtime.BuildTelemetryCsv());
        }

        private async System.Threading.Tasks.Task SaveTextAsync(string stem, string content)
        {
            string exportDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                "PedDashExports");
            Directory.CreateDirectory(exportDirectory);

            string fileName = $"peddash_{stem}_{DateTime.Now:yyyyMMdd_HHmmss}.csv";
            string path = Path.Combine(exportDirectory, fileName);

            await File.WriteAllTextAsync(path, content);
            Runtime_OnEventLogged(EventLogItem.Create("Info", $"Exported CSV: {path}", Microsoft.UI.Colors.DeepSkyBlue));
        }
    }
}
