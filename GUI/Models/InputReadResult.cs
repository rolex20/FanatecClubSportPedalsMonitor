namespace PedDash.Models
{
    public enum ConnectionChange
    {
        None,
        Disconnected,
        Reconnected
    }

    public sealed class InputReadResult
    {
        public bool IsConnected { get; set; }
        public ConnectionChange ConnectionChange { get; set; }
        public uint JoyId { get; set; }
        public uint JoyFlags { get; set; }
        public uint AxisMax { get; set; }
        public string DeviceName { get; set; } = string.Empty;
        public long DeviceReadStartUnixMs { get; set; }
        public long DeviceReadDurationMs { get; set; }
        public long SampleUnixMs { get; set; }
        public uint RawGas { get; set; }
        public uint RawBrake { get; set; }
        public uint RawClutch { get; set; }
    }
}
