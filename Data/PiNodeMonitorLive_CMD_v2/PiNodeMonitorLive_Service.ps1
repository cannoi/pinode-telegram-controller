if (Test-Path "$PSScriptRoot/Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1" }
# PiNodeMonitorLive_Service.ps1
# Background - SAME REBUILT collect standard as PiNodeMonitorLive.ps1
param([switch]$ShowWindow)
$ErrorActionPreference = "SilentlyContinue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# App Data root = parent of CMD_v2 folder
$DataDir = Split-Path -Parent $Root
$AppRoot = Split-Path -Parent $DataDir

function Get-ConfiguredPiContainerName {
    $default = "testnet2"
    try {
        $f = Join-Path $DataDir "PiNodeMonitorLive\container_name.txt"
        if (Test-Path -LiteralPath $f) {
            $n = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue).Trim()
            if ($n -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { return $n }
        }
    } catch {}
    return $default
}
$LiveDir = Join-Path $DataDir "PiNodeMonitorLive"
$HistDir = Join-Path $LiveDir "history"
$HourlyDir = Join-Path $LiveDir "hourly"
$DailyDir = Join-Path $LiveDir "daily"
$LatestPath = Join-Path $LiveDir "latest.json"
$NodeHistoryPath = Join-Path $DataDir "node_history.json"
$PidPath = Join-Path $LiveDir "live_service.pid"

# Temperature DLL (keep old Data copy)
$Dll = $null
foreach ($cand in @(
        (Join-Path $DataDir "assets\OpenHardwareMonitorLib.dll")
    )) {
    if (Test-Path -LiteralPath $cand) { $Dll = $cand; break }
}

New-Item -ItemType Directory -Force -Path $LiveDir, $HistDir, $HourlyDir, $DailyDir | Out-Null
try { Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII } catch {}

# REBUILT State shape
$State = [ordered]@{
    Source = "Starting"
    Node = "Unavailable"; Ledger = $null; Age = $null; In = $null; Out = $null
    CPU = $null; RAM = $null; Temp = $null; Disk = $null; Vmmem = $null
    DesktopState = "Unavailable"; DesktopBlock = $null; DesktopLatest = $null
    DesktopAvailability = $null; DesktopSwitch = $null
    Ports = "not checked"
    Docker = "UNKNOWN"
    Container = $null
    ContainerStatus = $null
    Updated = ""
    Anomaly = "Starting"
}

function Get-TextFromClipboard {
    try { return (Get-Clipboard -Raw -ErrorAction Stop) } catch { return "" }
}

function Get-PiDesktopProcess {
    Get-Process -Name "Pi Network" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
}

