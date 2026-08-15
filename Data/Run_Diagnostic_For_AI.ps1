# PowerShell 5.1
$ErrorActionPreference = 'SilentlyContinue'
$DataDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Diag = Join-Path $DataDir 'Pi_Node_Diagnostic_PRO.ps1'
$Json = Join-Path $DataDir 'diagnostic_latest.json'
if (-not (Test-Path -LiteralPath $Diag)) { exit 2 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Diag | Out-Null
if (Test-Path -LiteralPath $Json) {
    Get-Content -LiteralPath $Json -Raw -Encoding UTF8
    exit 0
}
exit 3
