using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System;
using System.Numerics;

namespace PedDash.Controls
{
    public sealed partial class Win2DGaugeControl : UserControl
    {
        public static readonly DependencyProperty PhysicalValueProperty =
            DependencyProperty.Register("PhysicalValue", typeof(double), typeof(Win2DGaugeControl), new PropertyMetadata(0.0, OnPhysicalValueChanged));

        public static readonly DependencyProperty LogicalValueProperty =
            DependencyProperty.Register("LogicalValue", typeof(double), typeof(Win2DGaugeControl), new PropertyMetadata(0.0, OnLogicalValueChanged));

        public static readonly DependencyProperty LabelProperty =
            DependencyProperty.Register("Label", typeof(string), typeof(Win2DGaugeControl), new PropertyMetadata("", OnLabelChanged));

        public static readonly DependencyProperty AccentColorProperty =
            DependencyProperty.Register("AccentColor", typeof(Windows.UI.Color), typeof(Win2DGaugeControl), new PropertyMetadata(Colors.White, OnAccentColorChanged));

        private const double SettleEpsilon = 0.05;
        private readonly GaussianBlurEffect _glowEffect = new() { BlurAmount = 15f };

        private double _physicalValue;
        private double _logicalValue;
        private string _label = string.Empty;
        private Windows.UI.Color _accentColor = Colors.White;

        private double _dispPhys;
        private double _dispLog;

        private CanvasTextFormat _labelFormat = null!;
        private CanvasTextFormat _valueFormat = null!;
        private CanvasTextFormat _physFormat = null!;
        private CanvasTextFormat _logFormat = null!;
        private CanvasStrokeStyle _roundStrokeStyle = null!;
        private CanvasLinearGradientBrush? _physicalGradientBrush;
        private CanvasCommandList? _staticLayer;

        private float _lastWidth = -1f;
        private float _lastHeight = -1f;
        private bool _staticResourcesDirty = true;
        private bool _pauseAfterDraw;

        public Win2DGaugeControl()
        {
            this.InitializeComponent();
            Canvas.SizeChanged += Canvas_SizeChanged;
            Loaded += Win2DGaugeControl_Loaded;
            Unloaded += Win2DGaugeControl_Unloaded;
        }

        public double PhysicalValue
        {
            get => (double)GetValue(PhysicalValueProperty);
            set => SetValue(PhysicalValueProperty, value);
        }

        public double LogicalValue
        {
            get => (double)GetValue(LogicalValueProperty);
            set => SetValue(LogicalValueProperty, value);
        }

        public string Label
        {
            get => (string)GetValue(LabelProperty);
            set => SetValue(LabelProperty, value);
        }

        public Windows.UI.Color AccentColor
        {
            get => (Windows.UI.Color)GetValue(AccentColorProperty);
            set => SetValue(AccentColorProperty, value);
        }

        private static void OnPhysicalValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is not Win2DGaugeControl ctrl)
            {
                return;
            }

            double next = (double)e.NewValue;
            if (ctrl._physicalValue == next)
            {
                return;
            }

