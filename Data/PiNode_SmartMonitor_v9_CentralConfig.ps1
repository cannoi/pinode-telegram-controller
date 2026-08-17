# PI NODE SMART MONITOR v10.0 — Live Data Collector (read-only)
# Thay thế OCR/chụp màn hình bằng stellar-core + Docker + hệ thống + cảm biến.
# Nguyên tắc: chỉ dữ liệu thật, không suy đoán, không bịa số 0 giả.
# Windows PowerShell 5.1 — portable theo thư mục Data/

$ErrorActionPreference = 'Continue'

$BASE_DIR = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BASE_DIR)) {
    $BASE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$APP_ROOT = Split-Path -Parent $BASE_DIR
$CONFIG_FILE = Join-Path $APP_ROOT 'Config\PiNode_Config.ps1'

if (!(Test-Path -LiteralPath $CONFIG_FILE)) {
    Write-Host "LOI: Khong tim thay Config trung tam: $CONFIG_FILE" -ForegroundColor Red
    exit 20
}
try { . $CONFIG_FILE } catch {
    Write-Host "LOI: Khong nap duoc Config: $($_.Exception.Message)" -ForegroundColor Red
    exit 21
}

$BOT_TOKEN      = $BotToken
$CHAT_ID        = $ChatId
$RAM_ALERT      = if ($RamAlert) { [double]$RamAlert } else { 88 }
$TEMP_ALERT     = if ($TempAlert) { [double]$TempAlert } else { 78 }
$INCOMING_LOW   = if ($IncomingLow) { [double]$IncomingLow } else { 3 }
$CPU_ALERT      = if ($CpuAlert) { [double]$CpuAlert } else { 90 }
$LEDGER_AGE_MAX = if ($LedgerAgeMaxSec) { [int]$LedgerAgeMaxSec } else { 30 }
$DISK_FREE_MIN  = if ($DiskFreeMinGB) { [double]$DiskFreeMinGB } else { 20 }
$HISTORY_MAX    = if ($NodeHistoryMaxRecords) { [int]$NodeHistoryMaxRecords } else { 2500 }
$DISK_SAMPLE_MINUTES = if ($DiskSampleMinutes) { [int]$DiskSampleMinutes } else { 30 }

$HISTORY_DIR = Join-Path $BASE_DIR 'History\ScreenMonitor'
$LOGFILE     = Join-Path $BASE_DIR 'Monitor_Node.log'
$DATA_FILE   = Join-Path $BASE_DIR 'node_history.json'
$COLLECTOR_STATE = Join-Path $BASE_DIR 'collector_state.json'
$DLL_PATH    = Join-Path $BASE_DIR 'OpenHardwareMonitorLib.dll'
New-Item -ItemType Directory -Path $HISTORY_DIR -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Text)
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Text"
        Write-Host $line -ForegroundColor Cyan
        $line | Out-File -LiteralPath $LOGFILE -Append -Encoding utf8
    } catch {}
}

function Send-Telegram {
    param([string]$Text, [int]$Times = 1)
    if ([string]::IsNullOrWhiteSpace($BOT_TOKEN) -or $BOT_TOKEN -eq 'PUT_TELEGRAM_BOT_TOKEN_HERE') {
        Write-Log 'Telegram chua cau hinh'; return
    }
    for ($i = 1; $i -le $Times; $i++) {
        try {
            $u = "https://api.telegram.org/bot$BOT_TOKEN/sendMessage?chat_id=$CHAT_ID&text=$([uri]::EscapeDataString($Text))"
            Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 15 | Out-Null
            Write-Log "Telegram OK ($i/$Times)"
        } catch { Write-Log "Telegram LOI: $($_.Exception.Message)" }
        if ($i -lt $Times) { Start-Sleep 2 }
    }
}

function Load-History {
    if (!(Test-Path -LiteralPath $DATA_FILE)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $DATA_FILE -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $x = $raw | ConvertFrom-Json
        if ($x -is [array]) { return @($x) }
        return @($x)
    } catch {
        Write-Log "Load history loi: $($_.Exception.Message)"
        return @()
    }
}

