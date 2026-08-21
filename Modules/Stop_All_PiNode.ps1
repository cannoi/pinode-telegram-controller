# ============================================================
# Stop_All_PiNode.ps1
# Stop all Pi Node Controller PRO related processes
# ASCII-safe
# ============================================================

function Stop-AllPiNodeRelated {
    param(
        [switch]$IncludeSelf,
        [string]$Reason = 'user_request'
    )

    $patterns = @(
        'PiNode_Telegram_Controller_PRO',
        'PiNodeMonitorLive\.ps1',
        'PiNodeMonitorLive_Service\.ps1',
        'PiNodeMonitorLive_Once\.ps1',
        'Set_Bot_Menu\.ps1'
    )

    $killed = @()
    $myPid = $PID

    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $myPid -and
                $_.CommandLine -and
                ($patterns | Where-Object { $_.CommandLine -match $_ })
            }
        foreach ($proc in @($procs)) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                $killed += (($proc.ProcessId).ToString() + ':' + $proc.Name)
            } catch {}
        }
    } catch {}

    $roots = @()
    try { if ($AppRoot) { $roots += $AppRoot } } catch {}
    try { if ($BASE_DIR) { $roots += $BASE_DIR } } catch {}
    try { if ($DataDir) { $roots += (Split-Path -Parent $DataDir) } } catch {}
    $roots = $roots | Select-Object -Unique

    foreach ($root in $roots) {
        $pidFiles = @(
            (Join-Path $root 'State\controller.pid'),
            (Join-Path $root 'Data\PiNodeMonitorLive\live_service.pid')
        )
        foreach ($pf in $pidFiles) {
            try {
                if (Test-Path -LiteralPath $pf) {
                    $oldPid = 0
                    try { $oldPid = [int]((Get-Content -LiteralPath $pf -Raw).Trim()) } catch {}
                    if ($oldPid -gt 0 -and $oldPid -ne $myPid) {
                        try { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue } catch {}
                    }
                    Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log ("Stop-AllPiNodeRelated reason=" + $Reason + " killed=" + ($killed -join ','))
    }

    if ($IncludeSelf) {
        try {
            if (Get-Command Cleanup-Controller -ErrorAction SilentlyContinue) {
                Cleanup-Controller
            }
        } catch {}
        Start-Sleep -Milliseconds 300
        exit 0
    }

    return $killed
}
