using Microsoft.UI.Xaml;
using System;
using System.Runtime.InteropServices;
using System.Speech.Synthesis;
using System.Threading;
using PedDash.Services;

namespace PedDash
{
    public partial class App : Application
    {
        private const string SingleInstanceMutexName = "fanatec_monitor_single_instance_mutex";
        private const string DuplicateInstanceMessage = "Another Fanatec monitor instance is already running. Closing this copy now.";

        public static AppLaunchOptions LaunchOptions { get; private set; } = new AppLaunchOptions();
        public static MainWindow? MainAppWindow { get; private set; }

        private static Mutex? _singleInstanceMutex;
        private Window? _window;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW")]
        private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxTimeoutW", SetLastError = true)]
        private static extern int MessageBoxTimeout(IntPtr hWnd, string text, string caption, uint type, short languageId, int milliseconds);

        public App()
        {
            InitializeComponent();
        }

        protected override void OnLaunched(LaunchActivatedEventArgs args)
        {
            LaunchOptions = AppLaunchOptions.Parse(Environment.GetCommandLineArgs());
            if (!TryAcquireSingleInstanceGuard())
            {
                NotifyDuplicateInstanceAndExit();
                return;
            }

            MainAppWindow = new MainWindow();
            _window = MainAppWindow;
            _window.Activate();
        }

        public static void ReleaseSingleInstanceGuard()
        {
            try
            {
                _singleInstanceMutex?.ReleaseMutex();
            }
            catch
            {
            }

            _singleInstanceMutex?.Dispose();
            _singleInstanceMutex = null;
        }

        private static bool TryAcquireSingleInstanceGuard()
        {
            try
            {
                _singleInstanceMutex = new Mutex(true, SingleInstanceMutexName, out bool createdNew);
                return createdNew;
            }
            catch
            {
                return true;
            }
        }

        private static void NotifyDuplicateInstanceAndExit()
        {
            try
            {
                using var synth = new SpeechSynthesizer();
                synth.SelectVoiceByHints(VoiceGender.Female);
                synth.Speak(DuplicateInstanceMessage);
            }
            catch
            {
            }

            try
            {
                int result = MessageBoxTimeout(IntPtr.Zero, DuplicateInstanceMessage, "PedDash", 0, 0, 5000);
                if (result == 0)
                {
                    MessageBox(IntPtr.Zero, DuplicateInstanceMessage, "PedDash", 0);
                }
            }
            catch
            {
            }

            Environment.Exit(0);
        }
    }
}
