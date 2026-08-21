# ============================================================
# Admin_Elevate.ps1 - Elevate to Administrator once
# Windows PowerShell 5.1 - ASCII-safe
# ============================================================

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Confirm-AdminRights {
    param(
        [string]$ScriptPath = $null,
        [string[]]$ExtraArgs = @()
    )

    if (Test-IsAdministrator) {
        return $true
    }

    if ($env:PINODE_ELEVATED -eq '1') {
        Write-Warning 'Confirm-AdminRights: elevate tried but still not Admin.'
        return $false
    }

    try {
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
            $ScriptPath = $MyInvocation.PSCommandPath
            if ([string]::IsNullOrWhiteSpace($ScriptPath) -and $PSCommandPath) {
                $ScriptPath = $PSCommandPath
            }
        }
        if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
            Write-Warning 'Confirm-AdminRights: cannot resolve script path.'
            return $false
        }

        $argList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$ScriptPath`""
        ) + $ExtraArgs

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ($argList -join ' ')
        $psi.Verb = 'runas'
        $psi.UseShellExecute = $true
        $psi.WorkingDirectory = Split-Path -Parent $ScriptPath

        [Environment]::SetEnvironmentVariable('PINODE_ELEVATED', '1', 'Process')
        [void][System.Diagnostics.Process]::Start($psi)
        exit 0
    } catch {
        Write-Warning ("Confirm-AdminRights: elevate failed - " + $_.Exception.Message)
        return $false
    }
}
