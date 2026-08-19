if (Test-Path "$PSScriptRoot/Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1" }
# One-shot - REBUILT collect once, write latest.json, exit
$ErrorActionPreference = "SilentlyContinue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Dot-source is hard with loops; run inline minimal
$DataDir = Split-Path -Parent $Root
$LiveDir = Join-Path $DataDir "PiNodeMonitorLive"
$LatestPath = Join-Path $LiveDir "latest.json"
$NodeHistoryPath = Join-Path $DataDir "node_history.json"
function Get-ConfiguredPiContainerName {
    $default = "testnet2"
    try {
        $f = Join-Path $LiveDir "container_name.txt"
        if (Test-Path -LiteralPath $f) {
            $n = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue).Trim()
            if ($n -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { return $n }
        }
    } catch {}
    return $default
}
$HistDir = Join-Path $LiveDir "history"
New-Item -ItemType Directory -Force -Path $LiveDir, $HistDir | Out-Null
$Dll = $null
foreach ($cand in @((Join-Path $DataDir "assets\OpenHardwareMonitorLib.dll"))) {
    if (Test-Path $cand) { $Dll = $cand; break }
}
function Get-Temp {
    if (-not $Dll -or !(Test-Path $Dll)) { return $null }
    try {
        if (-not ("OpenHardwareMonitor.Hardware.Computer" -as [type])) { Unblock-File $Dll -EA SilentlyContinue; Add-Type -Path $Dll }
        $c = [OpenHardwareMonitor.Hardware.Computer]::new(); $c.CPUEnabled = $true; $c.Open(); $vals = @()
        foreach ($h in @($c.Hardware | Where-Object HardwareType -eq "CPU")) {
            $h.Update(); $vals += @($h.Sensors | Where-Object SensorType -eq "Temperature" | ForEach-Object { if ($null -ne $_.Value) { [double]$_.Value } })
        }
        $c.Close(); if ($vals.Count) { return [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1) }
    } catch {}; return $null
}
$pi = $null; $in = $null; $out = $null
try {
    $raw = docker exec (Get-ConfiguredPiContainerName) /usr/bin/stellar-core --conf /opt/stellar/core/etc/stellar-core.cfg http-command info 2>$null | Out-String
    $i = $raw.IndexOf('{'); if ($i -ge 0) { $pi = ($raw.Substring($i) | ConvertFrom-Json).info }
} catch {}
try {
    $raw = docker exec (Get-ConfiguredPiContainerName) /usr/bin/stellar-core --conf /opt/stellar/core/etc/stellar-core.cfg http-command peers 2>$null | Out-String
    $i = $raw.IndexOf('{')
    if ($i -ge 0) {
        $j = $raw.Substring($i) | ConvertFrom-Json
        $in = @($j.authenticated_peers.inbound).Count; $out = @($j.authenticated_peers.outbound).Count
    }
} catch {}
$cpu = Get-Counter '\Processor(_Total)\% Processor Time' -EA SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -EA SilentlyContinue
$vm = Get-Process vmmem, vmmemWSL -EA SilentlyContinue | Measure-Object WorkingSet64 -Sum
$temp = Get-Temp
$dockerRun = $false
try { if (docker info --format "{{.ServerVersion}}" 2>$null) { $dockerRun = $true } } catch {}
$ctnRun = $false
try { if ((docker ps --format "{{.Names}}" 2>$null) -contains "testnet2") { $ctnRun = $true } } catch {}
$portOk = 0
foreach ($p in @(31401, 31402, 31403)) {
    $listen = [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $listen) {
        try {
            if (netstat -ano 2>$null | Select-String -Pattern (":" + $p + "\s+.*LISTENING")) { $listen = $true }
        } catch {}
    }
    if ($listen) { $portOk++ }
}
$portStr = if ($portOk -eq 3) { 'OPEN' } else { 'CLOSED' }
$now = Get-Date
$record = [ordered]@{
    time = $now.ToString('o'); source = 'PiNodeMonitorLive_CMD'
    data_source = if ($pi) { 'Stellar/Docker' } else { 'Unavailable' }
    sync_raw = if ($pi) { [string]$pi.state } else { 'Unavailable' }
    sync = if ($pi -and $pi.state -eq 'Synced!') { 'Dong bo tot' } else { 'N/A' }
    synced = [bool]($pi -and $pi.state -eq 'Synced!')
    local = if ($pi -and $pi.ledger) { $pi.ledger.num } else { $null }
    latest = if ($pi -and $pi.ledger) { $pi.ledger.num } else { $null }
    ledger_age = if ($pi -and $pi.ledger) { $pi.ledger.age } else { $null }
    incoming = $in; outgoing = $out; peer_in = $in; peer_out = $out
    pi_container = 'testnet2'; docker = if ($dockerRun) { 'RUNNING' } else { 'STOPPED' }; container_status = if ($ctnRun) { 'running' } else { 'stopped' }; port = $portStr
    cpu_sys = if ($cpu) { [math]::Round($cpu.CookedValue, 1) } else { $null }
    ram_sys = if ($os) { [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1) } else { $null }
    temp = $temp
    vmmem_gb = if ($vm -and $vm.Sum) { [math]::Round($vm.Sum / 1GB, 2) } else { $null }
    disk_used = if ($disk -and $disk.Size) { [math]::Round((1 - ($disk.FreeSpace / $disk.Size)) * 100, 1) } else { $null }
    problems = 0; problem_details = @(); severity = 'OK'
}
($record | ConvertTo-Json -Depth 10 -Compress) | Set-Content $LatestPath -Encoding UTF8
$hist = @()
if (Test-Path $NodeHistoryPath) {
    try { $x = Get-Content $NodeHistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($x -is [array]) { $hist = @($x) } elseif ($x) { $hist = @($x) } } catch {}
}
$hist += [pscustomobject]$record
if ($hist.Count -gt 1500) { $hist = @($hist | Select-Object -Last 1500) }
($hist | ConvertTo-Json -Depth 10 -Compress) | Set-Content $NodeHistoryPath -Encoding UTF8
($record | ConvertTo-Json -Depth 10 -Compress) | Add-Content (Join-Path $HistDir ($now.ToString('yyyy-MM-dd') + '.ndjson')) -Encoding UTF8
$record | ConvertTo-Json -Depth 10 -Compress
exit 0