function Save-History {
    param([array]$Records)
    try {
        $max = [math]::Max(100, $HISTORY_MAX)
        if ($Records.Count -gt $max) { $Records = @($Records | Select-Object -Last $max) }
        ($Records | ConvertTo-Json -Depth 12 -Compress) | Set-Content -LiteralPath $DATA_FILE -Encoding UTF8
    } catch {
        Write-Log "Save history loi: $($_.Exception.Message)"
    }
}

function Read-CollectorState {
    $defaults = [ordered]@{
        lastDiskSample = $null
        lastDisk = $null
        lastAlertKey = ''
        lastAlertAt = $null
        alertCountToday = 0
        alertDay = ''
    }
    if (!(Test-Path -LiteralPath $COLLECTOR_STATE)) { return $defaults }
    try {
        $raw = Get-Content -LiteralPath $COLLECTOR_STATE -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            if ($null -ne $raw.PSObject.Properties[$k]) { $defaults[$k] = $raw.$k }
        }
        return $defaults
    } catch { return $defaults }
}

function Save-CollectorState {
    param($State)
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $COLLECTOR_STATE -Encoding UTF8
    } catch {}
}

function Invoke-External {
    param(
        [string]$File,
        [string[]]$Args,
        [int]$TimeoutMs = 8000
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.Arguments = ($Args | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return $null
        }
        return $p.StandardOutput.ReadToEnd()
    } catch { return $null }
}

function Get-DockerLive {
    $docker = $null
    try { $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source } catch {}
    if (-not $docker) {
        return [ordered]@{ available = $false; engine = 'STOPPED'; pi_container = $null; containers = @(); info = $null; pi_stats = $null }
    }
    $info = Invoke-External $docker @('info', '--format', 'Server={{.ServerVersion}}|Containers={{.Containers}}|Running={{.ContainersRunning}}|Images={{.Images}}')
    $ps = Invoke-External $docker @('ps', '--format', '{{.Names}}|{{.Image}}|{{.Status}}')
    $containers = @()
    if ($ps) {
        foreach ($line in ($ps -split "`r?`n")) {
            if ($line.Trim()) {
                $x = $line -split '\|', 3
                $containers += [pscustomobject]@{ name = $x[0]; image = $x[1]; status = $x[2] }
            }
        }
    }
    $testnet = $containers | Where-Object { $_.name -eq 'testnet2' -or $_.image -match 'pi-node-docker' } | Select-Object -First 1
    $stats = $null
    if ($testnet) {
        $s = Invoke-External $docker @('stats', $testnet.name, '--no-stream', '--format', 'CPU={{.CPUPerc}}|RAM={{.MemUsage}}|RAMP={{.MemPerc}}|NET={{.NetIO}}|BLOCK={{.BlockIO}}|PIDS={{.PIDs}}')
        if ($s) {
            $stats = [ordered]@{}
            foreach ($v in ($s.Trim() -split '\|')) {
                $kv = $v -split '=', 2
                if ($kv.Count -eq 2) { $stats[$kv[0]] = $kv[1] }
            }
        }
    }
    [ordered]@{
        available    = $true
        engine       = 'RUNNING'
        info         = $info
        containers   = $containers
        pi_container = if ($testnet) { $testnet.name } else { $null }
        pi_stats     = $stats
    }
}

