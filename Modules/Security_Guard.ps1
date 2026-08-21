# Security_Guard.ps1
# Windows PowerShell 5.1 compatible security helpers.
# No secrets are stored here.

if (-not $script:PinodeRateTable) {
    $script:PinodeRateTable = @{}
}

function Test-PiNodeRateLimit {
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$MaxRequests = 30,
        [int]$WindowSeconds = 60
    )
    try {
        $now = Get-Date
        if (-not $script:PinodeRateTable.ContainsKey($Key)) {
            $script:PinodeRateTable[$Key] = New-Object System.Collections.ArrayList
        }
        $list = $script:PinodeRateTable[$Key]
        for ($i = $list.Count - 1; $i -ge 0; $i--) {
            if (($now - [datetime]$list[$i]).TotalSeconds -gt $WindowSeconds) {
                [void]$list.RemoveAt($i)
            }
        }
        if ($list.Count -ge $MaxRequests) {
            return $false
        }
        [void]$list.Add($now)
        return $true
    } catch {
        # Fail closed if the limiter itself cannot be evaluated.
        return $false
    }
}

function Test-PiNodeSafePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        $pathFull = [IO.Path]::GetFullPath($Path)
        return $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-PiNodeContainerName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name.Trim() -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
}
