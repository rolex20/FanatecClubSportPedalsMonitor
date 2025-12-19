<#
.SYNOPSIS
    PedBridge - Telemetry Bridge and HTTP JSON Server for PedMon.
    Exposes Fanatec pedal state over HTTP and provides event-driven async TTS.

.NOTES
    Design Architecture:
    1. Interop: Connects to PedMon via Win32 Shared Memory and Events.
    2. Telemetry Loop: Uses a "Double-Read" pattern to prevent torn reads from the C producer.
    3. HTTP Server: High-concurrency HttpListener serving JSON on port 8181.
    4. TTS Worker: Uses a BlockingCollection producer-consumer pattern to eliminate busy waiting.
#>

# Region: TTS Templates
$TtsTemplates = @{
    GasAlert        = "Gas {0} percent."
    ClutchAlert     = "Rudder."
    NewEstimation   = "New deadzone estimation {0} percent."
    AutoAdjusted    = "Auto adjusted deadzone to {0} percent."
    Connected       = "Controller connected."
    Disconnected    = "Controller disconnected."
}


# Region: Interop Definitions
$Definition = @"
using System;
using System.Runtime.InteropServices;

namespace PedMon {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi, Pack = 4)]
    public struct PedalMonState {
        // --- Configuration / Flags ---
        public int verbose_flag;
        public int monitor_clutch;
        public int monitor_gas;
        public int gas_deadzone_in;
        public int gas_deadzone_out;
        public int gas_window;
        public int gas_cooldown;
        public int gas_timeout;
        public int gas_min_usage_percent;
        public int axis_normalization_enabled;
        public int debug_raw_mode;
        public int clutch_repeat_required;
        public int estimate_gas_deadzone_enabled;
        public int auto_gas_deadzone_enabled;
        public int auto_gas_deadzone_minimum;
        public int target_vendor_id;
        public int target_product_id;
        public int telemetry_enabled;
        public int tts_enabled;
        public int ipc_enabled;
        public int no_console_banner;

        // --- UI Indicator Percentages (Added in v1.9c) ---
        public uint gas_physical_pct;
        public uint clutch_physical_pct;
        public uint gas_logical_pct;
        public uint clutch_logical_pct;

        // --- CLI / Axis State ---
        public uint joy_ID;
        public uint joy_Flags;
        public uint iterations;
        public uint margin;
        public uint sleep_Time;
        public uint axisMax;
        public uint axisMargin;
        public uint lastClutchValue;
        public int  repeatingClutchCount;
        public int  isRacing;
        public uint peakGasInWindow;
        public uint lastFullThrottleTime;
        public uint lastGasActivityTime;
        public uint lastGasAlertTime;
        public uint gasIdleMax;
        public uint gasFullMin;
        public uint gas_timeout_ms;
        public uint gas_window_ms;
        public uint gas_cooldown_ms;

        // --- Estimation State ---
        public uint best_estimate_percent;
        public uint last_printed_estimate;
        public uint estimate_window_peak_percent;
        public uint estimate_window_start_time;
        public uint last_estimate_print_time;

        // --- Sample Values ---
        public uint currentTime;
        public uint rawGas;
        public uint rawClutch;
        public uint gasValue;
        public uint clutchValue;
        public int  closure;
        public uint percentReached;
        public uint currentPercent;
        public uint iLoop;

        // --- Metrics ---
        public uint producer_loop_start_ms;
        public uint producer_notify_ms;
        public uint fullLoopTime_ms;
        public uint telemetry_sequence;

        // --- Event Flags ---
        public int gas_alert_triggered;
        public int clutch_alert_triggered;
        public int controller_disconnected;
        public int controller_reconnected;
        public int gas_estimate_decreased;
        public int gas_auto_adjust_applied;

        // --- Event Timestamps ---
        public uint last_disconnect_time_ms;
        public uint last_reconnect_time_ms;
    }

    public class Win32 {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr OpenFileMapping(uint dwDesiredAccess, bool bInheritHandle, string lpName);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr OpenEvent(uint dwDesiredAccess, bool bInheritHandle, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
    }
}
"@
Add-Type -TypeDefinition $Definition -Language CSharp