function Bring-PiDesktopFront {
    $p = Get-PiDesktopProcess
    if (!$p) { return $false }
    try {
        if (-not ("PiWinApi" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PiWinApi {
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@
        }
        [PiWinApi]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
        [PiWinApi]::BringWindowToTop($p.MainWindowHandle) | Out-Null
        [PiWinApi]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        return $true
    } catch { return $false }
}

function Parse-PiDesktopText($text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $o = [ordered]@{}
    foreach ($m in [regex]::Matches($text, '(?im)^\s*([^:\r\n]+?)\s*:\s*(.+?)\s*$')) {
        $k = $m.Groups[1].Value.Trim()
        $v = $m.Groups[2].Value.Trim()
        if ($k) { $o[$k] = $v }
    }
    return [pscustomobject]$o
}

function Get-PiDesktopClipboard {
    # REBUILT: NEVER clears clipboard, NEVER clicks, NEVER Ctrl+A/C.
    # Only works if clipboard already has selectable Pi Desktop text.
    if (!(Bring-PiDesktopFront)) { return $null }
    Start-Sleep -Milliseconds 250
    $t = Get-TextFromClipboard
    if ($t -match 'State:\s*(Synced!|Syncing|Not synced)|Incoming connections|Outgoing connections|Local block number') {
        return $t
    }
    return $null
}

function Get-PiInfoDocker {
    try {
        $ctn = Get-ConfiguredPiContainerName
        $raw = docker exec $ctn /usr/bin/stellar-core --conf /opt/stellar/core/etc/stellar-core.cfg http-command info 2>$null | Out-String
        $i = $raw.IndexOf('{'); if ($i -lt 0) { return $null }
        return ($raw.Substring($i) | ConvertFrom-Json).info
    } catch { return $null }
}

function Get-PeersDocker {
    try {
        $ctn = Get-ConfiguredPiContainerName
        $raw = docker exec $ctn /usr/bin/stellar-core --conf /opt/stellar/core/etc/stellar-core.cfg http-command peers 2>$null | Out-String
        $i = $raw.IndexOf('{'); if ($i -lt 0) { return $null }
        $j = $raw.Substring($i) | ConvertFrom-Json
        return [pscustomobject]@{
            In  = @($j.authenticated_peers.inbound).Count
            Out = @($j.authenticated_peers.outbound).Count
        }
    } catch { return $null }
}

function Get-Temp {
    if (-not $Dll -or !(Test-Path $Dll)) { return $null }
    try {
        if (-not ("OpenHardwareMonitor.Hardware.Computer" -as [type])) {
            Unblock-File $Dll -ErrorAction SilentlyContinue
            Add-Type -Path $Dll
        }
        $c = [OpenHardwareMonitor.Hardware.Computer]::new()
        $c.CPUEnabled = $true; $c.Open()
        $vals = @()
        foreach ($h in @($c.Hardware | Where-Object HardwareType -eq "CPU")) {
            $h.Update()
            $vals += @($h.Sensors | Where-Object SensorType -eq "Temperature" | ForEach-Object {
                    if ($null -ne $_.Value) { [double]$_.Value }
                })
        }
        $c.Close()
        if ($vals.Count) { return [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1) }
    } catch {}
    return $null
}

function Get-HardwareSnapshot {
    $cpu = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty CounterSamples | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    $vm = Get-Process vmmem, vmmemWSL -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum
    [pscustomobject]@{
        CPU   = if ($cpu) { [math]::Round($cpu.CookedValue, 1) } else { $null }
        RAM   = if ($os) { [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1) } else { $null }
        Temp  = Get-Temp
        Disk  = if ($disk -and $disk.Size) { [math]::Round((1 - ($disk.FreeSpace / $disk.Size)) * 100, 1) } else { $null }
        Vmmem = if ($vm -and $vm.Sum) { [math]::Round($vm.Sum / 1GB, 2) } else { $null }
        DiskFreeGB = if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 2) } else { $null }
    }
}


function Get-DockerStatus {
    # Docker health: is daemon up + is the configured Pi Node container running?
    $daemon = $false
    $ctn = $null
    $ctnStatus = $null
    $wanted = Get-ConfiguredPiContainerName
    try {
        $v = docker info --format "{{.ServerVersion}}" 2>$null
        if ($v) { $daemon = $true }
    } catch {}
    if ($daemon) {
        try {
            $names = @(docker ps --format "{{.Names}}" 2>$null)
            if ($names -contains $wanted) {
                $ctn = $wanted
                $ctnStatus = "running"
            } else {
                $all = @(docker ps -a --format "{{.Names}} {{.Status}}" 2>$null | Where-Object { $_ -match ("(?i)^" + [regex]::Escape($wanted) + "\s") })
                if ($all) {
                    $ctn = $wanted
                    $ctnStatus = if ($all[0] -match "(?i)Up") { "running" } else { "stopped" }
                }
            }
        } catch {}
    }
    return [pscustomobject]@{
        Docker    = if ($daemon) { "RUNNING" } else { "STOPPED" }
        Container = $ctn
        Status    = $ctnStatus
    }
}

function Get-PortSnapshot {
    # Controller (/status /report) expects exactly: port = "OPEN" | "CLOSED"
    # OPEN  = all of 31401,31402,31403 are LISTEN
    # CLOSED = any port not listening
    $ports = @(31401, 31402, 31403)
    $okCount = 0
    foreach ($p in $ports) {
        $listen = $false
        try {
            $listen = [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1)
        } catch {}
        if (-not $listen) {
            try {
                $line = netstat -ano 2>$null | Select-String -Pattern (":" + $p + "\s+.*LISTENING") | Select-Object -First 1
                if ($line) { $listen = $true }
            } catch {}
        }
        if ($listen) { $okCount++ }
    }
    if ($okCount -eq $ports.Count) { return "OPEN" }
    return "CLOSED"
}