function Get-PiCoreLive {
    param([string]$Container)
    if (-not $Container) { return [ordered]@{ available = $false } }
    $docker = $null
    try { $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source } catch {}
    if (-not $docker) { return [ordered]@{ available = $false } }

    $raw = Invoke-External $docker @('exec', $Container, 'stellar-core', 'http-command', 'info') 12000
    if (-not $raw) { return [ordered]@{ available = $false } }
    $i = $raw.IndexOf('{')
    if ($i -lt 0) { return [ordered]@{ available = $false } }
    try {
        $j = $raw.Substring($i) | ConvertFrom-Json
        $info = $j.info
        $in = 0; $out = 0; $auth = 0; $pending = 0
        $peersRaw = Invoke-External $docker @('exec', $Container, 'stellar-core', 'http-command', 'peers') 10000
        if ($peersRaw) {
            $pi = $peersRaw.IndexOf('{')
            if ($pi -ge 0) {
                try {
                    $pj = $peersRaw.Substring($pi) | ConvertFrom-Json
                    $in = @($pj.authenticated_peers.inbound).Count
                    $out = @($pj.authenticated_peers.outbound).Count
                    $auth = $in + $out
                    $pending = @($pj.pending_peers).Count
                } catch {}
            }
        }
        [ordered]@{
            available         = $true
            network           = $info.network
            state             = $info.state
            synced            = ($info.state -eq 'Synced!')
            build             = $info.build
            protocol_version  = $info.protocol_version
            started_on        = $info.startedOn
            ledger = [ordered]@{
                number     = $info.ledger.num
                age        = $info.ledger.age
                hash       = $info.ledger.hash
                close_time = $info.ledger.closeTime
            }
            peers = [ordered]@{
                incoming      = $in
                outgoing      = $out
                authenticated = $auth
                pending       = $pending
            }
            quorum = [ordered]@{
                phase         = $info.quorum.qset.phase
                agree         = $info.quorum.qset.agree
                disagree      = $info.quorum.qset.disagree
                missing       = $info.quorum.qset.missing
                lag_ms        = $info.quorum.qset.lag_ms
                intersection  = $info.quorum.transitive.intersection
                node_count    = $info.quorum.transitive.node_count
            }
        }
    } catch {
        Write-Log "PiCore parse loi: $($_.Exception.Message)"
        return [ordered]@{ available = $false }
    }
}

function Get-TemperatureLive {
    if (-not (Test-Path -LiteralPath $DLL_PATH)) {
        return [ordered]@{ available = $false; source = 'none'; package_c = $null; min_c = $null; max_c = $null }
    }
    try {
        Unblock-File $DLL_PATH -ErrorAction SilentlyContinue
        if (-not ('OpenHardwareMonitor.Hardware.Computer' -as [type])) {
            Add-Type -Path $DLL_PATH
        }
        $c = [OpenHardwareMonitor.Hardware.Computer]::new()
        $c.CPUEnabled = $true
        $c.Open()
        $cores = @()
        $packages = @()
        foreach ($h in @($c.Hardware | Where-Object { $_.HardwareType -eq 'CPU' })) {
            $h.Update()
            foreach ($s in @($h.Sensors | Where-Object { $_.SensorType -eq 'Temperature' -and $null -ne $_.Value })) {
                $v = [math]::Round([double]$s.Value, 1)
                if ($s.Name -match 'Package') { $packages += $v }
                else { $cores += [pscustomobject]@{ sensor = $s.Name; temp_c = $v } }
            }
        }
        $c.Close()
        if ($packages.Count -gt 0) {
            return [ordered]@{
                available  = $true
                source     = 'OpenHardwareMonitorLib'
                package_c  = [math]::Round((($packages | Measure-Object -Average).Average), 1)
                min_c      = if ($cores.Count) { [math]::Round((($cores.temp_c | Measure-Object -Minimum).Minimum), 1) } else { $null }
                max_c      = if ($cores.Count) { [math]::Round((($cores.temp_c | Measure-Object -Maximum).Maximum), 1) } else { $null }
                cores      = $cores
            }
        }
        return [ordered]@{ available = $false; source = 'OpenHardwareMonitorLib'; package_c = $null; min_c = $null; max_c = $null }
    } catch {
        Write-Log "Temp loi: $($_.Exception.Message)"
        return [ordered]@{ available = $false; source = 'OpenHardwareMonitorLib'; error = $_.Exception.Message; package_c = $null; min_c = $null; max_c = $null }
    }
}

