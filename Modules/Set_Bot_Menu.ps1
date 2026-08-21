# ============================================================
# Set_Bot_Menu.ps1
# setMyCommands (TELE-style) + all_private_chats scope
# Usage: powershell -File Set_Bot_Menu.ps1 -BotToken "..." -ChatId "..."
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$BotToken,

    [Parameter(Mandatory = $true)]
    [string]$ChatId,

    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BotToken) -or $BotToken -notmatch '^\d+:.+$') {
    Write-Host 'ERROR: invalid BotToken.' -ForegroundColor Red
    exit 2
}
if ([string]::IsNullOrWhiteSpace($ChatId)) {
    Write-Host 'ERROR: empty ChatId.' -ForegroundColor Red
    exit 3
}

$API = "https://api.telegram.org/bot$BotToken"

function Invoke-TgForm {
    param([string]$Method, [hashtable]$Data)
    try {
        return Invoke-RestMethod -Uri "$API/$Method" -Method Post -Body $Data -ErrorAction Stop
    } catch {
        Write-Host ("Telegram API Error ($Method): " + $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

$commands = @(
    @{ command = 'start';       description = 'Mo menu Pi Node Controller' }
    @{ command = 'status';      description = 'Trang thai Node' }
    @{ command = 'monitor';     description = 'Xac minh su co' }
    @{ command = 'node';        description = 'Chi tiet Node' }
    @{ command = 'peers';       description = 'Peer In/Out' }
    @{ command = 'report';      description = 'Bao cao he thong' }
    @{ command = 'health';      description = 'Suc khoe Node' }
    @{ command = 'evidence';    description = 'Bang chung moi nhat' }
    @{ command = 'history';     description = 'Lich su' }
    @{ command = 'trends';      description = 'Xu huong + AI' }
    @{ command = 'scheduler';   description = 'Lich tu dong' }
    @{ command = 'settings';    description = 'Cai dat' }
    @{ command = 'docker';      description = 'Docker' }
    @{ command = 'disk';        description = 'O dia' }
    @{ command = 'logs';        description = 'Logs' }
    @{ command = 'diagnostic';  description = 'Chan doan' }
    @{ command = 'cleanram';    description = 'Don RAM' }
    @{ command = 'maintenance'; description = 'Bao tri (Live Y/N)' }
    @{ command = 'reset';       description = 'Reset (Live Y/N)' }
    @{ command = 'ask';         description = 'Hoi AI' }
    @{ command = 'help';        description = 'Tro giup' }
    @{ command = 'cancel';      description = 'Huy thao tac' }
)

$json = $commands | ConvertTo-Json -Compress -Depth 5

# Clear then set default scope
$null = Invoke-TgForm 'deleteMyCommands' @{}
Start-Sleep -Milliseconds 400
$r1 = Invoke-TgForm 'setMyCommands' @{ commands = $json }

# Also set for all private chats (helps some clients refresh)
$scopePrivate = '{"type":"all_private_chats"}'
$r2 = Invoke-TgForm 'setMyCommands' @{ commands = $json; scope = $scopePrivate }

# Chat-specific scope for this user
$scopeChat = ('{"type":"chat","chat_id":' + $ChatId + '}')
$r3 = Invoke-TgForm 'setMyCommands' @{ commands = $json; scope = $scopeChat }

$ok = ($r1 -and $r1.ok) -or ($r2 -and $r2.ok) -or ($r3 -and $r3.ok)

if ($ok) {
    if (-not $Silent) {
        Write-Host ("OK: setMyCommands - " + $commands.Count + " commands.") -ForegroundColor Green
        $helpText = @"
Menu da nap ($($commands.Count) lenh).

De THAY menu trong chat:
1) Thoat HAN app Telegram (vuot tat / Force stop)
2) Mo lai Telegram
3) Mo chat bot, go dau /

Hoac: BotFather -> /mybots -> bot -> Edit Bot -> Edit Commands (kiem tra da co lenh).

Luu y: Telegram hay cache menu; API da thanh cong khong dong nghia client hien ngay.
"@
        $null = Invoke-TgForm 'sendMessage' @{
            chat_id = $ChatId
            text    = $helpText
            disable_web_page_preview = 'true'
        }
    }
    exit 0
}

Write-Host 'FAIL: setMyCommands failed.' -ForegroundColor Red
exit 1
