param (
    [string]$percentage = "0"
)
#Get-Location
#$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
#Write-Output "[$timestamp] Gas pedal only reaching $percentage% "

Add-Type -AssemblyName System.speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
$speak.Rate = 1
$speak.Speak("Gas " + $percentage + " percent")