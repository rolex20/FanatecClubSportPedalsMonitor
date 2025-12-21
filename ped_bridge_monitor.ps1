<#
.SYNOPSIS
    PedBridge Monitor - Telemetry Accumulation & Statistics
    Connects to the PedBridge HTTP server and validates timing metrics.
    Used for troubleshooting and debugging only

.DESCRIPTION
    Cycles through a list of target frame counts (1..1000).
    Aggregates Min/Max/Avg for:
    1. C Program Loop (fullLoopTime_ms)
    2. PowerShell Main Loop (metricLoopProcessMs)
    3. HTTP Server Processing (metricHttpProcessMs)
    4. TTS Latency (metricTtsSpeakMs)

.NOTES
    Output Format: Avg (Min - Max)
#>

# Configuration: Sequence of frames to accumulate
$targetSequence = @(1, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)
$targetSequence = @(1, 2)
$url = "http://localhost:8181/"

# Friendly: We need an initial guess for the C program's sleep time.
# It will auto-correct after the first successful request.
$cProgramSleepTimeMs = 10 

# Helper function to format stats nicely: "Avg (Min-Max)"
function Format-Stats ($data, $propName) {
    if ($null -eq $data -or $data.Count -eq 0) { return "-" }
    
    $stats = $data | Measure-Object -Property $propName -Average -Minimum -Maximum
    
    # If the property doesn't exist or is null, return dash
    if ($null -eq $stats.Average) { return "-" }

    # Format: 1.23 (1-5)
    return "{0:N2} ({1:N0}-{2:N0})" -f $stats.Average, $stats.Minimum, $stats.Maximum
}

Write-Host "Starting PedBridge Monitor (Stats Mode)..." -ForegroundColor Cyan
Write-Host "Connecting to $url" -ForegroundColor Gray
Write-Host "Legend: Avg (Min-Max) in milliseconds" -ForegroundColor Gray
Write-Host "------------------------------------------------------------------------------------------------------------------------------"
Write-Host ("{0,-6} | {1,-6} | {2,-8} | {3,-20} | {4,-20} | {5,-20} | {6,-20}" -f "Target", "Actual", "Wait(ms)", "C-Loop(ms)", "PS-Loop(ms)", "HTTP(ms)", "TTS(ms)")
Write-Host "------------------------------------------------------------------------------------------------------------------------------"

while ($true) {
    foreach ($targetFrames in $targetSequence) {
        
        # --- 1. Dynamic Sleep Calculation ---
        # TimeToWait = (TargetFrames * C_Sleep_Time) + small buffer
        $sleepDuration = ($targetFrames * $cProgramSleepTimeMs) + 25
        
        Start-Sleep -Milliseconds $sleepDuration

        # --- 2. Fetch Telemetry ---
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-RestMethod -Uri $url -ErrorAction Stop
            $sw.Stop()
            
            # --- 3. Process Response ---
            $frames = $response.frames
            $actualCount = $frames.Count

            if ($actualCount -gt 0) {
                # Update sleep time knowledge from the most recent frame
                if ($frames[-1].sleep_Time -gt 0) {
                    $cProgramSleepTimeMs = $frames[-1].sleep_Time
                }

                # --- 4. Calculate Statistics ---
                # We calculate Min, Max, and Avg for the requested metrics across ALL frames in this batch
                $statCLoop  = Format-Stats $frames "fullLoopTime_ms"
                $statPsLoop = Format-Stats $frames "metricLoopProcessMs"
                $statHttp   = Format-Stats $frames "metricHttpProcessMs"
                $statTts    = Format-Stats $frames "metricTtsSpeakMs"

                # --- 5. Print Statistics ---
                $color = if ($actualCount -lt $targetFrames) { "Yellow" } else { "Green" }
                
                Write-Host ("{0,-6} | {1,-6} | {2,-8} | {3,-20} | {4,-20} | {5,-20} | {6,-20}" -f `
                    $targetFrames, `
                    $actualCount, `
                    $sleepDuration, `
                    $statCLoop, `
                    $statPsLoop, `
                    $statHttp, `
                    $statTts) -ForegroundColor $color
            }
            else {
                Write-Host ("{0,-6} | {1,-6} | {2,-8} | [No Data Received]" -f $targetFrames, 0, $sleepDuration) -ForegroundColor Red
            }
        }
        catch {
            Write-Host "Error connecting to PedBridge: $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
    
    Write-Host "--- Cycle Complete ---" -ForegroundColor DarkGray
    Start-Sleep -Seconds 1

}
