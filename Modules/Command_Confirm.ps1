# ============================================================
# Command_Confirm.ps1
# Shell confirm via Telegram; reset/maintenance via Live window (NON-BLOCKING)
# Windows PowerShell 5.1 - ASCII-safe
# ============================================================

if (-not (Get-Variable -Name PendingShell -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PendingShell = $false
    $script:PendingShellAt = $null
    $script:PendingShellType = $null
    $script:PendingShellCommand = $null
}

if (-not (Get-Variable -Name LiveConfirmPending -Scope Script -ErrorAction SilentlyContinue)) {
    $script:LiveConfirmPending = $false
    $script:LiveConfirmRequestId = $null
    $script:LiveConfirmAction = $null
    $script:LiveConfirmDeadline = $null
    $script:LiveConfirmShellType = $null
    $script:LiveConfirmShellCommand = $null
}

function Test-TelegramAuthorized {
    param([string]$ChatIdFromMessage)
    if ([string]::IsNullOrWhiteSpace($ChatIdFromMessage)) { return $false }
    $allowed = $null
    try {
        if ($CHAT_ID) { $allowed = [string]$CHAT_ID }
        elseif ($AllowedChatID) { $allowed = [string]$AllowedChatID }
        elseif ($ChatId) { $allowed = [string]$ChatId }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($allowed)) { return $false }
    return ($ChatIdFromMessage -eq $allowed)
}

function Get-LivePendingPaths {
    $root = $null
    try {
        if ($DataDir) { $root = $DataDir }
        elseif ($AppRoot) { $root = Join-Path $AppRoot 'Data' }
        elseif ($BASE_DIR) { $root = Join-Path $BASE_DIR 'Data' }
    } catch {}
    if (-not $root) {
        try { $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'Data' } catch { $root = 'Data' }
    }
    $liveDir = Join-Path $root 'PiNodeMonitorLive'
    New-Item -ItemType Directory -Path $liveDir -Force -ErrorAction SilentlyContinue | Out-Null
    return @{
        LiveDir = $liveDir
        Pending = (Join-Path $liveDir 'pending_action.json')
        Result  = (Join-Path $liveDir 'pending_action_result.json')
    }
}

function Start-LiveWindowConfirm {
    <#
    .SYNOPSIS
        NON-BLOCKING: write pending_action.json and return immediately.
        Main loop must call Complete-LiveWindowConfirmTick to finish.
        Action: reset | maintenance | ps | cmd
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Action,
        [int]$TimeoutSec = 90,
        [string]$ShellType = $null,
        [string]$ShellCommand = $null
    )

    if ($script:LiveConfirmPending) {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'Another Live confirm is still pending. Send /cancel first.'
        }
        return $false
    }

    $paths = Get-LivePendingPaths
    $requestId = [guid]::NewGuid().ToString('N')
    $expires = (Get-Date).AddSeconds($TimeoutSec).ToString('o')

    try { Remove-Item -LiteralPath $paths.Result  -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $paths.Pending -Force -ErrorAction SilentlyContinue } catch {}

    $req = @{
        requestId  = $requestId
        action     = $Action
        title      = $Title
        body       = $Body
        timeoutSec = $TimeoutSec
        expiresAt  = $expires
        createdAt  = (Get-Date).ToString('o')
        shellType  = $ShellType
        shellCommand = $ShellCommand
    }
    ($req | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $paths.Pending -Encoding UTF8

    $script:LiveConfirmPending = $true
    $script:LiveConfirmRequestId = $requestId
    $script:LiveConfirmAction = $Action
    $script:LiveConfirmDeadline = (Get-Date).AddSeconds($TimeoutSec + 5)
    $script:LiveConfirmShellType = $ShellType
    $script:LiveConfirmShellCommand = $ShellCommand

    if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
        $hint = @"
$Title
----------------
$Body

Confirm on Pi Node Monitor Live window (CMD):
  Press Y = approve
  Press N = cancel
  Timeout: ${TimeoutSec}s

Controller keeps responding to other commands while waiting.
Send /cancel to abort this confirm.
"@
        Send-Text $hint
    }
    return $true
}

function Complete-LiveWindowConfirmTick {
    <#
    .SYNOPSIS
        Call every main-loop iteration. If user pressed Y/N on Live (or timeout), run action.
        Never blocks more than a few ms.
    #>
    if (-not $script:LiveConfirmPending) { return }

    $paths = Get-LivePendingPaths
    $done = $false
    $approved = $false

    if (Test-Path -LiteralPath $paths.Result) {
        try {
            $res = Get-Content -LiteralPath $paths.Result -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($res -and [string]$res.requestId -eq [string]$script:LiveConfirmRequestId) {
                $approved = [bool]$res.approved
                $done = $true
            }
        } catch {}
        try { Remove-Item -LiteralPath $paths.Result  -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $paths.Pending -Force -ErrorAction SilentlyContinue } catch {}
    }

    if (-not $done -and $script:LiveConfirmDeadline -and ((Get-Date) -gt $script:LiveConfirmDeadline)) {
        $done = $true
        $approved = $false
        try { Remove-Item -LiteralPath $paths.Pending -Force -ErrorAction SilentlyContinue } catch {}
    }

    if (-not $done) { return }

    $action = $script:LiveConfirmAction
    $script:LiveConfirmPending = $false
    $script:LiveConfirmRequestId = $null
    $script:LiveConfirmAction = $null
    $script:LiveConfirmDeadline = $null

    if (-not $approved) {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'Cancelled (Live window: N or timeout).'
        }
        return
    }

    if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
        Send-Text 'Running...'
    }
    try {
        if ($action -eq 'ps' -or $action -eq 'cmd') {
            $st = $script:LiveConfirmShellType
            $sc = $script:LiveConfirmShellCommand
            $script:LiveConfirmShellType = $null
            $script:LiveConfirmShellCommand = $null
            if (Get-Command Invoke-ShellCommand -ErrorAction SilentlyContinue) {
                Invoke-ShellCommand -ShellType $st -CommandText $sc
            } else {
                if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
                    Send-Text 'Invoke-ShellCommand not found.'
                }
            }
        } else {
            $key = if ($action -eq 'reset') { '/reset' } else { '/maintenance' }
            if (Get-Command Invoke-RegisteredProgram -ErrorAction SilentlyContinue) {
                Invoke-RegisteredProgram $key
            } else {
                if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
                    Send-Text ("Invoke-RegisteredProgram not found for " + $key)
                }
            }
        }
    } catch {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text ("Action failed: " + $_.Exception.Message)
        }
    }
}

