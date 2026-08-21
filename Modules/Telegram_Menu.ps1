# ============================================================
# Telegram_Menu.ps1
# After ~45s: scan once. If menu missing -> ask /confirmmenu.
# /confirmmenu runs Modules\Set_Bot_Menu.ps1 as Admin with token+chatId.
# ASCII-safe for Windows PowerShell 5.1
# ============================================================

if (-not (Get-Variable -Name MenuBootstrapDone -Scope Script -ErrorAction SilentlyContinue)) {
    $script:MenuBootstrapDone   = $false
    $script:MenuPendingConfirm  = $false
    $script:ControllerStartedAt = Get-Date
}

function Test-PiNodeMenuPresent {
    if (-not (Get-Command Invoke-Telegram -ErrorAction SilentlyContinue)) { return $false }
    try {
        $r = Invoke-Telegram 'getMyCommands' @{}
        if (-not $r -or $r.ok -ne $true) { return $false }
        $list = @($r.result)
        if ($list.Count -lt 5) { return $false }
        $names = @($list | ForEach-Object { [string]$_.command })
        foreach ($c in @('start','status','help','settings','scheduler')) {
            if ($names -notcontains $c) { return $false }
        }
        return $true
    } catch { return $false }
}

function Send-MenuSetupPrompt {
    $msg = @"
TELEGRAM COMMAND MENU - CONFIRM REQUIRED

Controller is stable. Bot command menu is missing or incomplete.

If you approve, the app will run Set_Bot_Menu.ps1 as Administrator
using BotToken + ChatId from Config (no hardcoded secrets).

  /confirmmenu   - load menu now
  /skipmenu      - skip this session

Asked once per Controller start (after ~45 seconds).
After load: close bot chat and reopen, or type /.
"@
    if (Get-Command Send-Text -ErrorAction SilentlyContinue) { Send-Text $msg }
    $script:MenuPendingConfirm = $true
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log 'Telegram Menu: waiting for /confirmmenu'
    }
}

function Invoke-MenuBootstrapOnce {
    if ($script:MenuBootstrapDone) { return }
    if (-not $script:ControllerStartedAt) { $script:ControllerStartedAt = Get-Date }
    if (((Get-Date) - $script:ControllerStartedAt).TotalSeconds -lt 45) { return }

    $script:MenuBootstrapDone = $true

    if (Test-PiNodeMenuPresent) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log 'Telegram Menu: already present - skip prompt'
        }
        return
    }
    try { Send-MenuSetupPrompt } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log ("Telegram Menu prompt error: " + $_.Exception.Message)
        }
    }
}

function Complete-MenuConfirm {
    if (-not $script:MenuPendingConfirm) {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'No pending menu load. (Prompt appears once after ~45s if menu is missing.)'
        }
        return $false
    }

    $token = $null
    $chat  = $null
    try {
        if ($BOT_TOKEN) { $token = [string]$BOT_TOKEN }
        elseif ($BotToken) { $token = [string]$BotToken }
    } catch {}
    try {
        if ($CHAT_ID) { $chat = [string]$CHAT_ID }
        elseif ($ChatId) { $chat = [string]$ChatId }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($chat)) {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'Missing BotToken or ChatId in Config.'
        }
        return $false
    }

    $scriptPath = $null
    try {
        if ($AppRoot) {
            $scriptPath = Join-Path $AppRoot 'Modules\Set_Bot_Menu.ps1'
        }
    } catch {}
    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
        $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\Set_Bot_Menu.ps1'
    }
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'Set_Bot_Menu.ps1 not found under Modules.'
        }
        return $false
    }

    if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
        Send-Text 'Loading menu (Set_Bot_Menu.ps1 may show UAC)...'
    }

    try {
        $argList = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', "`"$scriptPath`""
            '-BotToken', "`"$token`""
            '-ChatId', "`"$chat`""
        )
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ($argList -join ' ')
        $psi.UseShellExecute = $true
        $psi.Verb = 'runas'
        $psi.WorkingDirectory = Split-Path -Parent $scriptPath
        [void][System.Diagnostics.Process]::Start($psi)

        $script:MenuPendingConfirm = $false
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log ("Telegram Menu: launched Set_Bot_Menu.ps1 ChatId=" + $chat)
        }
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'Menu loader started. Accept UAC if shown. Then close/reopen bot chat or type /.'
        }
        return $true
    } catch {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text ("Failed to start Set_Bot_Menu: " + $_.Exception.Message)
        }
        return $false
    }
}

function Skip-MenuConfirm {
    $script:MenuPendingConfirm = $false
    if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
        Send-Text 'Skipped menu load for this session.'
    }
}

function Get-PiNodeStartMenuText {
    @"
PI NODE CONTROLLER PRO

Monitor / maintain / troubleshoot Pi Node via Telegram.

/status /node /peers /report /monitor
/cleanram /maintenance /reset /diagnostic /cancel
/docker /disk /logs /screenshot
/ask /help /settings /scheduler

/reset and /maintenance require Y/N on Live window every time (including after Controller restart).
"@
}