function Get-SystemLive {
    param($CachedDisk)
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $cpuLoad = if ($cpu.Count) { [math]::Round((($cpu.LoadPercentage | Measure-Object -Average).Average), 1) } else { $null }
    $ramTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $ramFree = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $disks = $CachedDisk
    if ($null -eq $disks) {
        $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
            [pscustomobject]@{
                name          = $_.DeviceID
                total_gb      = [math]::Round($_.Size / 1GB, 2)
                free_gb       = [math]::Round($_.FreeSpace / 1GB, 2)
                used_gb       = [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 2)
                usage_percent = if ($_.Size -gt 0) { [math]::Round((1 - ($_.FreeSpace / $_.Size)) * 100, 1) } else { $null }
            }
        })
    }
    $net = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; description = $_.InterfaceDescription; speed = $_.LinkSpeed }
    })
    $ping = $null
    try { $ping = (Test-Connection 1.1.1.1 -Count 1 -ErrorAction Stop).ResponseTime } catch {}
    $ports = @(31401, 31402, 31403) | ForEach-Object {
        $p = $_
        $listen = @(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue).Count -gt 0
        [pscustomobject]@{ port = $p; listening = $listen }
    }
    $vmmem = Get-Process vmmem, vmmemWSL -ErrorAction SilentlyContinue | Select-Object -First 1
    $piDesktop = $null
    try {
        $piDesktop = Get-Process | Where-Object { $_.ProcessName -match 'Pi|PiNetwork|PiNode' } | Select-Object -First 1
    } catch {}
    [ordered]@{
        hostname = $env:COMPUTERNAME
        os       = $os.Caption
        uptime   = ((Get-Date) - $os.LastBootUpTime).ToString()
        cpu = [ordered]@{
            usage_percent     = $cpuLoad
            sockets           = $cpu.Count
            cores             = ($cpu | Measure-Object NumberOfCores -Sum).Sum
            threads           = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
            frequency_mhz     = if ($cpu.Count) { [math]::Round((($cpu.CurrentClockSpeed | Measure-Object -Average).Average), 0) } else { $null }
            max_frequency_mhz = if ($cpu.Count) { [math]::Round((($cpu.MaxClockSpeed | Measure-Object -Average).Average), 0) } else { $null }
        }
        ram = [ordered]@{
            total_gb      = $ramTotal
            free_gb       = $ramFree
            used_gb       = [math]::Round($ramTotal - $ramFree, 2)
            usage_percent = if ($ramTotal -gt 0) { [math]::Round((1 - $ramFree / $ramTotal) * 100, 1) } else { $null }
        }
        disk              = $disks
        network           = [ordered]@{ adapters = $net; latency_ms = $ping }
        ports             = $ports
        vmmem_gb          = if ($vmmem) { [math]::Round($vmmem.WorkingSet64 / 1GB, 2) } else { $null }
        pi_desktop_running = ($null -ne $piDesktop)
    }
}

# ===================== MAIN =====================
Write-Log '========== BAT DAU SmartMonitor v10 Live =========='
$Now = Get-Date
$cstate = Read-CollectorState

# Disk: lấy thưa hơn
$needDisk = $true
$cachedDisk = $null
if ($cstate.lastDiskSample -and $cstate.lastDisk) {
    try {
        $lastD = [datetime]$cstate.lastDiskSample
        if (($Now - $lastD).TotalMinutes -lt $DISK_SAMPLE_MINUTES) {
            $needDisk = $false
            $cachedDisk = $cstate.lastDisk
        }
    } catch { $needDisk = $true }
}

$dock = Get-DockerLive
$pi   = Get-PiCoreLive -Container $dock.pi_container
$temp = Get-TemperatureLive
$sys  = Get-SystemLive -CachedDisk $(if ($needDisk) { $null } else { $cachedDisk })

if ($needDisk) {
    $cstate.lastDiskSample = $Now.ToString('o')
    $cstate.lastDisk = $sys.disk
}

# Map sang schema cũ (controller phụ thuộc) + mở rộng
$SyncStatus = 'N/A'
$Local = 'N/A'
$Latest = 'N/A'
$Out = 'N/A'
$In = 'N/A'
$TempVal = 'N/A'
$RAM = if ($null -ne $sys.ram.usage_percent) { $sys.ram.usage_percent } else { 'N/A' }
$CPU = if ($null -ne $sys.cpu.usage_percent) { $sys.cpu.usage_percent } else { 'N/A' }
$Docker = if ($dock.available) { 'RUNNING' } else { 'STOPPED' }
$PortStatus = 'CLOSED'
$FreeGB = 'N/A'
$Net = if ($null -ne $sys.network.latency_ms) { 'ONLINE' } else { 'OFFLINE' }
$Ping = if ($null -ne $sys.network.latency_ms) { "$($sys.network.latency_ms) ms" } else { 'N/A' }
$PiApp = if ($sys.pi_desktop_running) { 'RUNNING' } else { 'STOPPED' }
$Uptime = $sys.uptime
$LedgerAge = $null
$QuorumPhase = $null
$LagMs = $null
$Evidence = @()

