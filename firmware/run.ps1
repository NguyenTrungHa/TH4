
$ErrorActionPreference = "Stop"

$pio = "$env:USERPROFILE\.platformio\penv\Scripts\platformio.exe"

Write-Host "1. Building ESP32..."
& $pio run -e esp32dev
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "2. Uploading to ESP32..."
& $pio run -e esp32dev -t upload
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "3. Opening Serial Monitor..."
& $pio device monitor -b 115200
