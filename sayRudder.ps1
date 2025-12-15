#Get-Location
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[$timestamp] Rudder noise detected."

Add-Type -AssemblyName System.speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
$speak.Rate = 3
#$x = $speak.SpeakAsync('Rudder.  Rudder.  Rudder.')
$speak.Speak('Rudder')