function Update-NodeData {
    # 1) PRIMARY: Stellar-Core via Docker (stable, no UI interference)
    $pi = Get-PiInfoDocker
    $peers = Get-PeersDocker
    if ($pi) {
        $State.Source = "Stellar/Docker"
        $State.Node = $pi.state
        if ($pi.ledger) {
            $State.Ledger = $pi.ledger.num
            $State.Age = $pi.ledger.age
        }
        if ($peers) { $State.In = $peers.In; $State.Out = $peers.Out }
        return
    }

    # 2) OPTIONAL fallback: Pi Desktop clipboard (only if already selectable)
    # Does NOT Ctrl+A/C, does NOT clear clipboard - avoids UI errors.
    $dt = Get-PiDesktopClipboard
    $parsed = Parse-PiDesktopText $dt
    if ($parsed) {
        $State.Source = "Pi Desktop"
        if ($parsed.PSObject.Properties.Name -contains "State") { $State.DesktopState = $parsed.State; $State.Node = $parsed.State }
        if ($parsed.PSObject.Properties.Name -contains "Outgoing connections") { $State.Out = [int]$parsed.'Outgoing connections' }
        if ($parsed.PSObject.Properties.Name -contains "Incoming connections") { $State.In = [int]$parsed.'Incoming connections' }
        if ($parsed.PSObject.Properties.Name -contains "Local block number") { $State.DesktopBlock = [int64]$parsed.'Local block number'; $State.Ledger = $State.DesktopBlock }
        if ($parsed.PSObject.Properties.Name -contains "Latest block number") { $State.DesktopLatest = [int64]$parsed.'Latest block number' }
        if ($parsed.PSObject.Properties.Name -contains "Availability (up to 90 days)") { $State.DesktopAvailability = $parsed.'Availability (up to 90 days)' }
        return
    }

    # 3) Keep last-known; never invent zeros
    $State.Source = "Unavailable"
}

function Detect-Anomaly {
    $issues = @()
    if ($State.Node -and $State.Node -ne "Synced!" -and $State.Node -ne "Unavailable") { $issues += "Node=$($State.Node)" }
    if ($null -ne $State.Age -and $State.Age -ge 30) { $issues += "Ledger age $($State.Age)s" }
    if ($null -ne $State.CPU -and $State.CPU -ge 90) { $issues += "CPU $($State.CPU)%" }
    if ($null -ne $State.RAM -and $State.RAM -ge 90) { $issues += "RAM $($State.RAM)%" }
    if ($null -ne $State.Temp -and $State.Temp -ge 85) { $issues += "CPU temp $($State.Temp)C" }
    if ($issues.Count) { return ($issues -join "; ") }
    return "Normal"
}

