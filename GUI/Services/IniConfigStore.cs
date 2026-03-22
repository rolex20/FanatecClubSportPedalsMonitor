using PedDash.Models;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace PedDash.Services
{
    public sealed class IniConfigStore
    {
        private sealed class IniLine
        {
            public string Raw { get; set; } = string.Empty;
            public bool IsSection { get; set; }
            public bool IsKeyValue { get; set; }
            public string Section { get; set; } = string.Empty;
            public string Key { get; set; } = string.Empty;
        }

        private sealed class ConfigKey
        {
            public required string Section { get; init; }
            public required string Key { get; init; }
            public required Func<PedalConfig, string> Getter { get; init; }
            public required Action<PedalConfig, string> Setter { get; init; }
        }

        private readonly List<IniLine> _lines = new();
        private readonly Dictionary<string, ConfigKey> _keyMap;
        private readonly Dictionary<string, List<ConfigKey>> _keysBySection;

        public IniConfigStore()
        {
            List<ConfigKey> keys = BuildKeys();
            _keyMap = BuildMap(keys);
            _keysBySection = BuildKeysBySection(keys);
        }

        public string ResolveConfigPath(string? overridePath)
        {
            if (!string.IsNullOrWhiteSpace(overridePath))
            {
                return Path.GetFullPath(overridePath);
            }

            return Path.Combine(AppContext.BaseDirectory, "FanatecPedals.current.ini");
        }

        public PedalConfig Load(string? overridePath)
        {
            string path = ResolveConfigPath(overridePath);
            _lines.Clear();

            if (!File.Exists(path))
            {
                var fresh = new PedalConfig { ConfigPath = path };
                fresh.Normalize();
                Save(fresh);
                return fresh;
            }

            var config = new PedalConfig
            {
                ConfigPath = path,
                BrakeDeadzoneIn = -1,
                BrakeDeadzoneOut = -1,
                ClutchDeadzoneIn = -1,
                ClutchDeadzoneOut = -1
            };

            string currentSection = string.Empty;
            foreach (string rawLine in File.ReadAllLines(path))
            {
                string trimmed = rawLine.Trim();
                var line = new IniLine
                {
                    Raw = rawLine,
                    Section = currentSection
                };

                if (trimmed.StartsWith("[", StringComparison.Ordinal) && trimmed.EndsWith("]", StringComparison.Ordinal))
                {
                    currentSection = trimmed[1..^1].Trim();
                    line.IsSection = true;
                    line.Section = currentSection;
                    _lines.Add(line);
                    continue;
                }

                int equalsIndex = rawLine.IndexOf('=');
                if (equalsIndex > 0 && !trimmed.StartsWith(";", StringComparison.Ordinal))
                {
                    string key = rawLine[..equalsIndex].Trim();
                    string value = rawLine[(equalsIndex + 1)..].Trim();
                    string canonical = CanonicalKey(currentSection, key);

                    line.IsKeyValue = true;
                    line.Key = key;

                    if (_keyMap.TryGetValue(canonical, out ConfigKey? mapped))
                    {
                        mapped.Setter(config, value);
                    }
                }

                _lines.Add(line);
            }

            ApplyLegacyDefaults(config);
            config.Normalize();
            return config;
        }

        public void Save(PedalConfig config)
        {
            config.Normalize();
            string path = string.IsNullOrWhiteSpace(config.ConfigPath)
                ? ResolveConfigPath(null)
                : config.ConfigPath;

            config.ConfigPath = path;
            string? directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            if (_lines.Count == 0)
            {
                _lines.AddRange(DefaultLines());
            }

            var output = new StringBuilder();
            var writtenKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var seenSections = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string currentSection = string.Empty;

            void AppendMissingForSection(string section)
            {
                if (string.IsNullOrWhiteSpace(section))
                {
                    return;
                }

                if (!_keysBySection.TryGetValue(section, out List<ConfigKey>? keys))
                {
                    return;
                }

                foreach (ConfigKey key in keys)
                {
                    string canonical = CanonicalKey(section, key.Key);
                    if (writtenKeys.Contains(canonical) || !ShouldPersistKey(config, key))
                    {
                        continue;
                    }

                    output.AppendLine($"{key.Key}={key.Getter(config)}");
                    writtenKeys.Add(canonical);
                }
            }

            foreach (IniLine line in _lines)
            {
                if (line.IsSection)
                {
                    AppendMissingForSection(currentSection);
                    currentSection = line.Section;
                    seenSections.Add(currentSection);
                    output.AppendLine(line.Raw);
                    continue;
                }

                if (line.IsKeyValue)
                {
                    string canonical = CanonicalKey(currentSection, line.Key);
                    if (_keyMap.TryGetValue(canonical, out ConfigKey? key))
                    {
                        if (!ShouldPersistKey(config, key))
                        {
                            continue;
                        }

                        output.AppendLine($"{key.Key}={key.Getter(config)}");
                        writtenKeys.Add(canonical);
                        continue;
                    }
                }

                output.AppendLine(line.Raw);
            }

            AppendMissingForSection(currentSection);

            foreach (string section in new[] { "General", "Gas", "Brake", "Clutch", "Audio", "Telemetry" })
            {
                if (seenSections.Contains(section))
                {
                    continue;
                }

                output.AppendLine($"[{section}]");
                AppendMissingForSection(section);
                output.AppendLine();
            }

            File.WriteAllText(path, output.ToString(), new UTF8Encoding(false));
        }

        private static void ApplyLegacyDefaults(PedalConfig config)
        {
            if (!config.BrakeDeadzoneInExplicit || config.BrakeDeadzoneIn < 0) config.BrakeDeadzoneIn = config.GasDeadzoneIn;
            if (!config.BrakeDeadzoneOutExplicit || config.BrakeDeadzoneOut < 0) config.BrakeDeadzoneOut = config.GasDeadzoneOut;
            if (!config.ClutchDeadzoneInExplicit || config.ClutchDeadzoneIn < 0) config.ClutchDeadzoneIn = config.GasDeadzoneIn;
            if (!config.ClutchDeadzoneOutExplicit || config.ClutchDeadzoneOut < 0) config.ClutchDeadzoneOut = config.GasDeadzoneOut;
        }

        private static Dictionary<string, List<ConfigKey>> BuildKeysBySection(IEnumerable<ConfigKey> keys)
        {
            var keysBySection = new Dictionary<string, List<ConfigKey>>(StringComparer.OrdinalIgnoreCase);
            foreach (ConfigKey key in keys)
            {
                if (!keysBySection.TryGetValue(key.Section, out List<ConfigKey>? bucket))
                {
                    bucket = new List<ConfigKey>();
                    keysBySection[key.Section] = bucket;
                }

                bucket.Add(key);
            }

            return keysBySection;
        }

        private static Dictionary<string, ConfigKey> BuildMap(IEnumerable<ConfigKey> keys)
        {
            var map = new Dictionary<string, ConfigKey>(StringComparer.OrdinalIgnoreCase);
            foreach (ConfigKey key in keys)
            {
                map[CanonicalKey(key.Section, key.Key)] = key;
            }

            return map;
        }

        private List<ConfigKey> BuildKeys()
        {
            return new List<ConfigKey>
            {
                Key("General", "InputMode", cfg => cfg.InputMode.ToString(), (cfg, value) => cfg.InputMode = ParseInputMode(value)),
                Key("General", "SleepTime", cfg => cfg.SleepTime.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.SleepTime = ParseInt(value, cfg.SleepTime)),
                Key("General", "Verbose", cfg => FormatBool(cfg.Verbose), (cfg, value) => cfg.Verbose = ParseBool(value)),
                Key("General", "NoAxisNormalization", cfg => FormatBool(cfg.NoAxisNormalization), (cfg, value) => cfg.NoAxisNormalization = ParseBool(value)),
                Key("General", "Iterations", cfg => cfg.Iterations.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.Iterations = ParseInt(value, cfg.Iterations)),
                Key("General", "JoyFlags", cfg => cfg.JoyFlags.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.JoyFlags = ParseInt(value, cfg.JoyFlags)),
                Key("General", "VendorId", cfg => cfg.VendorId, (cfg, value) => cfg.VendorId = value),
                Key("General", "ProductId", cfg => cfg.ProductId, (cfg, value) => cfg.ProductId = value),
                Key("General", "JoystickId", cfg => cfg.JoystickId.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.JoystickId = ParseInt(value, cfg.JoystickId)),
                Key("General", "Idle", cfg => FormatBool(cfg.Idle), (cfg, value) => cfg.Idle = ParseBool(value)),
                Key("General", "BelowNormal", cfg => FormatBool(cfg.BelowNormal), (cfg, value) => cfg.BelowNormal = ParseBool(value)),
                Key("General", "AffinityMask", cfg => cfg.AffinityMask, (cfg, value) => cfg.AffinityMask = value),
                Key("General", "Margin", cfg => cfg.Margin.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.Margin = ParseInt(value, cfg.Margin)),
                Key("General", "ClutchRepeat", cfg => cfg.ClutchRepeat.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.ClutchRepeat = ParseInt(value, cfg.ClutchRepeat)),
                Key("General", "DebugRaw", cfg => FormatBool(cfg.DebugRaw), (cfg, value) => cfg.DebugRaw = ParseBool(value)),
                Key("General", "NoConsoleBanner", cfg => FormatBool(cfg.NoConsoleBanner), (cfg, value) => cfg.NoConsoleBanner = ParseBool(value)),
                Key("General", "MaxHistory", cfg => cfg.MaxHistory.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.MaxHistory = ParseInt(value, cfg.MaxHistory)),
                Key("General", "RenderSmoothingMode", cfg => cfg.RenderSmoothingMode, (cfg, value) => cfg.RenderSmoothingMode = value),
                Key("General", "RenderFpsCap", cfg => cfg.RenderFpsCap, (cfg, value) => cfg.RenderFpsCap = value),
                Key("General", "SignalsWaveformHeightPercent", cfg => cfg.SignalsWaveformHeightPercent.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.SignalsWaveformHeightPercent = ParseInt(value, cfg.SignalsWaveformHeightPercent)),
                Key("General", "SignalsHideBrake", cfg => FormatBool(cfg.SignalsHideBrake), (cfg, value) => cfg.SignalsHideBrake = ParseBool(value)),

                Key("Gas", "MonitorGas", cfg => FormatBool(cfg.MonitorGas), (cfg, value) => cfg.MonitorGas = ParseBool(value)),
                Key("Gas", "GasDeadzoneIn", cfg => cfg.GasDeadzoneIn.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.GasDeadzoneIn = ParseInt(value, cfg.GasDeadzoneIn)),
                Key("Gas", "GasDeadzoneOut", cfg => cfg.GasDeadzoneOut.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.GasDeadzoneOut = ParseInt(value, cfg.GasDeadzoneOut)),
                Key("Gas", "GasWindow", cfg => cfg.GasWindow.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.GasWindow = ParseInt(value, cfg.GasWindow)),
                Key("Gas", "GasCooldown", cfg => cfg.GasCooldown.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.GasCooldown = ParseInt(value, cfg.GasCooldown)),
                Key("Gas", "GasTimeout", cfg => cfg.GasTimeout.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.GasTimeout = ParseInt(value, cfg.GasTimeout)),
                Key("Gas", "GasMinUsage", cfg => cfg.GasMinUsage.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.GasMinUsage = ParseInt(value, cfg.GasMinUsage)),
                Key("Gas", "EstimateGasDeadzone", cfg => FormatBool(cfg.EstimateGasDeadzone), (cfg, value) => cfg.EstimateGasDeadzone = ParseBool(value)),
                Key("Gas", "AutoGasDeadzoneMin", cfg => cfg.AutoGasDeadzoneMin.ToString(CultureInfo.InvariantCulture), (cfg, value) => cfg.AutoGasDeadzoneMin = ParseInt(value, cfg.AutoGasDeadzoneMin)),

                Key("Brake", "BrakeDeadzoneIn", cfg => cfg.BrakeDeadzoneIn.ToString(CultureInfo.InvariantCulture), (cfg, value) =>
                {
                    cfg.BrakeDeadzoneIn = ParseInt(value, cfg.BrakeDeadzoneIn);
                    cfg.BrakeDeadzoneInExplicit = true;
                }),
                Key("Brake", "BrakeDeadzoneOut", cfg => cfg.BrakeDeadzoneOut.ToString(CultureInfo.InvariantCulture), (cfg, value) =>
                {
                    cfg.BrakeDeadzoneOut = ParseInt(value, cfg.BrakeDeadzoneOut);
                    cfg.BrakeDeadzoneOutExplicit = true;
                }),

                Key("Clutch", "MonitorClutch", cfg => FormatBool(cfg.MonitorClutch), (cfg, value) => cfg.MonitorClutch = ParseBool(value)),
                Key("Clutch", "ClutchDeadzoneIn", cfg => cfg.ClutchDeadzoneIn.ToString(CultureInfo.InvariantCulture), (cfg, value) =>
                {
                    cfg.ClutchDeadzoneIn = ParseInt(value, cfg.ClutchDeadzoneIn);
                    cfg.ClutchDeadzoneInExplicit = true;
                }),
                Key("Clutch", "ClutchDeadzoneOut", cfg => cfg.ClutchDeadzoneOut.ToString(CultureInfo.InvariantCulture), (cfg, value) =>
                {
                    cfg.ClutchDeadzoneOut = ParseInt(value, cfg.ClutchDeadzoneOut);
                    cfg.ClutchDeadzoneOutExplicit = true;
                }),

                Key("Audio", "Tts", cfg => FormatBool(cfg.Tts), (cfg, value) => cfg.Tts = ParseBool(value)),
                Key("Audio", "NoTts", cfg => FormatBool(cfg.NoTts), (cfg, value) => cfg.NoTts = ParseBool(value)),

                Key("Telemetry", "Telemetry", cfg => FormatBool(cfg.Telemetry), (cfg, value) => cfg.Telemetry = ParseBool(value))
            };
        }

        private static ConfigKey Key(string section, string key, Func<PedalConfig, string> getter, Action<PedalConfig, string> setter)
        {
            return new ConfigKey
            {
                Section = section,
                Key = key,
                Getter = getter,
                Setter = setter
            };
        }

        private static IEnumerable<IniLine> DefaultLines()
        {
            return new[]
            {
                new IniLine { Raw = "; PedDash configuration" },
                new IniLine { Raw = string.Empty },
                new IniLine { Raw = "[General]", IsSection = true, Section = "General" },
                new IniLine { Raw = string.Empty, Section = "General" },
                new IniLine { Raw = "[Gas]", IsSection = true, Section = "Gas" },
                new IniLine { Raw = string.Empty, Section = "Gas" },
                new IniLine { Raw = "[Brake]", IsSection = true, Section = "Brake" },
                new IniLine { Raw = string.Empty, Section = "Brake" },
                new IniLine { Raw = "[Clutch]", IsSection = true, Section = "Clutch" },
                new IniLine { Raw = string.Empty, Section = "Clutch" },
                new IniLine { Raw = "[Audio]", IsSection = true, Section = "Audio" },
                new IniLine { Raw = string.Empty, Section = "Audio" },
                new IniLine { Raw = "[Telemetry]", IsSection = true, Section = "Telemetry" }
            };
        }

        private static string CanonicalKey(string section, string key)
        {
            return $"{section.Trim().ToLowerInvariant()}::{key.Trim().ToLowerInvariant()}";
        }

        private static bool ShouldPersistKey(PedalConfig config, ConfigKey key)
        {
            string canonical = CanonicalKey(key.Section, key.Key);
            return canonical switch
            {
                "brake::brakedeadzonein" => config.BrakeDeadzoneInExplicit,
                "brake::brakedeadzoneout" => config.BrakeDeadzoneOutExplicit,
                "clutch::clutchdeadzonein" => config.ClutchDeadzoneInExplicit,
                "clutch::clutchdeadzoneout" => config.ClutchDeadzoneOutExplicit,
                _ => true
            };
        }

        private static bool ParseBool(string value)
        {
            string normalized = value.Trim().ToLowerInvariant();
            return normalized is "1" or "true" or "yes" or "y" or "on";
        }

        private static string FormatBool(bool value)
        {
            return value ? "true" : "false";
        }

        private static int ParseInt(string value, int fallback)
        {
            return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsed) ? parsed : fallback;
        }

        private static InputMode ParseInputMode(string value)
        {
            return Enum.TryParse(value, true, out InputMode mode) ? mode : InputMode.Simulation;
        }
    }
}
