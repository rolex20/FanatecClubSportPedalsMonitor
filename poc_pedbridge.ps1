<#
.SYNOPSIS
    PedBridge TTS (Async)
    Monitors FanatecMonitor Shared Memory and performs Text-To-Speech.  Avoids Write-Host for each event since Write-Host is so CPU expensive in Powershell, besides C program already Alerts with text and timestamp.
	Just a Proof of Concept with some working ideas.
#>

# 1. Setup Voice (Using your preferred settings)
Add-Type -AssemblyName System.speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
$speak.Rate = 0

# 2. Define C# Struct and Interop
# CRITICAL: This struct is aligned to match your C program. 
# Do not modify fields without modifying the C program too.
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

        // --- CLI Parameters ---
        public uint joy_ID;
        public uint joy_Flags;
        public uint iterations;
        public uint margin;
        public uint sleep_Time;

        // --- Axis State ---
        public uint axisMax;
        public uint axisMargin;
        public uint lastClutchValue;
        public int  repeatingClutchCount;

        // --- Gas State ---
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

        // --- Gas Estimate State ---
        public uint best_estimate_percent;
        public uint last_printed_estimate;
        public uint estimate_window_peak_percent;
        public uint estimate_window_start_time;
        public uint last_estimate_print_time;

        // --- Per-Sample Values ---
        public uint currentTime;
        public uint rawGas;
        public uint rawClutch;
        public uint gasValue;
        public uint clutchValue;
        public int  closure;
        public uint percentReached;
        public uint currentPercent;

        // --- Loop Counter ---
        public uint iLoop;

        // --- Telemetry Metrics ---
        public uint producer_loop_start_ms;
        public uint producer_notify_ms;
        public uint fullLoopTime_ms;
        public uint telemetry_sequence;

        // --- Event Flags (One-Shots) ---
        public int gas_alert_triggered;
        public int clutch_alert_triggered;
        public int controller_disconnected; // State (latched)
        public int controller_reconnected;  // Event (one-shot)
        public int gas_estimate_decreased;
        public int gas_auto_adjust_applied;

        // --- Timestamps ---
        public uint last_disconnect_time_ms;
        public uint last_reconnect_time_ms;
    }

    public class TelemetryLink : IDisposable {
        const uint FILE_MAP_READ = 0x0004;
        const uint SYNCHRONIZE = 0x00100000;
        
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        static extern IntPtr OpenFileMapping(uint dwDesiredAccess, bool bInheritHandle, string lpName);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        static extern IntPtr OpenEvent(uint dwDesiredAccess, bool bInheritHandle, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        private IntPtr hMap = IntPtr.Zero;
        private IntPtr pMem = IntPtr.Zero;
        private IntPtr hEvent = IntPtr.Zero;

        public bool Connect() {
            hMap = OpenFileMapping(FILE_MAP_READ, false, "PedMonTelemetry");
            if (hMap == IntPtr.Zero) return false;

            pMem = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, new UIntPtr((uint)Marshal.SizeOf(typeof(PedalMonState))));
            if (pMem == IntPtr.Zero) return false;

            hEvent = OpenEvent(SYNCHRONIZE, false, "PedMonTelemetryEvent");
            if (hEvent == IntPtr.Zero) return false;

            return true;
        }

        public bool WaitForUpdate(uint timeoutMs) {
            if (hEvent == IntPtr.Zero) return false;
            return WaitForSingleObject(hEvent, timeoutMs) == 0; 
        }

        public PedalMonState Read() {
            if (pMem == IntPtr.Zero) return new PedalMonState();
            return (PedalMonState)Marshal.PtrToStructure(pMem, typeof(PedalMonState));
        }

        public void Dispose() {
            if (pMem != IntPtr.Zero) UnmapViewOfFile(pMem);
            if (hMap != IntPtr.Zero) CloseHandle(hMap);
            if (hEvent != IntPtr.Zero) CloseHandle(hEvent);
            pMem = IntPtr.Zero; hMap = IntPtr.Zero; hEvent = IntPtr.Zero;
        }
    }
}
"@

Add-Type -TypeDefinition $Definition -Language CSharp 