function Request-ShellConfirmOnce {
    param(
        [Parameter(Mandatory)][ValidateSet('cmd','ps')][string]$ShellType,
        [Parameter(Mandatory)][string]$CommandText
    )
    $timeout = 120
    try { if ($ConfirmTimeout -gt 0) { $timeout = [int]$ConfirmTimeout } } catch {}

    $script:PendingShell = $true
    $script:PendingShellAt = Get-Date
    $script:PendingShellType = $ShellType
    $script:PendingShellCommand = $CommandText

    $msg = @"
REMOTE COMMAND - CONFIRM REQUIRED
----------------
[$($ShellType.ToUpperInvariant())] $CommandText

Send /confirmshell within $timeout seconds to run.
Send /cancel to abort.
"@
    if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
        Send-Text $msg
    }
}

function Complete-ShellConfirmOnce {
    param([scriptblock]$InvokeShell)

    $timeout = 120
    try { if ($ConfirmTimeout -gt 0) { $timeout = [int]$ConfirmTimeout } } catch {}

    if (-not $script:PendingShell -or -not $script:PendingShellAt) {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'No pending /ps or /cmd confirm.'
        }
        return $false
    }

    $elapsed = ((Get-Date) - $script:PendingShellAt).TotalSeconds
    if ($elapsed -gt $timeout) {
        $script:PendingShell = $false
        $script:PendingShellAt = $null
        $script:PendingShellType = $null
        $script:PendingShellCommand = $null
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text 'Confirm timed out. Send /ps or /cmd again.'
        }
        return $false
    }

    $st = $script:PendingShellType
    $sc = $script:PendingShellCommand
    $script:PendingShell = $false
    $script:PendingShellAt = $null
    $script:PendingShellType = $null
    $script:PendingShellCommand = $null

    if ($InvokeShell) {
        & $InvokeShell $st $sc
    } elseif (Get-Command Invoke-ShellCommand -ErrorAction SilentlyContinue) {
        Invoke-ShellCommand -ShellType $st -CommandText $sc
    } else {
        if (Get-Command Send-Text -ErrorAction SilentlyContinue) {
            Send-Text ("Invoke-ShellCommand not found. Command: [$st] $sc")
        }
        return $false
    }
    return $true
}

function Request-DangerousActionConfirm {
    <#
    .SYNOPSIS
        NON-BLOCKING start of Live confirm for reset/maintenance.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('reset','maintenance')][string]$Action,
        [string]$Title = $null,
        [string]$Body = $null,
        [int]$TimeoutSec = 90
    )
    if (-not $Title) {
        $Title = if ($Action -eq 'reset') {
            'RESET NETWORK + NODE - CONFIRM'
        } else {
            'SYSTEM MAINTENANCE - CONFIRM'
        }
    }
    if (-not $Body) {
        $Body = if ($Action -eq 'reset') {
            'Dangerous: reset network + Node + Docker/WSL. Confirm only if sure.'
        } else {
            'Runs periodic maintenance (cleanup, Docker, DNS, TRIM...). Confirm on Live window.'
        }
    }

    return (Start-LiveWindowConfirm -Title $Title -Body $Body -Action $Action -TimeoutSec $TimeoutSec)
}


function Request-ShellLiveConfirm {
    param(
        [Parameter(Mandatory)][ValidateSet('cmd','ps')][string]$ShellType,
        [Parameter(Mandatory)][string]$CommandText,
        [int]$TimeoutSec = 90
    )
    $title = 'REMOTE ' + $ShellType.ToUpperInvariant() + ' - CONFIRM ON LIVE WINDOW'
    $body = "Will run: [$ShellType] $CommandText`nPress Y on Live window to run, N to cancel."
    return (Start-LiveWindowConfirm -Title $title -Body $body -Action $ShellType -TimeoutSec $TimeoutSec -ShellType $ShellType -ShellCommand $CommandText)
}

function Cancel-PendingConfirms {
    $script:PendingShell = $false
    $script:PendingShellAt = $null
    $script:PendingShellType = $null
    $script:PendingShellCommand = $null
    $script:LiveConfirmPending = $false
    $script:LiveConfirmRequestId = $null
    $script:LiveConfirmAction = $null
    $script:LiveConfirmDeadline = $null
    $script:LiveConfirmShellType = $null
    $script:LiveConfirmShellCommand = $null
    $paths = Get-LivePendingPaths
    try { Remove-Item -LiteralPath $paths.Pending -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $paths.Result  -Force -ErrorAction SilentlyContinue } catch {}
}
