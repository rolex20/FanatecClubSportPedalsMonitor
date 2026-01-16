# Debugging tool to see what is being sent by the web browser
 
 # Create a TCP client and connect to localhost:8181
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect("localhost", 8181)

# Get the network stream
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

# Build and send the raw HTTP request
$request = "GET /index.html HTTP/1.1`r`nHost: localhost:8181`r`nConnection: close`r`n`r`n"
$writer.Write($request)
$writer.Flush()

# Read the raw response
# 1. Use ReadToEnd() to get the whole response as one string
# This avoids the "ReadLine" loop and manually adding newlines
$response = "nada" # just a flag
$response = $reader.ReadToEnd()

# 2. Avoid Write-Output if you are just checking the raw data
# Instead, output to a file or use a specific Width to see if it's truly broken

Remove-Item -path "raw_response.json"
$response | Set-Content "raw_response.json"

# OR, if you must print to console, force it to not wrap:

Write-Host $response


# Clean up
$reader.Close()
$writer.Close()
$stream.Close()
$client.Close()
