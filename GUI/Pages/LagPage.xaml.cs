using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PedDash.Models;
using PedDash.Services;

namespace PedDash.Pages
{
    public sealed partial class LagPage : Page
    {
        private readonly object _frameGate = new();
        private double[] _tickValues = System.Array.Empty<double>();
        private double[] _readValues = System.Array.Empty<double>();
        private double[] _computeValues = System.Array.Empty<double>();
        private double[] _paintValues = System.Array.Empty<double>();
        private TelemetryState? _pendingFrame;
        private bool _frameUpdateQueued;

        public LagPage()
        {
            InitializeComponent();
            Loaded += LagPage_Loaded;
            Unloaded += LagPage_Unloaded;
        }

        private void LagPage_Loaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady += Runtime_OnFrameReady;
        }

        private void LagPage_Unloaded(object sender, RoutedEventArgs e)
        {
            MainWindow.Runtime.OnFrameReady -= Runtime_OnFrameReady;
        }

        private void Runtime_OnFrameReady(TelemetryState frame)
        {
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

                LagSnapshotResult snapshot = MainWindow.Runtime.CopyLagSnapshot(_tickValues, _readValues, _computeValues, _paintValues);
                if (!snapshot.Copied || _tickValues.Length != snapshot.Count)
                {
                    EnsureBufferLength(snapshot.Count);
                    snapshot = MainWindow.Runtime.CopyLagSnapshot(_tickValues, _readValues, _computeValues, _paintValues);
                }

                if (snapshot.Count == 0)
                {
                    continue;
                }

                TxtLagTick.Text = $"{frame.TickPeriodMs:F1} ms";
                TxtLagRead.Text = $"{frame.ReadMs:F1} ms";
                TxtLagCompute.Text = $"{frame.ComputeMs:F1} ms";
                TxtLagPaint.Text = $"{frame.TickToPaintMs:F1} ms";

                TxtLagTickAvg.Text = $"(avg {snapshot.TickAverage:F1} ms)";
                TxtLagReadAvg.Text = $"(avg {snapshot.ReadAverage:F1} ms)";
                TxtLagComputeAvg.Text = $"(avg {snapshot.ComputeAverage:F1} ms)";
                TxtLagPaintAvg.Text = $"(avg {snapshot.PaintAverage:F1} ms)";

                double peak = snapshot.MaxLag * 1.2;
                if (peak < 10)
                {
                    peak = 10;
                }

                ChartLagTick.MaxValue = peak;
                ChartLagTick.Values = _tickValues;
                ChartLagRead.MaxValue = peak;
                ChartLagRead.Values = _readValues;
                ChartLagCompute.MaxValue = peak;
                ChartLagCompute.Values = _computeValues;
                ChartLagPaint.MaxValue = peak;
                ChartLagPaint.Values = _paintValues;
            }
        }

        private void EnsureBufferLength(int count)
        {
            if (_tickValues.Length != count)
            {
                _tickValues = new double[count];
            }

            if (_readValues.Length != count)
            {
                _readValues = new double[count];
            }

            if (_computeValues.Length != count)
            {
                _computeValues = new double[count];
            }

            if (_paintValues.Length != count)
            {
                _paintValues = new double[count];
            }
        }

        private void Card_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
        {
            if (sender is FrameworkElement element)
            {
                Microsoft.UI.Xaml.Controls.Primitives.FlyoutBase.ShowAttachedFlyout(element);
            }
        }
    }
}
