# Pi Node Diagnostic - PowerShell
$ErrorActionPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Output "==== Pi Node Diagnostic ===="
Write-Output "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

try {
    $dv = docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' 2>$null
    Write-Output "Docker: $dv"
} catch { Write-Output "Docker: N/A" }

try {
    $ps = docker ps --format '{{.Names}} | {{.Status}}' 2>$null
    if ($ps) { Write-Output "Containers:"; $ps | ForEach-Object { Write-Output "  $_" } }
    else { Write-Output "Containers: none" }
} catch { Write-Output "Containers: N/A" }

foreach ($port in 31401, 31402, 31403) {
    try {
        $ok = (Test-NetConnection 127.0.0.1 -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded
        Write-Output "Port $port : $ok"
    } catch { Write-Output "Port $port : error" }
}

$hist = Join-Path $ScriptDir 'node_history.json'
if (Test-Path -LiteralPath $hist) {
    try {
        $x = Get-Content -LiteralPath $hist -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($x -is [array]) { $last = $x[-1] } else { $last = $x }
        Write-Output "Last history:"
        Write-Output ($last | ConvertTo-Json -Depth 5 -Compress)
    } catch { Write-Output "History read error" }
} else {
    Write-Output "No node_history.json"
}

Write-Output "[OK] Diagnostic completed."
exit 0