if ($pi.available) {
    $Evidence += 'stellar-core http-command info/peers'
    if ($pi.synced) { $SyncStatus = 'Dong bo tot' }
    elseif ($pi.state -match '(?i)sync') { $SyncStatus = 'Dang dong bo' }
    else { $SyncStatus = 'Chua dong bo' }
    if ($null -ne $pi.ledger.number) { $Local = [string]$pi.ledger.number; $Latest = [string]$pi.ledger.number }
    if ($null -ne $pi.peers.outgoing) { $Out = [string]$pi.peers.outgoing }
    if ($null -ne $pi.peers.incoming) { $In = [string]$pi.peers.incoming }
    $LedgerAge = $pi.ledger.age
    $QuorumPhase = $pi.quorum.phase
    $LagMs = $pi.quorum.lag_ms
} else {
    $Evidence += 'pi_node.unavailable (khong doc duoc stellar-core)'
}

if ($temp.available -and $null -ne $temp.package_c) {
    $TempVal = [string]$temp.package_c
    $Evidence += "temp source=$($temp.source)"
} else {
    $Evidence += 'temp unavailable'
}

$portOpen = @($sys.ports | Where-Object { $_.listening }).Count
$portTotal = @($sys.ports).Count
if ($portOpen -ge 1) { $PortStatus = 'OPEN' } else { $PortStatus = 'CLOSED' }
$Evidence += "ports listening=$portOpen/$portTotal"

$cDrive = @($sys.disk | Where-Object { $_.name -eq 'C:' } | Select-Object -First 1)
if ($cDrive) { $FreeGB = $cDrive.free_gb }

$Critical = @()
$Warnings = @()
$SoftIssues = @()

# Critical — chỉ khi có bằng chứng đo được
if (-not $dock.available) {
    $Critical += 'Docker engine khong kha dung (docker info that bai)'
}
if ($dock.available -and -not $dock.pi_container) {
    $Critical += 'Khong tim thay container Pi Node (testnet2 / pi-node-docker)'
}
if ($pi.available -and -not $pi.synced) {
    $Critical += "Node chua Synced (state=$($pi.state), ledger_age=$($pi.ledger.age))"
}
if ($pi.available -and $null -ne $pi.ledger.age -and [double]$pi.ledger.age -gt $LEDGER_AGE_MAX) {
    $Critical += "Ledger age cao: $($pi.ledger.age)s (nguong ${LEDGER_AGE_MAX}s)"
}
if ($PortStatus -eq 'CLOSED') {
    $Critical += 'Port Pi (31401-31403) khong LISTEN'
}
if ($Net -eq 'OFFLINE') {
    $Critical += 'May mat ket noi Internet (ping 1.1.1.1 that bai)'
}

# Warnings — tài nguyên / peer
if ($RAM -ne 'N/A' -and [double]$RAM -ge $RAM_ALERT) { $Warnings += "RAM cao: $RAM% (nguong $RAM_ALERT%)" }
if ($CPU -ne 'N/A' -and [double]$CPU -ge $CPU_ALERT) { $Warnings += "CPU cao: $CPU% (nguong $CPU_ALERT%)" }
if ($TempVal -ne 'N/A') {
    try { if ([double]$TempVal -ge $TEMP_ALERT) { $Warnings += "Nhiet do cao: $TempVal C (nguong $TEMP_ALERT C)" } } catch {}
}
if ($FreeGB -ne 'N/A' -and [double]$FreeGB -lt $DISK_FREE_MIN) { $Warnings += "O C thap: $FreeGB GB (nguong ${DISK_FREE_MIN}GB)" }
if ($In -ne 'N/A') {
    try { if ([double]$In -le $INCOMING_LOW) { $Warnings += "Incoming thap: $In (nguong $INCOMING_LOW)" } } catch {}
}
if ($pi.available -and $null -ne $pi.peers.outgoing -and [int]$pi.peers.outgoing -eq 0 -and [int]$pi.peers.incoming -eq 0) {
    $Warnings += 'Incoming+Outgoing = 0 (peer mat ket noi)'
}
# Xu hướng peer: so với mẫu trước (chỉ khi cả hai mẫu có số thật)
$peerDropNote = $null
try {
    $prevHist = @(Load-History)
    if ($prevHist.Count -gt 0 -and $In -ne 'N/A' -and $Out -ne 'N/A') {
        $prev = $prevHist[-1]
        $pIn = $null; $pOut = $null
        try { $pIn = [double]$prev.incoming } catch {}
        try { $pOut = [double]$prev.outgoing } catch {}
        $cIn = [double]$In; $cOut = [double]$Out
        if ($null -ne $pIn -and $null -ne $pOut) {
            $sumPrev = $pIn + $pOut
            $sumNow = $cIn + $cOut
            if ($sumPrev -ge 4 -and $sumNow -lt ($sumPrev * 0.5)) {
                $peerDropNote = "Peer sut giam bat thuong: In+Out $sumPrev -> $sumNow (mau truoc -> hien tai)"
                $Warnings += $peerDropNote
                $Evidence += $peerDropNote
            } elseif ($sumPrev -eq 0 -and $sumNow -ge 2) {
                $Evidence += "Peer dang phuc hoi: In+Out 0 -> $sumNow"
            }
        }
    }
} catch {}
if (-not $sys.pi_desktop_running) {
    $SoftIssues += 'Pi Desktop process khong thay chay (khong bat buoc neu Docker Node dang chay)'
}
if (-not $pi.available -and $dock.available) {
    $SoftIssues += 'Co Docker nhung khong doc duoc stellar-core info'
}

