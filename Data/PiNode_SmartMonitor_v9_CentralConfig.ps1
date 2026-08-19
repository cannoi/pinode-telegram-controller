# PI NODE SMART MONITOR v11.0 — Smart Evidence Live Data Collector (read-only)
# Thay thế OCR/chụp màn hình bằng stellar-core + Docker + Windows/CIM + OpenHardwareMonitorLib.
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
    throw "Khong tim thay Config trung tam: $CONFIG_FILE"
}
try { . $CONFIG_FILE } catch {
    Write-Host "LOI: Khong nap duoc Config: $($_.Exception.Message)" -ForegroundColor Red
    throw "Khong nap duoc Config: $($_.Exception.Message)"
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
$VHDX_SAMPLE_MINUTES = if ($VhdxSampleMinutes) { [int]$VhdxSampleMinutes } else { 30 }
$ARCHIVE_DAYS = if ($NodeHistoryArchiveDays) { [int]$NodeHistoryArchiveDays } else { 45 }
$ARCHIVE_MAX_MB = if ($NodeHistoryArchiveMaxMB) { [int]$NodeHistoryArchiveMaxMB } else { 200 }
$PEER_DROP_PERCENT = if ($PeerDropPercent) { [double]$PeerDropPercent } else { 50 }
$PEER_BASELINE_MIN = if ($PeerBaselineMin) { [int]$PeerBaselineMin } else { 4 }

$HISTORY_DIR = Join-Path $BASE_DIR 'History\ScreenMonitor'
$LOGFILE     = Join-Path $BASE_DIR 'Monitor_Node.log'
$DATA_FILE   = Join-Path $BASE_DIR 'node_history.json'
$COLLECTOR_STATE = Join-Path $BASE_DIR 'collector_state.json'
$ARCHIVE_DIR = Join-Path $BASE_DIR 'History\Node'
New-Item -ItemType Directory -Path $ARCHIVE_DIR -Force -ErrorAction SilentlyContinue | Out-Null
$DLL_PATH    = Join-Path $BASE_DIR 'OpenHardwareMonitorLib.dll'

# Collector chạy read-only trong chính process/token của Controller.
# Không OCR, không chụp màn hình, không tự sửa Node.
$script:IsAdministrator = $false
try { $script:IsAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
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
        lastPiContainer = $null
        lastVhdxSample = $null
        lastVhdx = $null
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

function Test-StellarCoreContainer {
    param([string]$DockerExe, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $raw = Invoke-External $DockerExe @('exec', $Name, 'stellar-core', 'http-command', 'info') 8000
    if (-not $raw) { return $false }
    return ($raw.IndexOf('{') -ge 0)
}

function Resolve-PiContainer {
    param(
        [string]$DockerExe,
        [array]$Containers,
        [string]$PreferredName
    )
    if ($PreferredName) {
        $hit = @($Containers | Where-Object { $_.name -eq $PreferredName } | Select-Object -First 1)
        if ($hit -and (Test-StellarCoreContainer -DockerExe $DockerExe -Name $PreferredName)) { return $PreferredName }
        if (Test-StellarCoreContainer -DockerExe $DockerExe -Name $PreferredName) { return $PreferredName }
    }
    $nameHints = @('testnet2', 'testnet', 'pi-node', 'pinode', 'pi_node', 'pi-network', 'mainnet')
    foreach ($hint in $nameHints) {
        $c = @($Containers | Where-Object { $_.name -eq $hint -or $_.name -match [regex]::Escape($hint) } | Select-Object -First 1)
        if ($c -and (Test-StellarCoreContainer -DockerExe $DockerExe -Name $c.name)) { return [string]$c.name }
    }
    $imgHits = @($Containers | Where-Object { $_.image -match 'pi-node|pinode|pi.network|pi-network|stellar|testnet' })
    foreach ($c in $imgHits) {
        if (Test-StellarCoreContainer -DockerExe $DockerExe -Name $c.name) { return [string]$c.name }
    }
    $probed = 0
    foreach ($c in $Containers) {
        if ($probed -ge 12) { break }
        $probed++
        if (Test-StellarCoreContainer -DockerExe $DockerExe -Name $c.name) { return [string]$c.name }
    }
    return $null
}

function Convert-SizeToGB {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m=[regex]::Match($Text,'([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB|TB)',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $m.Success){return $null}
    $v=[double]$m.Groups[1].Value
    switch($m.Groups[2].Value.ToUpperInvariant()){
        'TB'{return [math]::Round($v*1024,2)} 'GB'{return [math]::Round($v,2)} 'MB'{return [math]::Round($v/1024,2)} 'KB'{return [math]::Round($v/1048576,2)} default{return [math]::Round($v/1073741824,3)}
    }
}
function Get-VhdxLive {
    $files=@()
    try {
        $paths=@((Join-Path $env:LOCALAPPDATA 'Docker'),(Join-Path $env:LOCALAPPDATA 'Packages'))
        $files=@(Get-ChildItem $paths -Filter '*.vhdx' -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object {[pscustomobject]@{name=$_.Name;path=$_.FullName;size_gb=[math]::Round($_.Length/1GB,2)}})
    } catch {}
    return [ordered]@{available=($files.Count -gt 0);files=$files;largest_gb=if($files.Count){$files[0].size_gb}else{$null}}
}
function Save-LongTermRecord {
    param($Record)
    try {
        $file=Join-Path $ARCHIVE_DIR ("NodeHistory_{0}.ndjson" -f (Get-Date $Record.time).ToString('yyyy-MM-dd'))
        ($Record | ConvertTo-Json -Depth 15 -Compress) | Add-Content -LiteralPath $file -Encoding UTF8
        $cut=(Get-Date).AddDays(-$ARCHIVE_DAYS)
        Get-ChildItem $ARCHIVE_DIR -Filter 'NodeHistory_*.ndjson' -File -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -lt $cut} | Remove-Item -Force -ErrorAction SilentlyContinue
        $total=(Get-ChildItem $ARCHIVE_DIR -Filter 'NodeHistory_*.ndjson' -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if($total -gt ($ARCHIVE_MAX_MB*1MB)){Get-ChildItem $ARCHIVE_DIR -Filter 'NodeHistory_*.ndjson' -File | Sort-Object LastWriteTime | Select-Object -First 1 | Remove-Item -Force -ErrorAction SilentlyContinue}
    } catch { Write-Log "Archive history loi: $($_.Exception.Message)" }
}

function Get-DockerLive {
    param([string]$PreferredContainer = $null)
    $docker = $null
    try { $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source } catch {}
    if (-not $docker) {
        return [ordered]@{
            available = $false; engine = 'STOPPED'; pi_container = $null
            containers = @(); info = $null; pi_stats = $null; container_names = @()
        }
    }
    $info = Invoke-External $docker @('info', '--format', '{{.ServerVersion}}')
    $ps = Invoke-External $docker @('ps', '--format', '{{.Names}}|{{.Image}}|{{.Status}}')
    $containers = @()
    if ($ps) {
        foreach ($line in ($ps -split "`r?`n")) {
            if ($line.Trim()) {
                $x = $line -split '\|', 3
                $containers += [pscustomobject]@{
                    name   = $x[0].Trim()
                    image  = if ($x.Count -gt 1) { $x[1].Trim() } else { '' }
                    status = if ($x.Count -gt 2) { $x[2].Trim() } else { '' }
                }
            }
        }
    }
    if ($containers.Count -eq 0) {
        $psRaw = Invoke-External $docker @('ps', '--no-trunc')
        if ($psRaw) {
            foreach ($line in @($psRaw -split "`r?`n" | Select-Object -Skip 1)) {
                if (-not $line.Trim()) { continue }
                $parts = $line -split '\s{2,}'
                $name = $parts[-1]
                if ($name) { $containers += [pscustomobject]@{ name = $name.Trim(); image = ''; status = 'Up' } }
            }
        }
    }

    $piName = Resolve-PiContainer -DockerExe $docker -Containers $containers -PreferredName $PreferredContainer
    $stats = $null
    if ($piName) {
        $s = Invoke-External $docker @('stats', $piName, '--no-stream', '--format', 'CPU={{.CPUPerc}}|RAM={{.MemUsage}}|RAMP={{.MemPerc}}|NET={{.NetIO}}|BLOCK={{.BlockIO}}|PIDS={{.PIDs}}')
        if ($s) {
            $stats = [ordered]@{}
            foreach ($v in ($s.Trim() -split '\|')) {
                $kv = $v -split '=', 2
                if ($kv.Count -eq 2) { $stats[$kv[0]] = $kv[1] }
            }
            if($stats.Contains('NET')){
                $n=@($stats['NET'] -split '\s*/\s*')
                if($n.Count -eq 2){$stats['NET_RX_GB']=Convert-SizeToGB $n[0];$stats['NET_TX_GB']=Convert-SizeToGB $n[1]}
            }
        }
    }
    [ordered]@{
        available       = $true
        engine          = 'RUNNING'
        info            = $info
        containers      = $containers
        container_names = @($containers | ForEach-Object { $_.name })
        pi_container    = $piName
        pi_stats        = $stats
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
                package_c      = [math]::Round((($packages | Measure-Object -Maximum).Maximum), 1)
                package_min_c  = [math]::Round((($packages | Measure-Object -Minimum).Minimum), 1)
                package_max_c  = [math]::Round((($packages | Measure-Object -Maximum).Maximum), 1)
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

# Ưu tiên: Config $PiContainerName → state đã học → auto-discover stellar-core
$preferredPi = $null
if ($PiContainerName) { $preferredPi = [string]$PiContainerName }
elseif ($cstate.lastPiContainer) { $preferredPi = [string]$cstate.lastPiContainer }

$needVhdx=$true; $vhdx=$null
if($cstate.lastVhdxSample -and $cstate.lastVhdx){try{if((($Now-[datetime]$cstate.lastVhdxSample).TotalMinutes)-lt $VHDX_SAMPLE_MINUTES){$needVhdx=$false;$vhdx=$cstate.lastVhdx}}catch{}}
if($needVhdx){$vhdx=Get-VhdxLive;$cstate.lastVhdxSample=$Now.ToString('o');$cstate.lastVhdx=$vhdx}

$dock = Get-DockerLive -PreferredContainer $preferredPi
if ($dock.pi_container) {
    $cstate.lastPiContainer = [string]$dock.pi_container
    Write-Log "Pi container: $($dock.pi_container)"
} else {
    Write-Log ("Pi container: KHONG TIM THAY. Dang chay: " + ((@($dock.container_names) -join ', ')))
}
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

if($null -ne $sys.vmmem_gb){$Evidence += "vmmem=$($sys.vmmem_gb)GB"}
if($vhdx -and $vhdx.available){$Evidence += "Docker VHDX largest=$($vhdx.largest_gb)GB"}
$Critical = @()
$Warnings = @()
$SoftIssues = @()

# Critical — chỉ khi có bằng chứng đo được
if (-not $dock.available) {
    $Critical += 'Docker engine khong kha dung (docker info that bai)'
}
if ($dock.available -and -not $dock.pi_container) {
    $names = @($dock.container_names)
    if ($names.Count -gt 0) {
        $Critical += "Khong tim thay container co stellar-core. Container dang chay: $($names -join ', '). Dat `$PiContainerName='ten' trong Config neu can."
    } else {
        $Critical += 'Docker RUNNING nhung khong co container nao dang chay (docker ps rong). Hay mo Pi Node / start container.'
    }
}
if ($dock.available -and $dock.pi_container -and -not $pi.available) {
    $Critical += "Co container '$($dock.pi_container)' nhung stellar-core http-command info that bai (Node chua san sang?)"
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
            $dropPct=if($sumPrev -gt 0){[math]::Round(100*(1-($sumNow/$sumPrev)),0)}else{0}
            if ($sumPrev -ge $PEER_BASELINE_MIN -and $dropPct -ge $PEER_DROP_PERCENT) {
                $peerDropNote = "Peer sut giam bat thuong: In+Out $sumPrev -> $sumNow (giam $dropPct%)"
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
$peerDelta=$null;$peerDropPct=$null
try{if($History.Count -gt 0 -and $In -ne 'N/A' -and $Out -ne 'N/A'){$pr=$History[-1];$pt=[double]$pr.incoming+[double]$pr.outgoing;$ct=[double]$In+[double]$Out;if($pt -gt 0){$peerDelta=[math]::Round($ct-$pt,0);$peerDropPct=[math]::Round(100*(1-($ct/$pt)),0)}}}catch{}
$History += [ordered]@{
    time       = $Now.ToString('o')
    sync       = $SyncStatus
    local      = $Local
    latest     = $Latest
    outgoing   = $Out
    incoming   = $In
    temp       = $TempVal
    temp_min   = if($temp.available){$temp.min_c}else{$null}
    temp_max   = if($temp.available){$temp.package_max_c}else{$null}
    temp_source= if($temp.available){$temp.source}else{$null}
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
    administrator = $script:IsAdministrator
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
    peer_total     = if ($pi.available) { [int]$pi.peers.incoming + [int]$pi.peers.outgoing } else { $null }
    peer_delta     = $peerDelta
    peer_drop_pct  = $peerDropPct
    protocol       = if ($pi.available) { $pi.protocol_version } else { $null }
    build          = if ($pi.available) { $pi.build } else { $null }
    quorum_agree   = if ($pi.available) { $pi.quorum.agree } else { $null }
    quorum_disagree= if ($pi.available) { $pi.quorum.disagree } else { $null }
    quorum_missing = if ($pi.available) { $pi.quorum.missing } else { $null }
    quorum_intersection = if ($pi.available) { $pi.quorum.intersection } else { $null }
    quorum_nodes   = if ($pi.available) { $pi.quorum.node_count } else { $null }
    docker_server  = $dock.info
    docker_pi_stats= $dock.pi_stats
    vmmem_gb       = $sys.vmmem_gb
    vhdx            = $vhdx
}
Save-History $History
Save-LongTermRecord $History[-1]

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

Smart Monitor Live (stellar-core + Docker + OHM, khong OCR/chup anh)
"@
    Send-Telegram $report.Trim()
}

Write-Log "Ket qua: Sync=$SyncStatus Severity=$Severity Critical=$CriticalCount Warn=$($Warnings.Count) Soft=$($SoftIssues.Count) Temp=$TempVal In=$In Out=$Out Age=$LedgerAge Source=live-api"
Write-Log '========== KET THUC =========='
