using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PedDash.Models;

namespace PedDash.Pages
{
    public sealed partial class ConfigPage : Page
    {
        private bool _isLoading;

        public ConfigPage()
        {
            InitializeComponent();
            Loaded += ConfigPage_Loaded;
        }

        private void ConfigPage_Loaded(object sender, RoutedEventArgs e)
        {
            LoadFromConfig();
        }

        private void LoadFromConfig()
        {
            _isLoading = true;

            PedalConfig config = MainWindow.Runtime.Config;
            TxtConfigPath.Text = config.ConfigPath;
            RestartBanner.Visibility = MainWindow.Runtime.RestartRequired ? Visibility.Visible : Visibility.Collapsed;

            CboInputMode.SelectedIndex = config.InputMode == InputMode.Hardware ? 1 : 0;
            TxtSleepTime.Text = config.SleepTime.ToString();
            TxtHistory.Text = config.MaxHistory.ToString();
            CboSmoothing.SelectedIndex = config.RenderSmoothingMode == "FrameLock" ? 1 : 0;
            CboRenderCap.SelectedIndex = config.RenderFpsCap switch
            {
                "10" => 1,
                "20" => 2,
                "30" => 3,
                "60" => 4,
                _ => 0
            };

            TxtJoystickId.Text = config.JoystickId.ToString();
            TxtVendorId.Text = config.VendorId;
            TxtProductId.Text = config.ProductId;
            TxtJoyFlags.Text = config.JoyFlags.ToString();
            TxtAffinityMask.Text = config.AffinityMask;
            TglAxisNorm.IsOn = config.AxisNormalizationEnabled;
            TglIdle.IsOn = config.Idle;
            TglBelowNormal.IsOn = config.BelowNormal;

            TglMonitorGas.IsOn = config.MonitorGas;
            TglEstimateGas.IsOn = config.EstimateGasDeadzone;
            TxtGasDeadzoneIn.Text = config.GasDeadzoneIn.ToString();
            TxtGasDeadzoneOut.Text = config.GasDeadzoneOut.ToString();
            TxtGasWindow.Text = config.GasWindow.ToString();
            TxtGasCooldown.Text = config.GasCooldown.ToString();
            TxtGasTimeout.Text = config.GasTimeout.ToString();
            TxtGasMinUsage.Text = config.GasMinUsage.ToString();
            TxtAutoGasMin.Text = config.AutoGasDeadzoneMin.ToString();

            TglMonitorClutch.IsOn = config.MonitorClutch;
            TglTts.IsOn = config.EffectiveTtsEnabled;
            TglTelemetry.IsOn = config.Telemetry;
            TxtBrakeDeadzoneIn.Text = config.BrakeDeadzoneIn.ToString();
            TxtBrakeDeadzoneOut.Text = config.BrakeDeadzoneOut.ToString();
            TxtClutchDeadzoneIn.Text = config.ClutchDeadzoneIn.ToString();
            TxtClutchDeadzoneOut.Text = config.ClutchDeadzoneOut.ToString();
            TxtMargin.Text = config.Margin.ToString();
            TxtClutchRepeat.Text = config.ClutchRepeat.ToString();

            TglVerbose.IsOn = config.Verbose;
            TglDebugRaw.IsOn = config.DebugRaw;
            TglNoBanner.IsOn = config.NoConsoleBanner;
            TxtIterations.Text = config.Iterations.ToString();

            _isLoading = false;
        }

        private void CboInputMode_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading)
            {
                return;
            }

            MainWindow.Runtime.UpdateConfig(config =>
            {
                config.InputMode = CboInputMode.SelectedIndex == 1 ? InputMode.Hardware : InputMode.Simulation;
            }, true);