# Region: Shared Collections & Worker Threads
# BlockingCollection provides event-driven wake-up (no busy waiting)
$telemetryQueue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()
$ttsQueue = [System.Collections.Concurrent.BlockingCollection[string]]::new()
$batchId = 0

# Start background TTS Worker
$ttsThread = [System.Threading.Thread]::new({
    Add-Type -AssemblyName System.speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
    $synth.Rate = 0
    
    try {
        while ($true) {
            # Take() blocks the thread indefinitely (0% CPU) until an item is available
            $msg = $using:ttsQueue.Take()
            $synth.Speak($msg)
        }
    } catch {
        # Handle thread termination
    }
})
$ttsThread.IsBackground = $true
$ttsThread.Start()

# Region: HTTP JSON Server
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8181/")
$listener.Start()

$httpTask = [System.Threading.Tasks.Task]::Run({
	$sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
			
			$sw.Restart()
            $request = $context.Request
            $response = $context.Response

            # CORS and Cache Headers
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            $response.AddHeader("Access-Control-Allow-Methods", "GET, OPTIONS")
            $response.AddHeader("Access-Control-Allow-Headers", "*")
            $response.AddHeader("Cache-Control", "no-store")

            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 200
                $response.Close()
                continue
            }

            # Drain pending frames from queue
            $frameList = [System.Collections.Generic.List[PSObject]]::new()
            $f = $null
            while ($using:telemetryQueue.TryDequeue([ref]$f)) { $frameList.Add($f) }

            $output = @{
                schemaVersion = 1
                bridgeInfo = @{
                    batchId = [System.Threading.Interlocked]::Increment([ref]$using:batchId)
                    servedAtUnixMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
                    pendingFrameCount = $frameList.Count
                }
                frames = $frameList
            }

            $json = $output | ConvertTo-Json -Depth 5 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.Close()
			
			$sw.Stop()
			# Report elapsed time in milliseconds, comment after you are happy with the performance
			Write-Output ("[HTTP] Response Elapsed total ms (double): {0}" -f $sw.Elapsed.TotalMilliseconds)
			
        } catch {
            # Ignore listener errors during shutdown
        }
    }
})

