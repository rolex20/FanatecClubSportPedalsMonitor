using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas;
using Microsoft.UI;
using System;

namespace PedDash.Controls
{
    public sealed partial class Win2DChartControl : UserControl
    {
        public static readonly DependencyProperty ValuesProperty =
            DependencyProperty.Register("Values", typeof(double[]), typeof(Win2DChartControl), new PropertyMetadata(null, OnInvalidate));

        public static readonly DependencyProperty LineColorProperty =
            DependencyProperty.Register("LineColor", typeof(Windows.UI.Color), typeof(Win2DChartControl), new PropertyMetadata(Colors.White, OnInvalidate));

        public static readonly DependencyProperty MaxValueProperty =
            DependencyProperty.Register("MaxValue", typeof(double), typeof(Win2DChartControl), new PropertyMetadata(100.0, OnInvalidate));

        public static readonly DependencyProperty FillAreaProperty =
            DependencyProperty.Register("FillArea", typeof(bool), typeof(Win2DChartControl), new PropertyMetadata(false, OnInvalidate));

        public double[] Values
        {
            get => (double[])GetValue(ValuesProperty);
            set => SetValue(ValuesProperty, value);
        }

        public Windows.UI.Color LineColor
        {
            get => (Windows.UI.Color)GetValue(LineColorProperty);
            set => SetValue(LineColorProperty, value);
        }

        public double MaxValue
        {
            get => (double)GetValue(MaxValueProperty);
            set => SetValue(MaxValueProperty, value);
        }

        public bool FillArea
        {
            get => (bool)GetValue(FillAreaProperty);
            set => SetValue(FillAreaProperty, value);
        }

        private readonly CanvasTextFormat _textFormatY;
        private readonly CanvasTextFormat _textFormatX;
        private readonly CanvasStrokeStyle _strokeStyle;
        private double[]? _buffer;
        private int _bufferCount;
        private ulong _bufferRevision;
        private ulong _fallbackRevision;
        private CanvasDevice? _cachedDevice;
        private CanvasGeometry? _cachedGeometry;
        private CanvasCommandList? _cachedGlowSource;
        private GaussianBlurEffect? _cachedGlowEffect;
        private ulong _cachedGeometryRevision = ulong.MaxValue;
        private int _cachedGeometryCount = -1;
        private float _cachedGeometryWidth = -1f;
        private float _cachedGeometryHeight = -1f;
        private double _cachedGeometryMaxValue = double.NaN;
        private bool _cachedGeometryFillArea;
        private Windows.UI.Color _cachedGlowColor;
        private bool _hasCachedGlowColor;
        private float _lastWidth = -1f;
        private float _lastHeight = -1f;

        public Win2DChartControl()
        {
            this.InitializeComponent();
            _textFormatY = new CanvasTextFormat
            {
                FontSize = 12,
                FontFamily = "Consolas",
                HorizontalAlignment = CanvasHorizontalAlignment.Right,
                VerticalAlignment = CanvasVerticalAlignment.Center
            };

            _textFormatX = new CanvasTextFormat
            {
                FontSize = 12,
                FontFamily = "Consolas",
                HorizontalAlignment = CanvasHorizontalAlignment.Center,
                VerticalAlignment = CanvasVerticalAlignment.Top
            };

            _strokeStyle = new CanvasStrokeStyle
            {
                StartCap = CanvasCapStyle.Round,
                EndCap = CanvasCapStyle.Round,
                LineJoin = CanvasLineJoin.Round
            };

            Canvas.SizeChanged += Canvas_SizeChanged;
            Unloaded += Win2DChartControl_Unloaded;
        }

        private static void OnInvalidate(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is Win2DChartControl self)
            {
                self.OnPropertyInvalidated(e);
            }
        }

