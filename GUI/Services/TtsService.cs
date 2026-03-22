using PedDash.Models;
using System;
using System.Diagnostics;
using System.Speech.Synthesis;

namespace PedDash.Services
{
    public sealed class TtsService : IDisposable
    {
        private bool _enabled;
        private SpeechSynthesizer? _synthesizer;

        public TtsService(PedalConfig config)
        {
            ApplyConfig(config);
        }

        public double SpeakAsync(string message)
        {
            if (!_enabled || string.IsNullOrWhiteSpace(message))
            {
                return 0;
            }

            try
            {
                EnsureSynthesizer();
                if (_synthesizer is null)
                {
                    return 0;
                }

                long startTimestamp = Stopwatch.GetTimestamp();
                _synthesizer.SpeakAsync(message);
                return Stopwatch.GetElapsedTime(startTimestamp).TotalMilliseconds;
            }
            catch
            {
                return 0;
            }
        }

        public void ApplyConfig(PedalConfig config)
        {
            _enabled = config.EffectiveTtsEnabled;
            if (!_enabled)
            {
                return;
            }

            EnsureSynthesizer();
        }

        private void EnsureSynthesizer()
        {
            if (_synthesizer is not null)
            {
                return;
            }

            try
            {
                _synthesizer = new SpeechSynthesizer();
                _synthesizer.SelectVoiceByHints(VoiceGender.Female);
            }
            catch
            {
                _enabled = false;
                _synthesizer = null;
            }
        }

        public void Dispose()
        {
            _synthesizer?.Dispose();
        }
    }
}