            ctrl._physicalValue = next;
            ctrl.ResumeAnimatedDrawing();
        }

        private static void OnLogicalValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is not Win2DGaugeControl ctrl)
            {
                return;
            }

            double next = (double)e.NewValue;
            if (ctrl._logicalValue == next)
            {
                return;
            }

            ctrl._logicalValue = next;
            ctrl.ResumeAnimatedDrawing();
        }

        private static void OnLabelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is not Win2DGaugeControl ctrl)
            {
                return;
            }

            string next = (string)e.NewValue;
            if (string.Equals(ctrl._label, next, StringComparison.Ordinal))
            {
                return;
            }

            ctrl._label = next;
            ctrl.MarkStaticResourcesDirty();
        }

        private static void OnAccentColorChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is not Win2DGaugeControl ctrl)
            {
                return;
            }

            Windows.UI.Color next = (Windows.UI.Color)e.NewValue;
            if (ctrl._accentColor == next)
            {
                return;
            }

            ctrl._accentColor = next;
            ctrl.ResumeAnimatedDrawing();
        }

        private void Win2DGaugeControl_Loaded(object sender, RoutedEventArgs e)
        {
            ResumeAnimatedDrawing();
        }

        private void Win2DGaugeControl_Unloaded(object sender, RoutedEventArgs e)
        {
            Canvas.Paused = true;
            DisposeDeviceResources();
        }

        private void Canvas_CreateResources(CanvasAnimatedControl sender, CanvasCreateResourcesEventArgs args)
        {
            _labelFormat = new CanvasTextFormat
            {
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                FontFamily = "Arial, sans-serif",
                HorizontalAlignment = CanvasHorizontalAlignment.Center,
                VerticalAlignment = CanvasVerticalAlignment.Center
            };

            _valueFormat = new CanvasTextFormat
            {
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                FontFamily = "Consolas",
                HorizontalAlignment = CanvasHorizontalAlignment.Center,
                VerticalAlignment = CanvasVerticalAlignment.Center
            };

            _physFormat = new CanvasTextFormat
            {
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                FontFamily = "Consolas",
                HorizontalAlignment = CanvasHorizontalAlignment.Right,
                VerticalAlignment = CanvasVerticalAlignment.Center
            };

            _logFormat = new CanvasTextFormat
            {
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                FontFamily = "Consolas",
                HorizontalAlignment = CanvasHorizontalAlignment.Left,
                VerticalAlignment = CanvasVerticalAlignment.Center
            };

            _roundStrokeStyle = new CanvasStrokeStyle
            {
                StartCap = CanvasCapStyle.Round,
                EndCap = CanvasCapStyle.Round,
                DashCap = CanvasCapStyle.Round
            };

            RecreateDeviceResources(sender);
            _staticResourcesDirty = true;
            ResumeAnimatedDrawing();
        }

        private void Canvas_SizeChanged(object sender, SizeChangedEventArgs e)
        {
            float width = (float)e.NewSize.Width;
            float height = (float)e.NewSize.Height;
            if (Math.Abs(width - _lastWidth) < 0.5f && Math.Abs(height - _lastHeight) < 0.5f)
            {
                return;
            }

            _lastWidth = width;
            _lastHeight = height;
            MarkStaticResourcesDirty();
        }

        private void Canvas_Update(ICanvasAnimatedControl sender, CanvasAnimatedUpdateEventArgs args)
        {
            if (PedDash.MainWindow.Runtime.Config.RenderSmoothingMode == "FrameLock")
            {
                _dispPhys = _physicalValue;
                _dispLog = _logicalValue;
            }
            else
            {
                double dt = args.Timing.ElapsedTime.TotalSeconds;
                double smoothing = 15.0 * dt;
                if (smoothing > 1)
                {
                    smoothing = 1;
                }

                _dispPhys += (_physicalValue - _dispPhys) * smoothing;
                _dispLog += (_logicalValue - _dispLog) * smoothing;
            }

            SnapIfSettled(ref _dispPhys, _physicalValue);
            SnapIfSettled(ref _dispLog, _logicalValue);
            _pauseAfterDraw = IsSettled() && !_staticResourcesDirty;
        }

        private void Canvas_Draw(ICanvasAnimatedControl sender, CanvasAnimatedDrawEventArgs args)
        {
            var size = sender.Size;
            if (size.Width <= 0 || size.Height <= 0)
            {
                return;
            }

            EnsureDeviceResources(Canvas);
            UpdateSizeDependentResources(size);
            EnsureStaticLayer(Canvas, size);

            var session = args.DrawingSession;
            float cx = (float)size.Width / 2;
            float cy = (float)size.Height / 2;
            float maxR = Math.Min(cx, cy);
            float rO = maxR * 0.85f;
            float rI = maxR * 0.65f;
            float thick = maxR * 0.12f;

            if (rI <= 0)
            {
                return;
            }

            if (_staticLayer is not null)
            {
                session.DrawImage(_staticLayer);
            }

            if (_physicalGradientBrush is not null)
            {
                DrawArc(session, Canvas, cx, cy, rO, _dispPhys, _physicalGradientBrush, thick, false);
            }

            Windows.UI.Color valColor = _dispLog == 0
                ? Colors.White
                : (_dispLog >= 99 ? ColorHelper.FromArgb(255, 255, 51, 51) : ColorHelper.FromArgb(255, 57, 255, 20));

            DrawArc(session, Canvas, cx, cy, rI, _dispLog, valColor, thick, true);

            session.DrawText($"{_dispLog:F0}", cx, cy, valColor, _valueFormat);
            session.DrawText($"PHYS: {_dispPhys:F0}%", cx - (maxR * 0.05f), cy + (maxR * 0.75f), ColorHelper.FromArgb(255, 119, 119, 119), _physFormat);
            session.DrawText($"GAME: {_dispLog:F0}%", cx + (maxR * 0.05f), cy + (maxR * 0.75f), ColorHelper.FromArgb(255, 119, 119, 119), _logFormat);

            if (_pauseAfterDraw)
            {
                Canvas.Paused = true;
                _pauseAfterDraw = false;
            }
        }

        private void EnsureDeviceResources(ICanvasResourceCreator resourceCreator)
        {
            if (_physicalGradientBrush is not null)
            {
                return;
            }

            RecreateDeviceResources(resourceCreator);
        }

        private void RecreateDeviceResources(ICanvasResourceCreator resourceCreator)
        {
            DisposeDeviceResources();

            var stops = new CanvasGradientStop[]
            {
                new CanvasGradientStop { Position = 0.0f, Color = ColorHelper.FromArgb(255, 0, 243, 255) },
                new CanvasGradientStop { Position = 1.0f, Color = ColorHelper.FromArgb(255, 0, 136, 170) }
            };

            _physicalGradientBrush = new CanvasLinearGradientBrush(resourceCreator, stops);
            _staticResourcesDirty = true;
        }

        private void EnsureStaticLayer(ICanvasResourceCreator resourceCreator, Windows.Foundation.Size size)
        {
            if (!_staticResourcesDirty)
            {
                return;
            }

            _staticLayer?.Dispose();
            _staticLayer = new CanvasCommandList(resourceCreator);

            float cx = (float)size.Width / 2;
            float cy = (float)size.Height / 2;
            float maxR = Math.Min(cx, cy);
            float rO = maxR * 0.85f;
            float rI = maxR * 0.65f;
            float thick = maxR * 0.12f;
            if (rI <= 0)
            {
                return;
            }

            using (CanvasDrawingSession ds = _staticLayer.CreateDrawingSession())
            {
                DrawTrack(ds, cx, cy, rO, ColorHelper.FromArgb(255, 34, 34, 34), thick);
                DrawTrack(ds, cx, cy, rI, ColorHelper.FromArgb(255, 34, 34, 34), thick);
                ds.DrawText(_label, cx, cy + (maxR * 0.40f), ColorHelper.FromArgb(255, 119, 119, 119), _labelFormat);
            }

            _staticResourcesDirty = false;
        }

        private void UpdateSizeDependentResources(Windows.Foundation.Size size)
        {
            float cx = (float)size.Width / 2;
            float cy = (float)size.Height / 2;
            float maxR = Math.Min(cx, cy);
            if (maxR <= 0)
            {
                return;
            }

            _labelFormat.FontSize = Math.Max(10f, maxR * 0.20f);
            _valueFormat.FontSize = Math.Max(10f, maxR * 0.50f);
            _physFormat.FontSize = Math.Max(8f, maxR * 0.12f);
            _logFormat.FontSize = Math.Max(8f, maxR * 0.12f);

            if (_physicalGradientBrush is not null)
            {
                _physicalGradientBrush.StartPoint = Vector2.Zero;
                _physicalGradientBrush.EndPoint = new Vector2((float)size.Width, 0);
            }
        }

        private void DrawTrack(CanvasDrawingSession session, float cx, float cy, float radius, Windows.UI.Color color, float thickness)
        {
            float startAngle = (float)(Math.PI * 0.75);
            float sweepAngle = (float)(Math.PI * 1.5);
            using CanvasGeometry arc = CreateArcGeometry(session.Device, cx, cy, radius, startAngle, sweepAngle);
            session.DrawGeometry(arc, color, thickness, _roundStrokeStyle);
        }

        private void DrawArc(CanvasDrawingSession session, ICanvasResourceCreator resourceCreator, float cx, float cy, float radius, double percent, object brushOrColor, float thickness, bool glow)
        {
            if (percent <= 0)
            {
                return;
            }

            if (percent > 100)
            {
                percent = 100;
            }

            float startAngle = (float)(Math.PI * 0.75);
            float sweepAngle = (float)((percent / 100.0) * (Math.PI * 1.5));
            Vector2 center = new(cx, cy);

            if (glow && brushOrColor is Windows.UI.Color glowColor)
            {
                using CanvasGeometry glowArc = CreateArcGeometry(session.Device, cx, cy, radius, startAngle, sweepAngle);
                using var cl = new CanvasCommandList(resourceCreator);
                using (CanvasDrawingSession glowSession = cl.CreateDrawingSession())
                {
                    glowSession.DrawGeometry(glowArc, glowColor, thickness, _roundStrokeStyle);
                }

                _glowEffect.Source = cl;
                session.DrawImage(_glowEffect);
            }

            using CanvasGeometry arc = CreateArcGeometry(session.Device, cx, cy, radius, startAngle, sweepAngle);
            if (brushOrColor is Windows.UI.Color color)
            {
                session.DrawGeometry(arc, color, thickness, _roundStrokeStyle);
            }
            else if (brushOrColor is ICanvasBrush brush)
            {
                session.DrawGeometry(arc, brush, thickness, _roundStrokeStyle);
            }
        }

        private void MarkStaticResourcesDirty()
        {
            _staticResourcesDirty = true;
            ResumeAnimatedDrawing();
        }

        private void ResumeAnimatedDrawing()
        {
            _pauseAfterDraw = false;
            if (Canvas is null)
            {
                return;
            }

            Canvas.Paused = false;
            Canvas.Invalidate();
        }

        private void DisposeDeviceResources()
        {
            _staticLayer?.Dispose();
            _staticLayer = null;

            _physicalGradientBrush?.Dispose();
            _physicalGradientBrush = null;
        }

        private bool IsSettled()
        {
            return Math.Abs(_dispPhys - _physicalValue) <= SettleEpsilon &&
                   Math.Abs(_dispLog - _logicalValue) <= SettleEpsilon;
        }

        private static void SnapIfSettled(ref double displayed, double target)
        {
            if (Math.Abs(displayed - target) <= SettleEpsilon)
            {
                displayed = target;
            }
        }

        private static CanvasGeometry CreateArcGeometry(ICanvasResourceCreator resourceCreator, float cx, float cy, float radius, float startAngle, float sweepAngle)
        {
            var builder = new CanvasPathBuilder(resourceCreator);
            builder.BeginFigure(cx + radius * (float)Math.Cos(startAngle), cy + radius * (float)Math.Sin(startAngle));
            builder.AddArc(new Vector2(cx, cy), radius, radius, startAngle, sweepAngle);
            builder.EndFigure(CanvasFigureLoop.Open);
            return CanvasGeometry.CreatePath(builder);
        }
    }
}
