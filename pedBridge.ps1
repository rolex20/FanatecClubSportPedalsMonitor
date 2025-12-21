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

# Load Speech Assembly Globally
Add-Type -AssemblyName System.speech

# Region: Interop Definitions
# Check if the type already exists.
# friendly tip: If you change the C# code below, you MUST restart PowerShell. Add-Type cannot "update" a class once loaded.
if (-not ([System.Management.Automation.PSTypeName]'PedMon.Interop').Type) {
$Definition = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Concurrent;
using System.Net; 

namespace PedMon {
    
    // CRITICAL: This struct matches the C program exactly.
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

    /* 
       Global Shared State
       This bridges the gap between the Main Loop and HTTP Thread safely.
    */
    public static class Shared {
        public static ConcurrentQueue<object> TelemetryQueue = new ConcurrentQueue<object>();
        public static int BatchId = 0;

        // We store the HttpListener here so the background thread can find it!
        public static HttpListener GlobalListener;

        // Performance Metrics (Thread-safe doubles)
        public static double LastHttpTimeMs;
        public static double LastLoopTimeMs;
        public static double LastTtsTimeMs;
        
        // Debug flag to check if HTTP thread is alive
        public static bool HttpThreadRunning = false;
        public static string HttpThreadError = "";
    }

    /*
       Interop Helper
       This class handles the "dirty work" of Windows API calls.
       It prevents PowerShell from having to cast Int32 to UIntPtr, which causes crashes.
    */
    public static class Interop {
        private const uint FILE_MAP_READ = 0x0004;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint INFINITE = 0xFFFFFFFF;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern IntPtr OpenFileMapping(uint dwDesiredAccess, bool bInheritHandle, string lpName);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern IntPtr OpenEvent(uint dwDesiredAccess, bool bInheritHandle, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);

        // -- Safe Wrappers for PowerShell --

        public static IntPtr OpenSharedMemory(string name) {
            return OpenFileMapping(FILE_MAP_READ, false, name);
        }

        public static IntPtr MapMemory(IntPtr hMap) {
            // We calculate the size here in C#, so PowerShell doesn't fail converting Int to UIntPtr
            UIntPtr size = new UIntPtr((uint)Marshal.SizeOf(typeof(PedalMonState)));
            return MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, size);
        }

        public static IntPtr OpenSyncEvent(string name) {
            return OpenEvent(SYNCHRONIZE, false, name);
        }

        public static bool WaitForSignalInfinite(IntPtr hEvent) {
            // We handle the 0xFFFFFFFF constant here in C#
            return WaitForSingleObject(hEvent, INFINITE) == 0;
        }
    }
}
"@
    Add-Type -TypeDefinition $Definition -Language CSharp
} else {
    Write-Warning "Using existing C# definition. If you modified the C# code, please restart PowerShell."
}

# Region: Reset Shared State (Fix for Restart Issue)
# We must clear static variables because they persist in memory after Ctrl+C.
[PedMon.Shared]::HttpThreadError = ""
[PedMon.Shared]::HttpThreadRunning = $false
[PedMon.Shared]::BatchId = 0
# Drain the queue
$junk = $null
while ([PedMon.Shared]::TelemetryQueue.TryDequeue([ref]$junk)) {}

# Region: TTS Templates
$TtsTemplates = @{
    GasAlert        = "Gas {0} percent."
    ClutchAlert     = "Rudder."
    NewEstimation   = "New deadzone estimation {0} percent."
    AutoAdjusted    = "Auto adjusted deadzone to {0} percent."
    Connected       = "Controller connected."
    Disconnected    = "Controller disconnected."
}

# Region: HTTP JSON Server
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8181/")
$listener.Start()

# Teleport the listener to the shared C# class so the background PS instance can see it
[PedMon.Shared]::GlobalListener = $listener