try {
# 3. Initialize Connection
$link = [PedMon.TelemetryLink]::new()

Write-Host "Waiting for Fanatec Monitor (Shared Memory)..." -ForegroundColor Cyan

# Loop until connected
while (-not $link.Connect()) {
    Start-Sleep -Milliseconds 1000
}

Write-Host "Connected. Voice Active." -ForegroundColor Green
$speak.SpeakAsync("Monitoring started.") | Out-Null

# Helper to prevent spamming disconnect messages
$wasDisconnected = 0

# Create and start a Stopwatch
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Create a strongly-typed list. 
# This is O(1) for adding items (amortized) and does not recreate arrays.
$telemetryHistory = [System.Collections.Generic.List[PedMon.PedalMonState]]::new()

# Optional: Pre-allocate memory if you expect a lot of data (e.g., space for 10,000 frames)
# to prevent resizing overhead during the first few minutes.
$telemetryHistory.Capacity = 10000
	
    while ($true) {
        # Wait up to 2 seconds for a signal from the C program
        # This puts the script to sleep efficiently until C writes a new frame
        if ($link.WaitForUpdate(2000)) {
            $sw.Restart()

            $data = $link.Read()
			#$data | Format-List

            # --- STORE IN MEMORY ---
            # This is O(1). It copies the struct values into the list.
            $telemetryHistory.Add($data)
            # -----------------------			

            # --- EVENT: Gas Drift Alert ---
            if ($data.gas_alert_triggered -ne 0) {
                $msg = "Gas $($data.percentReached) percent."
				# Write-Host is really CPU expensive, Write-Host significantly increases CPU usage in powershell.  Avoid it, C program already alerts with text and timestamp.
                #Write-Host "[ALERT] $msg" -ForegroundColor Yellow
                $speak.SpeakAsync($msg) | Out-Null
            }

            # --- EVENT: Clutch Noise Alert ---
            if ($data.clutch_alert_triggered -ne 0) {
                $msg = "Rudder."
				# Write-Host is really CPU expensive, Write-Host significantly increases CPU usage in powershell.  Avoid it, C program already alerts with text and timestamp.
                # Write-Host "[ALERT] $msg" -ForegroundColor Red
                $speak.SpeakAsync($msg) | Out-Null
            }

            # --- EVENT: New Estimation Found ---
            if ($data.gas_estimate_decreased -ne 0) {
                $msg = "New deadzone estimation: $($data.best_estimate_percent) percent."
				# Write-Host is really CPU expensive, Write-Host significantly increases CPU usage in powershell.  Avoid it, C program already alerts with text and timestamp.
                #Write-Host "[INFO]  $msg" -ForegroundColor Cyan
                $speak.SpeakAsync($msg) | Out-Null
            }

            # --- EVENT: Auto Adjustment Applied ---
            if ($data.gas_auto_adjust_applied -ne 0) {
                # Note: We read gas_deadzone_out because that is what was just updated
                $msg = "Auto adjusted deadzone to $($data.gas_deadzone_out) percent."
				# Write-Host is really CPU expensive, Write-Host significantly increases CPU usage in powershell.  Avoid it, C program already alerts with text and timestamp.
                #Write-Host "[INFO]  $msg" -ForegroundColor Green
                $speak.SpeakAsync($msg) | Out-Null
            }

            # --- EVENT: Controller Reconnected ---
            if ($data.controller_reconnected -ne 0) {
                $msg = "Controller connected."
				# Write-Host is really CPU expensive, Write-Host significantly increases CPU usage in powershell.  Avoid it, C program already alerts with text and timestamp.
                # Write-Host "[CONN]  $msg" -ForegroundColor Green
                $speak.SpeakAsync($msg) | Out-Null
            }

            # --- STATE: Controller Disconnected (Edge Detection) ---
            # Unlike the others, this is a state (1 while disconnected), so we track previous state
            if ($data.controller_disconnected -ne 0 -and $wasDisconnected -eq 0) {
                $msg = "Controller disconnected."
				# Write-Host is really CPU expensive, Write-Host significantly increases CPU usage in powershell.  Avoid it, C program already alerts with text and timestamp.
                # Write-Host "[CONN]  $msg" -ForegroundColor Red
                $speak.SpeakAsync($msg) | Out-Null
            }
            $wasDisconnected = $data.controller_disconnected

			# Stop the Stopwatch
			$sw.Stop()

			# Report elapsed time in milliseconds
			Write-Host ("Elapsed total ms (double): {0}" -f $sw.Elapsed.TotalMilliseconds)

        }
    }
}
finally {
    
    # Accessing the history after loop ends (Ctrl+C)
    Write-Host "`nCaptured $($telemetryHistory.Count) frames in memory." -ForegroundColor Gray
	
    # 1. Deterministic Cleanup (Closes Handles immediately)
    if ($link) { 
        $link.Dispose() 
    }

    # 2. Stop the Voice Engine
    if ($speak) { 
        $speak.Dispose() 
    }

    # 3. Remove PowerShell References
    $link = $null
    $speak = $null

    # 4. Force Garbage Collection (The "Nuclear" Cleanup)
    # This forces .NET to reclaim the memory NOW, rather than waiting.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-Host "`nDisconnected and Memory Freed." -ForegroundColor Gray		
}