$Problems = @($Critical + $Warnings)
$ProblemCount = $Problems.Count
$CriticalCount = $Critical.Count
$Severity = if ($CriticalCount -gt 0) { 'CRITICAL' } elseif ($Warnings.Count -gt 0) { 'WARNING' } else { 'OK' }

# Cảnh báo Telegram: chỉ CRITICAL, chống spam (cùng key trong 30 phút)
$alertKey = ($Critical -join '|')
$today = $Now.ToString('yyyy-MM-dd')
if ($cstate.alertDay -ne $today) {
    $cstate.alertDay = $today
    $cstate.alertCountToday = 0
}
$canAlert = $true
if ($cstate.lastAlertKey -eq $alertKey -and $cstate.lastAlertAt) {
    try {
        if ((($Now) - [datetime]$cstate.lastAlertAt).TotalMinutes -lt 30) { $canAlert = $false }
    } catch {}
}
if ($Critical.Count -gt 0 -and $canAlert) {
    $list = ($Critical | ForEach-Object { "- $_" }) -join "`n"
    $warnExtra = if ($Warnings.Count) { "`nCanh bao phu:`n" + (($Warnings | ForEach-Object { "- $_" }) -join "`n") } else { '' }
    $ev = ($Evidence | Select-Object -First 6) -join '; '
    $msg = @"
CANH BAO PI NODE (CRITICAL)
Luc $($Now.ToString('HH:mm')) ngay $($Now.ToString('dd/MM'))

Su co (co bang chung do duoc):
$list$warnExtra

Thong so do:
- Dong bo: $SyncStatus | Ledger: $Local | Age: $LedgerAge
- Incoming / Outgoing: $In / $Out
- RAM: $RAM% | CPU: $CPU% | Nhiet: $TempVal C
- Port: $PortStatus | Docker: $Docker | Pi Desktop: $PiApp
- Nguon: stellar-core + Docker + OHM (khong OCR)

Bang chung: $ev
"@
    if ($MonitorSelfNotify) { Send-Telegram $msg.Trim() }
    $cstate.lastAlertKey = $alertKey
    $cstate.lastAlertAt = $Now.ToString('o')
    $cstate.alertCountToday = [int]$cstate.alertCountToday + 1
    Write-Log "CRITICAL: $($Critical -join '; ')"
} elseif ($Warnings.Count -gt 0) {
    Write-Log "WARNING (khong spam Telegram): $($Warnings -join '; ')"
} else {
    Write-Log 'OK: khong su co critical/warning'
}
if ($SoftIssues.Count) { Write-Log "SoftIssues: $($SoftIssues -join '; ')" }

Save-CollectorState $cstate