            LoadFromConfig();
        }

        private void CboSmoothing_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading)
            {
                return;
            }

            MainWindow.Runtime.UpdateConfig(config =>
            {
                config.RenderSmoothingMode = CboSmoothing.SelectedIndex == 1 ? "FrameLock" : "SmoothConvergence";
            }, false);

            LoadFromConfig();
        }

        private void CboRenderCap_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading)
            {
                return;
            }

            MainWindow.Runtime.UpdateConfig(config =>
            {
                config.RenderFpsCap = CboRenderCap.SelectedIndex switch
                {
                    1 => "10",
                    2 => "20",
                    3 => "30",
                    4 => "60",
                    _ => "Auto"
                };
            }, false);

            LoadFromConfig();
        }

        private void SettingText_LostFocus(object sender, RoutedEventArgs e)
        {
            if (_isLoading || sender is not TextBox textBox || textBox.Tag is not string key)
            {
                return;
            }

            string value = textBox.Text.Trim();
            switch (key)
            {
                case "SleepTime":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.SleepTime = parsed, false));
                    break;
                case "MaxHistory":
                    ApplyInt(value, parsed => MainWindow.Runtime.ChangeMaxHistory(parsed));
                    break;
                case "JoystickId":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.JoystickId = parsed, true));
                    break;
                case "JoyFlags":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.JoyFlags = parsed, true));
                    break;
                case "GasDeadzoneIn":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.GasDeadzoneIn = parsed, false));
                    break;
                case "GasDeadzoneOut":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.GasDeadzoneOut = parsed, false));
                    break;
                case "GasWindow":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.GasWindow = parsed, false));
                    break;
                case "GasCooldown":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.GasCooldown = parsed, false));
                    break;
                case "GasTimeout":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.GasTimeout = parsed, false));
                    break;
                case "GasMinUsage":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.GasMinUsage = parsed, false));
                    break;
                case "AutoGasDeadzoneMin":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.AutoGasDeadzoneMin = parsed, false));
                    break;
                case "BrakeDeadzoneIn":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config =>
                    {
                        config.BrakeDeadzoneIn = parsed;
                        config.BrakeDeadzoneInExplicit = true;
                    }, false));
                    break;
                case "BrakeDeadzoneOut":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config =>
                    {
                        config.BrakeDeadzoneOut = parsed;
                        config.BrakeDeadzoneOutExplicit = true;
                    }, false));
                    break;
                case "ClutchDeadzoneIn":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config =>
                    {
                        config.ClutchDeadzoneIn = parsed;
                        config.ClutchDeadzoneInExplicit = true;
                    }, false));
                    break;
                case "ClutchDeadzoneOut":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config =>
                    {
                        config.ClutchDeadzoneOut = parsed;
                        config.ClutchDeadzoneOutExplicit = true;
                    }, false));
                    break;
                case "Margin":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.Margin = parsed, false));
                    break;
                case "ClutchRepeat":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.ClutchRepeat = parsed, false));
                    break;
                case "Iterations":
                    ApplyInt(value, parsed => MainWindow.Runtime.UpdateConfig(config => config.Iterations = parsed, false));
                    break;
                case "VendorId":
                    MainWindow.Runtime.UpdateConfig(config => config.VendorId = value, true);
                    break;
                case "ProductId":
                    MainWindow.Runtime.UpdateConfig(config => config.ProductId = value, true);
                    break;
                case "AffinityMask":
                    MainWindow.Runtime.UpdateConfig(config => config.AffinityMask = value, true);
                    break;
            }

            LoadFromConfig();
        }

        private void SettingToggle_Toggled(object sender, RoutedEventArgs e)
        {
            if (_isLoading || sender is not ToggleSwitch toggle || toggle.Tag is not string key)
            {
                return;
            }

            switch (key)
            {
                case "AxisNormalizationEnabled":
                    MainWindow.Runtime.UpdateConfig(config => config.NoAxisNormalization = !toggle.IsOn, false);
                    break;
                case "Idle":
                    MainWindow.Runtime.UpdateConfig(config => config.Idle = toggle.IsOn, true);
                    break;
                case "BelowNormal":
                    MainWindow.Runtime.UpdateConfig(config => config.BelowNormal = toggle.IsOn, true);
                    break;
                case "MonitorGas":
                    MainWindow.Runtime.UpdateConfig(config => config.MonitorGas = toggle.IsOn, false);
                    break;
                case "EstimateGasDeadzone":
                    MainWindow.Runtime.UpdateConfig(config => config.EstimateGasDeadzone = toggle.IsOn, false);
                    break;
                case "MonitorClutch":
                    MainWindow.Runtime.UpdateConfig(config => config.MonitorClutch = toggle.IsOn, false);
                    break;
                case "EffectiveTts":
                    MainWindow.Runtime.UpdateConfig(config =>
                    {
                        config.Tts = toggle.IsOn;
                        config.NoTts = !toggle.IsOn;
                    }, false);
                    break;
                case "Telemetry":
                    MainWindow.Runtime.UpdateConfig(config => config.Telemetry = toggle.IsOn, false);
                    break;
                case "Verbose":
                    MainWindow.Runtime.UpdateConfig(config => config.Verbose = toggle.IsOn, false);
                    break;
                case "DebugRaw":
                    MainWindow.Runtime.UpdateConfig(config => config.DebugRaw = toggle.IsOn, false);
                    break;
                case "NoConsoleBanner":
                    MainWindow.Runtime.UpdateConfig(config => config.NoConsoleBanner = toggle.IsOn, false);
                    break;
            }

            LoadFromConfig();
        }

        private static void ApplyInt(string value, System.Action<int> apply)
        {
            if (int.TryParse(value, out int parsed))
            {
                apply(parsed);
            }
        }
    }
}
