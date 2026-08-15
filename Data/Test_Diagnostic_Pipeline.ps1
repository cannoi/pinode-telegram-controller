# Local pipeline test. No Telegram, no repair.
$ErrorActionPreference = 'Stop'
$DataDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Diag = Join-Path $DataDir 'Pi_Node_Diagnostic_PRO.ps1'
$Json = Join-Path $DataDir 'diagnostic_latest.json'
if (-not (Test-Path $Diag)) { throw "Missing: $Diag" }
Remove-Item $Json -Force -ErrorAction SilentlyContinue
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Diag
if (-not (Test-Path $Json)) { throw "Diagnostic did not create diagnostic_latest.json" }
$j = Get-Content $Json -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "DIAGNOSTIC PIPELINE OK"
Write-Host "Result: $($j.result)"
Write-Host "Score : $($j.score)/100"
Write-Host "JSON  : $Json"
