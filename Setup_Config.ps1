# ============================================================
# SETUP CONFIG - PI NODE TELEGRAM CONTROLLER
# UTF-8 / Windows PowerShell 5.1 compatible
# ============================================================

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    chcp 65001 | Out-Null
}
catch {
}

$Host.UI.RawUI.WindowTitle = 'Nhap Key - Pi Node Controller'

$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg = Join-Path $AppRoot 'Config\PiNode_Config.ps1'


# ============================================================
# DOC GIA TRI TU FILE CONFIG
# ============================================================

function Read-CfgValue {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Default = ''
    )

    $pattern1 = '\$' + [regex]::Escape($Name) + '\s*=\s*"([^"]*)"'
    $match = [regex]::Match($Content, $pattern1)

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    $pattern2 = "\`$" + [regex]::Escape($Name) + "\s*=\s*'([^']*)'"
    $match = [regex]::Match($Content, $pattern2)

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    $pattern3 = '\$' + [regex]::Escape($Name) + '\s*=\s*(\d+)'
    $match = [regex]::Match($Content, $pattern3)

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $Default
}


# ============================================================
# NHAP DU LIEU
# ============================================================

function Ask {
    param(
        [string]$Label,
        [string]$Current
    )

    Write-Host ''

    Write-Host $Label -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($Current)) {
        Write-Host '    Hien tai: (chua co)' -ForegroundColor DarkGray
    }
    else {
        Write-Host ('    Hien tai: ' + $Current) -ForegroundColor DarkGray
    }

    $Value = Read-Host '    Nhap moi (Enter = giu nguyen)'

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Current
    }

    return $Value.Trim()
}


# ============================================================
# XOA MAN HINH
# ============================================================

Clear-Host


# ============================================================
# TIEU DE
# ============================================================

Write-Host '========================================================' -ForegroundColor Green
Write-Host '       NHAP KEY - PI NODE TELEGRAM CONTROLLER          ' -ForegroundColor Green
Write-Host '       Enter = giu nguyen gia tri hien tai             ' -ForegroundColor Green
Write-Host '========================================================' -ForegroundColor Green

Write-Host ''
Write-Host ('Thu muc: ' + $AppRoot) -ForegroundColor DarkGray
Write-Host ''


# ============================================================
# HUONG DAN TAO KEY
# ============================================================

Write-Host '========== TAO KEY MIEN PHI (neu chua co) ==========' -ForegroundColor Yellow
Write-Host ''

Write-Host '  1) Bot Telegram (BotFather)' -ForegroundColor White
Write-Host '     https://t.me/BotFather' -ForegroundColor Cyan
Write-Host '     Go /newbot -> dat ten -> copy TOKEN' -ForegroundColor DarkGray
Write-Host '     Nhắn 1 tin cho bot, sau do lay Chat ID' -ForegroundColor DarkGray
Write-Host '     Co the dung @userinfobot hoac getUpdates' -ForegroundColor DarkGray

Write-Host ''

Write-Host '  2) Google Gemini API Key' -ForegroundColor White
Write-Host '     https://aistudio.google.com/apikey' -ForegroundColor Cyan
Write-Host '     Dang nhap Google -> Create API key -> copy' -ForegroundColor DarkGray

Write-Host ''
Write-Host '====================================================' -ForegroundColor Yellow
Write-Host ''


# ============================================================
# KIEM TRA FILE CONFIG
# ============================================================

if (-not (Test-Path -LiteralPath $Cfg)) {

    Write-Host '[LOI] Khong tim thay Config\PiNode_Config.ps1' -ForegroundColor Red

    Read-Host 'Nhan Enter de thoat'

    exit 1
}


# ============================================================
# DOC CONFIG
# ============================================================

$c = Get-Content -LiteralPath $Cfg -Raw -Encoding UTF8

$bot  = Read-CfgValue -Content $c -Name 'BotToken'
$chat = Read-CfgValue -Content $c -Name 'ChatId'
$gem  = Read-CfgValue -Content $c -Name 'GeminiApiKey'

$mon = Read-CfgValue `
    -Content $c `
    -Name 'MonitorIntervalMinutes' `
    -Default '60'

$ram = Read-CfgValue `
    -Content $c `
    -Name 'RamAlert' `
    -Default '88'


# ============================================================
# NHAP KEY
# ============================================================

$bot = Ask `
    -Label '[1] Telegram Bot Token' `
    -Current $bot

$chat = Ask `
    -Label '[2] Telegram Chat ID' `
    -Current $chat

$gem = Ask `
    -Label '[3] Google Gemini API Key' `
    -Current $gem

$mon = Ask `
    -Label '[4] Phut giua moi lan kiem tra Node (mac dinh 60)' `
    -Current $mon

$ram = Ask `
    -Label '[5] Nguong canh bao RAM % (mac dinh 88)' `
    -Current $ram


# ============================================================
# GHI CHUOI
# ============================================================

function Set-Str {
    param(
        [string]$Name,
        [string]$Value
    )

    $patternDouble = '\$' + [regex]::Escape($Name) + '\s*=\s*"[^"]*"'
    $replacementDouble = '$' + $Name + ' = "' + $Value + '"'

    $script:c = [regex]::Replace(
        $script:c,
        $patternDouble,
        $replacementDouble
    )

    $patternSingle = "\`$" + [regex]::Escape($Name) + "\s*=\s*'[^']*'"
    $replacementSingle = '$' + $Name + ' = "' + $Value + '"'

    $script:c = [regex]::Replace(
        $script:c,
        $patternSingle,
        $replacementSingle
    )
}


# ============================================================
# GHI SO
# ============================================================

function Set-Num {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -notmatch '^\d+$') {
        return
    }

    $pattern = '\$' + [regex]::Escape($Name) + '\s*=\s*\d+'
    $replacement = '$' + $Name + ' = ' + $Value

    $script:c = [regex]::Replace(
        $script:c,
        $pattern,
        $replacement
    )
}


# ============================================================
# CAP NHAT CONFIG
# ============================================================

Set-Str -Name 'BotToken' -Value $bot
Set-Str -Name 'ChatId' -Value $chat
Set-Str -Name 'GeminiApiKey' -Value $gem

Set-Num -Name 'MonitorIntervalMinutes' -Value $mon
Set-Num -Name 'RamAlert' -Value $ram


# ============================================================
# LUU FILE
# ============================================================

Set-Content `
    -LiteralPath $Cfg `
    -Value $c `
    -Encoding UTF8


# ============================================================
# THONG BAO
# ============================================================

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host '  DA LUU CAU HINH THANH CONG' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''

Read-Host 'Nhan Enter de tiep tuc'

exit 0