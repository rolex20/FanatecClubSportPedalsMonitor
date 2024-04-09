﻿#Get-Location
Write-Host "    Timestamp: " -NoNewline
Get-Date -Format "MM/dd/yyyy HH:mm:ss"  
Add-Type -AssemblyName System.speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
$speak.Rate = 3
#$x = $speak.SpeakAsync('Rudder.  Rudder.  Rudder.')
$speak.Speak('Rudder')