        public void SetValues(double[]? values, int count, ulong revision)
        {
            int normalizedCount = values is null ? 0 : Math.Min(count, values.Length);
            if (ReferenceEquals(_buffer, values) && _bufferCount == normalizedCount && _bufferRevision == revision)
            {
                return;
            }

            _buffer = values;
            _bufferCount = normalizedCount;
            _bufferRevision = revision;
            Canvas.Invalidate();
        }

        private void OnPropertyInvalidated(DependencyPropertyChangedEventArgs e)
        {
            if (e.Property == ValuesProperty)
            {
                _fallbackRevision++;
                SetValues((double[]?)e.NewValue, ((double[]?)e.NewValue)?.Length ?? 0, _fallbackRevision);
                return;
            }

            if (Equals(e.OldValue, e.NewValue))
            {
                return;
            }

            if (e.Property == MaxValueProperty || e.Property == FillAreaProperty)
            {
                InvalidateGeometryCache();
            }
            else if (e.Property == LineColorProperty)
            {
                InvalidateGlowCache();
            }

            Canvas.Invalidate();
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
            Canvas.Invalidate();
        }

        private void Win2DChartControl_Unloaded(object sender, RoutedEventArgs e)
        {
            DisposeCachedResources();
        }

        private void Canvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
        {
            double[]? vals = _buffer ?? Values;
            int count = _buffer is not null ? _bufferCount : vals?.Length ?? 0;
            if (vals == null || count < 2) return;

            var session = args.DrawingSession;
            var size = sender.Size;
            float w = (float)size.Width;
            float h = (float)size.Height;

            // HTML layout paddings
            float pL = 40f;
            float pR = 10f;
            float pT = 10f;
            float pB = 30f;

            if (w <= pL + pR || h <= pT + pB || MaxValue <= 0)
            {
                return;
            }

            for (int i = 0; i <= 4; i++)
            {
                float v = (float)MaxValue * (i / 4f);
                float y = h - pB - ((v / (float)MaxValue) * (h - pT - pB));

                // Draw horizontal grid line
                session.DrawLine(pL, y, w - pR, y, ColorHelper.FromArgb(255, 85, 85, 85), 1f);
                
                // Draw Y label
                session.DrawText(v.ToString("F0"), pL - 5, y, ColorHelper.FromArgb(255, 85, 85, 85), _textFormatY);
            }

            float totalSeconds = (float)((count * Math.Max(1, PedDash.MainWindow.Runtime.Config.SleepTime)) / 1000.0);
            for (int i = 0; i < 5; i++)
            {
                float x = pL + ((count - 1) * (i / 4f) / (count - 1)) * (w - pL - pR);
                float s = totalSeconds * (1 - (i / 4f));
                
                string label = s == 0 ? "Now" : $"-{s:F0}s";
                session.DrawText(label, x, h - pB + 8, ColorHelper.FromArgb(255, 85, 85, 85), _textFormatX);
                session.DrawLine(x, h - pB, x, h - pB + 5, ColorHelper.FromArgb(255, 34, 34, 34), 1f);
            }

            EnsureCachedDrawResources(sender, vals, count, w, h, pL, pR, pT, pB);
            if (_cachedGeometry is null)
            {
                return;
            }

            if (FillArea)
            {
                var color = LineColor;
                session.FillGeometry(_cachedGeometry, Windows.UI.Color.FromArgb(50, color.R, color.G, color.B));
            }

            if (_cachedGlowEffect is not null)
            {
                session.DrawImage(_cachedGlowEffect);
            }

            session.DrawGeometry(_cachedGeometry, LineColor, 2f, _strokeStyle);
        }

