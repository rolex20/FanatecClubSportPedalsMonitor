using System;
using System.IO;

namespace PedDash.Services
{
    public sealed class AppLaunchOptions
    {
        public string? ConfigPath { get; private set; }

        public static AppLaunchOptions Parse(string[] args)
        {
            var options = new AppLaunchOptions();

            for (int i = 0; i < args.Length; i++)
            {
                if (!string.Equals(args[i], "--config", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (i + 1 < args.Length)
                {
                    options.ConfigPath = Path.GetFullPath(args[i + 1]);
                }
            }

            return options;
        }
    }
}
