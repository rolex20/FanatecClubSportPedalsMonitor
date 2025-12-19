param (
    [string]$text = "Alert[]"
)

$text = $text.Trim()
#$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
#Write-Output "[$timestamp] [$text]"

Add-Type -AssemblyName System.speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Adult)
$speak.Rate = 0
$speak.Speak($text)