# In PS 5.1, we must use [PowerShell]::Create() to run code in a background thread reliably.
$httpPs = [PowerShell]::Create()
$httpPs.AddScript({
    [PedMon.Shared]::HttpThreadRunning = $true
    $sharedListener = [PedMon.Shared]::GlobalListener
    $sw = [System.Diagnostics.Stopwatch]::New()

    try {
        while ($sharedListener.IsListening) {
            try {
                # GetContext blocks until a request arrives
                $context = $sharedListener.GetContext()
                
                $sw.Restart()
                $request = $context.Request
                $response = $context.Response

                $response.AddHeader("Access-Control-Allow-Origin", "*")
                $response.AddHeader("Access-Control-Allow-Methods", "GET, OPTIONS")
                $response.AddHeader("Access-Control-Allow-Headers", "*")
                $response.AddHeader("Cache-Control", "no-store")

                if ($request.HttpMethod -eq "OPTIONS") {
                    $response.StatusCode = 200
                    $response.Close()
                    continue
                }

                # Drain pending frames
                $frameList = [System.Collections.Generic.List[PSObject]]::new()
                $f = $null
                while ([PedMon.Shared]::TelemetryQueue.TryDequeue([ref]$f)) { $frameList.Add($f) }

                $output = @{
                    schemaVersion = 1
                    bridgeInfo = @{
                        batchId = [System.Threading.Interlocked]::Increment([ref][PedMon.Shared]::BatchId)
                        servedAtUnixMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
                        pendingFrameCount = $frameList.Count
                    }
                    frames = $frameList
                }

                $json = $output | ConvertTo-Json  -Compress
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
                $response.Close()
                
                $sw.Stop()
                [PedMon.Shared]::LastHttpTimeMs = $sw.Elapsed.TotalMilliseconds
                
            } catch {
                # Log error to shared state so main loop can see it
                [PedMon.Shared]::HttpThreadError = $_.Exception.Message
            }
        }
    } catch {
        [PedMon.Shared]::HttpThreadRunning = $false
        [PedMon.Shared]::HttpThreadError = "CRITICAL: " + $_.Exception.Message
    }
}) | Out-Null

# Start the background PowerShell instance asynchronously
$httpHandle = $httpPs.BeginInvoke()

