# Gui bao cao bao tri qua Telegram - doc BOT TOKEN / CHAT ID tu Config trung tam
param(
    [string]$DockerStatus = "N/A",
    [string]$PiStatus = "N/A",
    [string]$MonthlyStatus = "N/A",
    [string]$TimeStr = ""
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot = Split-Path -Parent $ScriptDir
$ConfigFile = Join-Path $AppRoot 'Config\PiNode_Config.ps1'

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    Write-Host "Khong tim thay Config: $ConfigFile"
    exit 1
}

. $ConfigFile

if ([string]::IsNullOrWhiteSpace($BotToken) -or [string]::IsNullOrWhiteSpace($ChatId)) {
    Write-Host "Chua cau hinh BotToken / ChatId trong Config"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($TimeStr)) {
    $TimeStr = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
}

$text = @"
✅ PI NODE - BAO TRI HOAN TAT

🕐 $TimeStr
🐳 Docker: $DockerStatus
🔷 Pi Network: $PiStatus
📅 Bao tri thang: $MonthlyStatus

Chi tiet log: Data\pinode_safe_maintenance.log
"@

try {
    $uri = "https://api.telegram.org/bot$BotToken/sendMessage"
    $body = @{
        chat_id = $ChatId
        text    = $text
        disable_web_page_preview = 'true'
    }
    Invoke-RestMethod -Uri $uri -Method Post -Body $body -TimeoutSec 30 | Out-Null
    Write-Host "Da gui bao cao Telegram."
    exit 0
} catch {
    Write-Host "Gui Telegram loi: $($_.Exception.Message)"
    exit 2
}