        private void EnsureCachedDrawResources(CanvasControl sender, double[] values, int count, float width, float height, float paddingLeft, float paddingRight, float paddingTop, float paddingBottom)
        {
            if (!ReferenceEquals(_cachedDevice, sender.Device))
            {
                DisposeCachedResources();
                _cachedDevice = sender.Device;
            }

            bool geometryChanged =
                _cachedGeometry is null ||
                _cachedGeometryRevision != _bufferRevision ||
                _cachedGeometryCount != count ||
                Math.Abs(_cachedGeometryWidth - width) >= 0.5f ||
                Math.Abs(_cachedGeometryHeight - height) >= 0.5f ||
                Math.Abs(_cachedGeometryMaxValue - MaxValue) > double.Epsilon ||
                _cachedGeometryFillArea != FillArea;

            if (geometryChanged)
            {
                RebuildGeometry(sender, values, count, width, height, paddingLeft, paddingRight, paddingTop, paddingBottom);
                InvalidateGlowCache();
                _cachedGeometryRevision = _bufferRevision;
                _cachedGeometryCount = count;
                _cachedGeometryWidth = width;
                _cachedGeometryHeight = height;
                _cachedGeometryMaxValue = MaxValue;
                _cachedGeometryFillArea = FillArea;
            }

            bool glowChanged =
                geometryChanged ||
                _cachedGlowSource is null ||
                _cachedGlowEffect is null ||
                !_hasCachedGlowColor ||
                _cachedGlowColor != LineColor;

            if (glowChanged && _cachedGeometry is not null)
            {
                RebuildGlow(sender);
            }
        }

        private void RebuildGeometry(CanvasControl sender, double[] values, int count, float width, float height, float paddingLeft, float paddingRight, float paddingTop, float paddingBottom)
        {
            using var builder = new CanvasPathBuilder(sender.Device);
            float firstY = 0f;
            float lastX = 0f;
            float lastY = 0f;

            for (int i = 0; i < count; i++)
            {
                float x = paddingLeft + ((float)i / (count - 1)) * (width - paddingLeft - paddingRight);
                double value = values[i];
                if (value > MaxValue) value = MaxValue;
                if (value < 0) value = 0;

                float y = height - paddingBottom - (float)((value / MaxValue) * (height - paddingTop - paddingBottom));
                if (i == 0)
                {
                    firstY = y;
                    builder.BeginFigure(x, y);
                }
                else
                {
                    builder.AddLine(x, y);
                }

                lastX = x;
                lastY = y;
            }

            if (FillArea)
            {
                builder.AddLine(lastX, height - paddingBottom);
                builder.AddLine(paddingLeft, height - paddingBottom);
                builder.AddLine(paddingLeft, firstY);
                builder.EndFigure(CanvasFigureLoop.Closed);
            }
            else
            {
                builder.EndFigure(CanvasFigureLoop.Open);
            }

            _cachedGeometry?.Dispose();
            _cachedGeometry = CanvasGeometry.CreatePath(builder);
        }

        private void RebuildGlow(CanvasControl sender)
        {
            if (_cachedGeometry is null)
            {
                return;
            }

            _cachedGlowSource?.Dispose();
            _cachedGlowSource = new CanvasCommandList(sender);
            using (CanvasDrawingSession ds = _cachedGlowSource.CreateDrawingSession())
            {
                ds.DrawGeometry(_cachedGeometry, LineColor, 2f, _strokeStyle);
            }

            _cachedGlowEffect = new GaussianBlurEffect
            {
                Source = _cachedGlowSource,
                BlurAmount = 4f
            };
            _cachedGlowColor = LineColor;
            _hasCachedGlowColor = true;
        }

        private void InvalidateGeometryCache()
        {
            _cachedGeometryRevision = ulong.MaxValue;
            _cachedGeometryCount = -1;
            _cachedGeometryWidth = -1f;
            _cachedGeometryHeight = -1f;
            _cachedGeometryMaxValue = double.NaN;
            _cachedGeometryFillArea = false;
            _cachedGeometry?.Dispose();
            _cachedGeometry = null;
            InvalidateGlowCache();
        }

        private void InvalidateGlowCache()
        {
            _cachedGlowSource?.Dispose();
            _cachedGlowSource = null;
            _cachedGlowEffect = null;
            _hasCachedGlowColor = false;
        }

        private void DisposeCachedResources()
        {
            InvalidateGeometryCache();
            _cachedDevice = null;
        }
    }
}