# Region: Main Telemetry Loop
try {
    Write-Host "PedBridge v1.9c - Initializing..." -ForegroundColor Cyan
    
    # --- Safe Interop Calls (No more casting errors) ---
    $hMap = [PedMon.Interop]::OpenSharedMemory("PedMonTelemetry")
    if ($hMap -eq [IntPtr]::Zero) { throw "Mapping not found. Ensure PedMon is running with --telemetry." }

    $pMem = [PedMon.Interop]::MapMemory($hMap)
    if ($pMem -eq [IntPtr]::Zero) { throw "Failed to map memory view." }

    $hEvent = [PedMon.Interop]::OpenSyncEvent("PedMonTelemetryEvent")
    if ($hEvent -eq [IntPtr]::Zero) { throw "Telemetry sync event not found." }

    # Setup TTS Engine (Main Thread)
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
    $synth.Rate = 0
    $ttsWatch = [System.Diagnostics.Stopwatch]::New()

    Write-Host "Connected to Shared Memory. Serving on http://localhost:8181/" -ForegroundColor Green

    $wasDisconnected = 0
	$sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        try {            
            # Infinite wait (non-polling) for producer update
            # Using the C# helper to handle the Infinite wait logic safely
            if ([PedMon.Interop]::WaitForSignalInfinite($hEvent)) {
				$sw.Restart()				
                
                # --- Double-Read Anti-Torn-Read Pattern ---
                $first = [System.Runtime.InteropServices.Marshal]::PtrToStructure($pMem, [type][PedMon.PedalMonState])
                $second = [System.Runtime.InteropServices.Marshal]::PtrToStructure($pMem, [type][PedMon.PedalMonState])
                
                $data = if ($first.telemetry_sequence -eq $second.telemetry_sequence) { $first } else { $second }
                $receivedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

                # --- Construct JSON-ready Frame ---
                # Wrap the struct in a PSObject so we can append members. 
                # This ensures absolutely ALL variables from the C struct are sent.
                $frame = [PSObject]$data

                # Append our metadata that isn't in the C# struct
                $frame | Add-Member -MemberType NoteProperty -Name "receivedAtUnixMs" -Value $receivedAt
                
                # Append the 3 requested Telemetry Metrics
                # FIX: We wrap the static members in parens (...) to force evaluation to Double.
                $frame | Add-Member -MemberType NoteProperty -Name "metricHttpProcessMs" -Value ([PedMon.Shared]::LastHttpTimeMs)
                $frame | Add-Member -MemberType NoteProperty -Name "metricTtsSpeakMs"    -Value ([PedMon.Shared]::LastTtsTimeMs)
                $frame | Add-Member -MemberType NoteProperty -Name "metricLoopProcessMs" -Value ([PedMon.Shared]::LastLoopTimeMs)

                # Push to shared queue
                [PedMon.Shared]::TelemetryQueue.Enqueue($frame)

                # --- TTS Logic (Main Thread / Async) ---
                if ($data.tts_enabled -eq 0) {
                    $msgToSpeak = $null

                    if ($data.gas_alert_triggered -ne 0) {
                        $msgToSpeak = ($TtsTemplates.GasAlert -f $data.percentReached)
                    }
                    elseif ($data.clutch_alert_triggered -ne 0) {
                        $msgToSpeak = $TtsTemplates.ClutchAlert
                    }
                    elseif ($data.gas_estimate_decreased -ne 0) {
                        $msgToSpeak = ($TtsTemplates.NewEstimation -f $data.best_estimate_percent)
                    }
                    elseif ($data.gas_auto_adjust_applied -ne 0) {
                        $msgToSpeak = ($TtsTemplates.AutoAdjusted -f $data.gas_deadzone_out)
                    }
                    elseif ($data.controller_reconnected -ne 0) {
                        $msgToSpeak = $TtsTemplates.Connected
                    }
                    elseif ($data.controller_disconnected -ne 0 -and $wasDisconnected -eq 0) {
                        $msgToSpeak = $TtsTemplates.Disconnected
                    }

                    if ($null -ne $msgToSpeak) {
                        $ttsWatch.Restart()
                        $synth.SpeakAsync($msgToSpeak) | Out-Null
                        $ttsWatch.Stop()
                        [PedMon.Shared]::LastTtsTimeMs = $ttsWatch.Elapsed.TotalMilliseconds
                    }
                }
                $wasDisconnected = $data.controller_disconnected
            }

            # Optional: Check if background thread crashed
            if ([PedMon.Shared]::HttpThreadError -ne "") {
                Write-Host ("HTTP Error: " + [PedMon.Shared]::HttpThreadError) -ForegroundColor Red
                [PedMon.Shared]::HttpThreadError = "" # Clear error
            }
            
            $sw.Stop()
            # Report elapsed time in milliseconds
            [PedMon.Shared]::LastLoopTimeMs = $sw.Elapsed.TotalMilliseconds
            
        } catch {
            Write-Host "[LOOP ERROR] $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Milliseconds 1000
        }
    }
}
finally {
    Write-Host "`nShutting down PedBridge..." -ForegroundColor Yellow
    if ($listener) { $listener.Stop() }
    
    # Clean up the background PowerShell instance
    if ($httpPs) { 
        $httpPs.Stop() 
        $httpPs.Dispose()
    }

    # Cleanup unmanaged resources via C# helper
    if ($pMem)   { [PedMon.Interop]::UnmapViewOfFile($pMem) | Out-Null }
    if ($hMap)   { [PedMon.Interop]::CloseHandle($hMap) | Out-Null }
    if ($hEvent) { [PedMon.Interop]::CloseHandle($hEvent) | Out-Null }
	
    if ($synth)  { $synth.Dispose() }
	
	$listener = $null
	$pMem = $null
	$hMap = $null 
	$hEvent = $null
    $synth = $null
    $httpPs = $null

    # Force Garbage Collection (The "Nuclear" Cleanup)
    # This forces .NET to reclaim the memory NOW, rather than waiting.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
	
    Write-Host "`nDisconnected and Memory Freed." -ForegroundColor Gray
    
}