function Save-MonitorData {
    try {
        $now = Get-Date
        $synced = ($State.Node -eq 'Synced!')
        $anomalyText = [string]$State.Anomaly
        $severity = if ($anomalyText -eq 'Normal' -or [string]::IsNullOrWhiteSpace($anomalyText)) { 'OK' }
                    elseif ($State.Source -eq 'Unavailable') { 'CRITICAL' } else { 'WARNING' }
        $problems = @()
        if ($anomalyText -and $anomalyText -ne 'Normal') { $problems = @($anomalyText -split ';\s*') }

        $record = [ordered]@{
            time = $now.ToString('o')
            source = 'PiNodeMonitorLive_CMD'
            data_source = $State.Source
            sync = if ($synced) { 'Dong bo tot' } elseif ($State.Node -match '(?i)sync') { 'Dang dong bo' } elseif ($State.Node -and $State.Node -ne 'Unavailable') { 'Chua dong bo' } else { 'N/A' }
            sync_raw = $State.Node
            synced = $synced
            local = $State.Ledger
            latest = if ($null -ne $State.DesktopLatest) { $State.DesktopLatest } else { $State.Ledger }
            ledger_age = $State.Age
            incoming = $State.In
            outgoing = $State.Out
            peer_in = $State.In
            peer_out = $State.Out
            availability = $State.DesktopAvailability
            desktop_state = $State.DesktopState
            desktop_block = $State.DesktopBlock
            desktop_latest = $State.DesktopLatest
            pi_container = if ($State.Container) { $State.Container } else { (Get-ConfiguredPiContainerName) }
            docker = $State.Docker
            container_status = $State.ContainerStatus
            port = $State.Ports
            cpu_sys = $State.CPU
            ram_sys = $State.RAM
            temp = $State.Temp
            vmmem_gb = $State.Vmmem
            disk_used = $State.Disk
            anomaly = $anomalyText
            problems = $problems.Count
            problem_details = @($problems)
            severity = $severity
        }

        ($record | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath $LatestPath -Encoding UTF8

        $dayFile = Join-Path $HistDir ($now.ToString('yyyy-MM-dd') + '.ndjson')
        ($record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $dayFile -Encoding UTF8
        Get-ChildItem $HistDir -Filter '*.ndjson' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $now.AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

        $hist = @()
        if (Test-Path $NodeHistoryPath) {
            try {
                $x = Get-Content $NodeHistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($x -is [array]) { $hist = @($x) } elseif ($x) { $hist = @($x) }
            } catch {}
        }
        $hist += [pscustomobject]$record
        if ($hist.Count -gt 1500) { $hist = @($hist | Select-Object -Last 1500) }
        ($hist | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath $NodeHistoryPath -Encoding UTF8

        try {
            $archiveDir = Join-Path $DataDir 'History\Node'
            New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
            $archive = Join-Path $archiveDir ("NodeHistory_{0}.ndjson" -f $now.ToString('yyyy-MM-dd'))
            ($record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $archive -Encoding UTF8
            Get-ChildItem $archiveDir -Filter 'NodeHistory_*.ndjson' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $now.AddDays(-45) } | Remove-Item -Force -ErrorAction SilentlyContinue
        } catch {}

        try {
            $hourFile = Join-Path $HourlyDir ($now.ToString('yyyy-MM-dd_HH') + '.json')
            if (-not (Test-Path $hourFile)) { ($record | ConvertTo-Json -Depth 8 -Compress) | Set-Content $hourFile -Encoding UTF8 }
        } catch {}
        try {
            $daySum = Join-Path $DailyDir ($now.ToString('yyyy-MM-dd') + '.json')
            if (-not (Test-Path $daySum)) { ($record | ConvertTo-Json -Depth 8 -Compress) | Set-Content $daySum -Encoding UTF8 }
        } catch {}
    } catch {}
}


# --- Service main ---
try {
    if (Test-Path $PidPath) {
        $oldPid = [int]((Get-Content $PidPath -Raw).Trim())
        if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
            Write-Host "Live service already running PID=$oldPid"
            exit 0
        }
    }
} catch {}
Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII

Write-Host "PiNodeMonitorLive SERVICE (REBUILT standard) PID=$PID"
Write-Host "Writing: $LatestPath"
Write-Host ("Temp DLL: {0}" -f $(if ($Dll) { $Dll } else { "NOT FOUND" }))

while ($true) {
    try {
        Update-NodeData
        $h = Get-HardwareSnapshot
        foreach ($k in @("CPU", "RAM", "Temp", "Disk", "Vmmem")) {
            if ($null -ne $h.$k) { $State.$k = $h.$k }
        }
        $State.Ports = Get-PortSnapshot
        $d = Get-DockerStatus
        $State.Docker = $d.Docker
        $State.Container = $d.Container
        $State.Anomaly = Detect-Anomaly
        $State.Updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Save-MonitorData
        $sev = if ($State.Anomaly -eq "Normal") { "OK" } else { "WARN" }
        $sleepSec = if ($sev -eq "OK") { 60 } else { 60 }
        if ($ShowWindow) {
            Clear-Host
            Write-Host ("SERVICE | {0} | {1} | IN={2} OUT={3} | TEMP={4} | {5}" -f $State.Source, $State.Node, $State.In, $State.Out, $State.Temp, $sev)
        }
    } catch {
        $sleepSec = 60
    }
    Start-Sleep -Seconds $sleepSec
}