$History = @(Load-History)
$History += [ordered]@{
    time       = $Now.ToString('o')
    sync       = $SyncStatus
    local      = $Local
    latest     = $Latest
    outgoing   = $Out
    incoming   = $In
    temp       = $TempVal
    ram_sys    = $RAM
    cpu_sys    = $CPU
    internet   = $Net
    blockchain = if ($pi.available) { 'OK' } else { 'N/A' }
    avail      = if ($pi.available -and $pi.synced) { 'OK' } else { 'N/A' }
    docker     = $Docker
    port       = $PortStatus
    capture    = 'live-api'
    window     = $false
    problems   = $ProblemCount
    critical   = $CriticalCount
    severity   = $Severity
    source     = 'stellar-core+docker+ohm'
    # extended (controller co the bo qua neu chua biet)
    ledger_age     = $LedgerAge
    quorum_phase   = $QuorumPhase
    quorum_lag_ms  = $LagMs
    pi_container   = $dock.pi_container
    free_gb        = $FreeGB
    pi_desktop     = $PiApp
    evidence       = $Evidence
    critical_list  = $Critical
    warning_list   = $Warnings
    peers_auth     = if ($pi.available) { $pi.peers.authenticated } else { $null }
    protocol       = if ($pi.available) { $pi.protocol_version } else { $null }
    build          = if ($pi.available) { $pi.build } else { $null }
}
Save-History $History

# Bao cao 7h/18h neu MonitorSelfNotify
$Hour = [int]$Now.Hour
$IsReportHour = ($Hour -eq 7 -or $Hour -eq 18)
if ($IsReportHour -and $MonitorSelfNotify) {
    $since = $Now.AddHours(-24)
    $Day = @($History | Where-Object { try { [datetime]$_.time -ge $since } catch { $false } })
    $TotalRuns = $Day.Count
    $ProblemRuns = @($Day | Where-Object { $_.problems -gt 0 }).Count
    $temps = @($Day | Where-Object { $_.temp -ne 'N/A' } | ForEach-Object { try { [double]$_.temp } catch {} })
    $maxT = if ($temps.Count) { ($temps | Measure-Object -Maximum).Maximum } else { 'N/A' }
    $avgT = if ($temps.Count) { [math]::Round(($temps | Measure-Object -Average).Average, 1) } else { 'N/A' }
    $ins = @($Day | Where-Object { $_.incoming -ne 'N/A' } | ForEach-Object { try { [double]$_.incoming } catch {} })
    $avgIn = if ($ins.Count) { [math]::Round(($ins | Measure-Object -Average).Average, 1) } else { 'N/A' }
    $syncOK = @($Day | Where-Object { $_.sync -eq 'Dong bo tot' }).Count
    $syncRate = if ($TotalRuns) { [math]::Round(100 * $syncOK / $TotalRuns, 0) } else { 0 }
    if ($ProblemRuns -ge 3 -or $syncRate -lt 70) { $overall = 'Can chu y'; $mood = 'Co vai diem can theo doi.' }
    elseif ($ProblemRuns -eq 0 -and $syncRate -ge 90) { $overall = 'Tot'; $mood = 'Node dang chay on dinh.' }
    else { $overall = 'On dinh'; $mood = 'Tinh trang chung o muc chap nhan duoc.' }
    $report = @"
BAO CAO PI NODE
$($Now.ToString('dd/MM/yyyy HH:mm'))

Tong quan: $overall
$mood

Hien tai (do truc tiep stellar-core):
Dong bo: $SyncStatus
Ledger: $Local | Age: $LedgerAge
Incoming/Outgoing: $In / $Out
Nhiet do: $TempVal C
RAM/CPU: $RAM% / $CPU%

24 gio:
So lan kiem tra: $TotalRuns
Lan co van de: $ProblemRuns
Ty le dong bo tot: $syncRate%
Nhiet do TB/Max: $avgT / $maxT C
Incoming TB: $avgIn

Dich vu:
Docker: $Docker
Pi Desktop: $PiApp
Port: $PortStatus
Uptime: $Uptime
Mang: $Net ($Ping)

$(if ($Problems.Count) { "Van de luc nay:`n" + (($Problems | ForEach-Object { "- $_" }) -join "`n") } else { 'Hien tai khong phat hien su co.' })

Smart Monitor v10 Live (khong OCR)
"@
    Send-Telegram $report.Trim()
}

Write-Log "Ket qua: Sync=$SyncStatus Severity=$Severity Critical=$CriticalCount Warn=$($Warnings.Count) Soft=$($SoftIssues.Count) Temp=$TempVal In=$In Out=$Out Age=$LedgerAge Source=live-api"
Write-Log '========== KET THUC =========='
