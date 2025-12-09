param (
    [string]$percentage = "0"
)
Add-Type -AssemblyName System.speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
$speak.Rate = 1
$speak.Speak("Gas " + $percentage + " percent")