# Region: Main Telemetry Loop
try {
    Write-Host "PedBridge v1.9c - Initializing..." -ForegroundColor Cyan
    
    $SYNCHRONIZE = 0x00100000
    $FILE_MAP_READ = 0x0004
    
    $hMap = [PedMon.Win32]::OpenFileMapping($FILE_MAP_READ, $false, "PedMonTelemetry")
    if ($hMap -eq [IntPtr]::Zero) { throw "Mapping not found. Ensure PedMon is running with --telemetry." }

    $pMem = [PedMon.Win32]::MapViewOfFile($hMap, $FILE_MAP_READ, 0, 0, [UIntPtr][System.Runtime.InteropServices.Marshal]::SizeOf([type][PedMon.PedalMonState]))
    $hEvent = [PedMon.Win32]::OpenEvent($SYNCHRONIZE, $false, "PedMonTelemetryEvent")
    if ($hEvent -eq [IntPtr]::Zero) { throw "Telemetry sync event not found." }

    Write-Host "Connected to Shared Memory. Serving on http://localhost:8181/" -ForegroundColor Green

    $wasDisconnected = 0

	$sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
		$sw.Restart()
		
        # Infinite wait (non-polling) for producer update
        if ([PedMon.Win32]::WaitForSingleObject($hEvent, [uint32]0xFFFFFFFF) -eq 0) {
            
            # --- Double-Read Anti-Torn-Read Pattern ---
            # We take two snapshots. If the sequence number is identical, the data is consistent.
            # If it changed during the read, the second snapshot is guaranteed to be newer/valid.
            $first = [System.Runtime.InteropServices.Marshal]::PtrToStructure($pMem, [type][PedMon.PedalMonState])
            $second = [System.Runtime.InteropServices.Marshal]::PtrToStructure($pMem, [type][PedMon.PedalMonState])
            
            $data = if ($first.telemetry_sequence -eq $second.telemetry_sequence) { $first } else { $second }
            $receivedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

            # --- Construct JSON-ready Frame ---
            $frame = [PSCustomObject]@{
                seq = $data.telemetry_sequence
                pedMonTimeMs = $data.currentTime
                controller = @{
                    connected = ($data.controller_disconnected -eq 0)
                    disconnectedFlag = $data.controller_disconnected
                    reconnectedFlag = $data.controller_reconnected
                    vendorId = $data.target_vendor_id
                    productId = $data.target_product_id
                    joyId = $data.joy_ID
                }
                telemetry = @{
                    producerLoopStartMs = $data.producer_loop_start_ms
                    producerNotifyMs    = $data.producer_notify_ms
                    fullLoopTimeMs      = $data.fullLoopTime_ms
                }
                pedals = @{
                    # New Precomputed Indicators
                    gasPhysicalPct    = $data.gas_physical_pct
                    clutchPhysicalPct = $data.clutch_physical_pct
                    gasLogicalPct     = $data.gas_logical_pct
                    clutchLogicalPct  = $data.clutch_logical_pct
                    # Raw/Normalized Values
                    rawGas      = $data.rawGas
                    rawClutch   = $data.rawClutch
                    gasValue    = $data.gasValue
                    clutchValue = $data.clutchValue
                }
                events = @{
                    gasAlert      = $data.gas_alert_triggered
                    clutchAlert   = $data.clutch_alert_triggered
                    reconnected   = $data.controller_reconnected
                    estimateDown  = $data.gas_estimate_decreased
                    autoAdjusted  = $data.gas_auto_adjust_applied
                }
                bridge = @{ receivedAtUnixMs = $receivedAt }
            }

            $telemetryQueue.Enqueue($frame)

            # --- TTS Logic (Only if PedMon is silent) ---
            if ($data.tts_enabled -eq 0) {
                if ($data.gas_alert_triggered -ne 0) {
                    $ttsQueue.Add(($TtsTemplates.GasAlert -f $data.percentReached))
                }
                if ($data.clutch_alert_triggered -ne 0) {
                    $ttsQueue.Add($TtsTemplates.ClutchAlert)
                }
                if ($data.gas_estimate_decreased -ne 0) {
                    $ttsQueue.Add(($TtsTemplates.NewEstimation -f $data.best_estimate_percent))
                }
                if ($data.gas_auto_adjust_applied -ne 0) {
                    $ttsQueue.Add(($TtsTemplates.AutoAdjusted -f $data.gas_deadzone_out))
                }
                if ($data.controller_reconnected -ne 0) {
                    $ttsQueue.Add($TtsTemplates.Connected)
                }
                if ($data.controller_disconnected -ne 0 -and $wasDisconnected -eq 0) {
                    $ttsQueue.Add($TtsTemplates.Disconnected)
                }
            }
            $wasDisconnected = $data.controller_disconnected
        }
		$sw.Stop()
		# Report elapsed time in milliseconds, comment after you are happy with the performance
		Write-Output ("[Telemetry] Loop Elapsed total ms (double): {0}" -f $sw.Elapsed.TotalMilliseconds)

    }
}
finally {
    Write-Host "`nShutting down PedBridge..." -ForegroundColor Yellow
    if ($listener) { $listener.Stop() }
    if ($pMem)   { [PedMon.Win32]::UnmapViewOfFile($pMem) | Out-Null }
    if ($hMap)   { [PedMon.Win32]::CloseHandle($hMap) | Out-Null }
    if ($hEvent) { [PedMon.Win32]::CloseHandle($hEvent) | Out-Null }
	
    $ttsQueue.CompleteAdding()
	
	$listener = $null
	$pMem = $null
	$hMap = $null 
	$hEvent = $null
	$ttsQueue = $null

    # Force Garbage Collection (The "Nuclear" Cleanup)
    # This forces .NET to reclaim the memory NOW, rather than waiting.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
	
    Write-Host "`nDisconnected and Memory Freed." -ForegroundColor Gray			
}