Sure — you can add Windows TTS (System.Speech) and speak the process name immediately on START/STOP, using async speech (SpeakAsync).

Below are drop-in changes for the discovery script I gave you.


---

1) Add this near the top of your script (after Set-StrictMode)

# --- TTS (async) -------------------------------------------------------------
Add-Type -AssemblyName System.Speech

# Keep synth objects alive until they finish speaking
$global:TtsSynths = [hashtable]::Synchronized(@{})

function Speak-ProcessEventAsync {
  param(
    [Parameter(Mandatory=$true)][ValidateSet("Started","Stopped")]
    [string] $EventType,

    [Parameter(Mandatory=$true)]
    [string] $ProcessName
  )

  try {
    # Create a dedicated synthesizer per utterance so calls can overlap without blocking
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer

    # Optional: tune voice/volume/rate
    $synth.Volume = 100
    $synth.Rate   = 0

    $id = [guid]::NewGuid().ToString()
    $global:TtsSynths[$id] = $synth

    # Dispose when finished speaking (async completion event)
    Register-ObjectEvent -InputObject $synth -EventName SpeakCompleted -SourceIdentifier "TTS_$id" -MessageData $id -Action {
      $id2 = [string]$Event.MessageData
      $syn = $global:TtsSynths[$id2]
      if ($syn) { try { $syn.Dispose() } catch {} }
      $null = $global:TtsSynths.Remove($id2)
      Unregister-Event -SourceIdentifier ("TTS_" + $id2) -ErrorAction SilentlyContinue
    } | Out-Null

    # Speak asynchronously (does not block the event handler)
    [void]$synth.SpeakAsync("$EventType $ProcessName")
  } catch {
    # Swallow TTS errors so monitoring never breaks
  }
}
# ---------------------------------------------------------------------------


---

2) In the START event action, call TTS right when the event happens

Find your START handler (the one that prints [START] ...). Right after that Write-Host, add:

Speak-ProcessEventAsync -EventType "Started" -ProcessName $pname

Example placement:

Write-Host ("[START] {0} PID={1} {2} | Parent={3} PID={4}" -f `
  $pname, $pid, $start.ToString("HH:mm:ss.fff"),
  ($st.ParentProcessName ?? "Unknown"), ($st.ParentProcessId ?? -1))

Speak-ProcessEventAsync -EventType "Started" -ProcessName $pname


---

3) In the STOP event action, do the same

After your STOP Write-Host line (the one that prints [STOP] ...), add:

Speak-ProcessEventAsync -EventType "Stopped" -ProcessName $pname

Example:

Write-Host ("[STOP]  {0} PID={1} {2} | Ran {3}" -f `
  $pname, $pid, $end.ToString("HH:mm:ss.fff"), $report.Duration)

Speak-ProcessEventAsync -EventType "Stopped" -ProcessName $pname


---

4) Optional cleanup on exit (nice to have)

Inside your finally { ... } block, add this so anything still speaking is disposed:

foreach ($k in @($global:TtsSynths.Keys)) {
  try { $global:TtsSynths[$k].Dispose() } catch {}
  $null = $global:TtsSynths.Remove($k)
  Unregister-Event -SourceIdentifier ("TTS_" + $k) -ErrorAction SilentlyContinue
}


---

Notes (so it behaves the way you want)

This is event-driven for start/stop detection (WMI trace events).

TTS is async (SpeakAsync) and will fire immediately when the event handler runs.

If many processes start quickly, you may hear overlapping speech (because async). If you want a single-voice queue (no overlap), tell me and I’ll give you a queued async speaker runspace.


If you paste your current script version (or tell me its filename), I can return a single consolidated version with these changes already merged.
