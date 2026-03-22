using System;
using Microsoft.UI;
using Windows.UI;

namespace PedDash.Models
{
    public sealed class EventLogItem
    {
        public DateTime Timestamp { get; set; } = DateTime.Now;
        public string Time { get; set; } = string.Empty;
        public string Type { get; set; } = string.Empty;
        public string Details { get; set; } = string.Empty;
        public Color TypeColor { get; set; } = Microsoft.UI.Colors.White;

        public static EventLogItem Create(string type, string details, Color color)
        {
            DateTime now = DateTime.Now;
            return new EventLogItem
            {
                Timestamp = now,
                Time = now.ToString("HH:mm:ss.fff"),
                Type = type,
                Details = details,
                TypeColor = color
            };
        }
    }
}
