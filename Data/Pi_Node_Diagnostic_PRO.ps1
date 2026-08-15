#requires -Version 5.1
<#
Pi Node Diagnostic PRO
Windows PowerShell 5.1 compatible

Purpose:
  Read-only diagnostic for Pi Node host.
  Checks:
    - Windows / uptime
    - CPU / RAM / C: disk
    - Pi Node / Pi Desktop processes
    - Docker client/server
    - Docker containers
    - WSL
    - Pi Node ports
    - Internet connectivity
    - node_history.json
    - recent history health
  Produces:
    - Human-readable console report
    - JSON report: diagnostic_latest.json
  Safety:
    - Does NOT restart, stop, reset, prune, delete, or modify Pi Node/Docker/WSL.
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = (Get-Location).Path }

$HistoryPath = Join-Path $ScriptDir 'node_history.json'
$JsonPath    = Join-Path $ScriptDir 'diagnostic_latest.json'
$Now         = Get-Date

$Good = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$Issues = New-Object System.Collections.Generic.List[string]

function Add-Good([string]$Text) { if ($Text) { [void]$Good.Add($Text) } }
function Add-Warn([string]$Text) { if ($Text) { [void]$Warnings.Add($Text) } }
function Add-Issue([string]$Text) { if ($Text) { [void]$Issues.Add($Text) } }

function Section([string]$Title) {
    Write-Output ""
    Write-Output "==== $Title ===="
}

function To-Number($Value) {
    if ($null -eq $Value) { return $null }
    $n = 0.0
    $s = ([string]$Value).Trim().Replace('%','').Replace('°C','').Replace('C','')
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Any,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    if ([double]::TryParse($s, [ref]$n)) { return $n }
    return $null
}

function Get-PropertyValue($Object, [string[]]$Names) {
    foreach ($name in $Names) {
        if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$name]) {
            $v = $Object.$name
            if ($null -ne $v -and ([string]$v).Trim() -ne '') { return $v }
        }
    }
    return $null
}

function Get-TimeValue($Object) {
    $v = Get-PropertyValue $Object @(
        'Timestamp','Time','DateTime','Date','RecordedAt','Recorded','timestamp','time'
    )
    if ($null -eq $v) { return $null }
    try { return [datetime]$v } catch { return $null }
}

function Get-MetricValues($Rows, [string[]]$Names) {
    $out = New-Object System.Collections.Generic.List[double]
    foreach ($row in $Rows) {
        $v = Get-PropertyValue $row $Names
        $n = To-Number $v
        if ($null -ne $n) { [void]$out.Add([double]$n) }
    }
    return @($out)
}

function Stats($Values) {
    if ($null -eq $Values -or @($Values).Count -eq 0) { return $null }
    $a = @($Values)
    $m = $a | Measure-Object -Minimum -Maximum -Average
    $sorted = @($a | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        $median = $sorted[$mid]
    } else {
        $median = ($sorted[$mid-1] + $sorted[$mid]) / 2
    }
    [pscustomobject]@{
        Count  = $a.Count
        Min    = [math]::Round([double]$m.Minimum, 2)
        Max    = [math]::Round([double]$m.Maximum, 2)
        Average= [math]::Round([double]$m.Average, 2)
        Median = [math]::Round([double]$median, 2)
    }
}

Write-Output "=============================================="
Write-Output " PI NODE DIAGNOSTIC PRO"
Write-Output "=============================================="
Write-Output "Time : $($Now.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "Host : $env:COMPUTERNAME"
Write-Output "Path : $ScriptDir"

$Report = [ordered]@{
    schema = 'PiNodeDiagnosticPRO.v1'
    timestamp = $Now.ToString('o')
    host = $env:COMPUTERNAME
    result = $null
    score = 100
    system = [ordered]@{}
    nodeProcess = [ordered]@{}
    docker = [ordered]@{}
    wsl = [ordered]@{}
    ports = @()
    network = [ordered]@{}
    history = [ordered]@{}
    good = @()
    warnings = @()
    issues = @()
}

# SYSTEM
Section 'SYSTEM'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpuRows = @(Get-CimInstance Win32_Processor)

    $ramTotal = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    $ramFree = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 2)
    $ramUsedPct = if ($ramTotal -gt 0) {
        [math]::Round((($ramTotal - $ramFree) / $ramTotal) * 100, 1)
    } else { $null }

    $cpuAvg = if ($cpuRows.Count -gt 0) {
        [math]::Round((($cpuRows | Measure-Object -Property LoadPercentage -Average).Average), 1)
    } else { $null }

    $uptime = $Now - $os.LastBootUpTime

    Write-Output "OS       : $($os.Caption) $($os.Version)"
    Write-Output "Uptime   : $([int]$uptime.TotalDays)d $($uptime.Hours)h $($uptime.Minutes)m"
    Write-Output "RAM      : $ramUsedPct% used | $ramFree GB free / $ramTotal GB"
    Write-Output "CPU      : $cpuAvg%"

    $Report.system.os = "$($os.Caption) $($os.Version)"
    $Report.system.uptimeHours = [math]::Round($uptime.TotalHours, 1)
    $Report.system.ramUsedPercent = $ramUsedPct
    $Report.system.ramFreeGB = $ramFree
    $Report.system.ramTotalGB = $ramTotal
    $Report.system.cpuPercent = $cpuAvg

    if ($ramUsedPct -ge 90) { Add-Issue "RAM rất cao: $ramUsedPct%" }
    elseif ($ramUsedPct -ge 80) { Add-Warn "RAM cao: $ramUsedPct%" }
    else { Add-Good "RAM ổn: $ramUsedPct%" }

    if ($cpuAvg -ge 90) { Add-Issue "CPU rất cao: $cpuAvg%" }
    elseif ($cpuAvg -ge 75) { Add-Warn "CPU cao: $cpuAvg%" }
    else { Add-Good "CPU ổn: $cpuAvg%" }
}
catch {
    Add-Warn "Không đọc đầy đủ thông tin hệ thống"
}

try {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    $freePct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
    Write-Output "Disk C   : $freePct% free | $freeGB GB"
    $Report.system.diskCFreeGB = $freeGB
    $Report.system.diskCFreePercent = $freePct

    if ($freePct -lt 10) { Add-Issue "Ổ C gần đầy: $freePct% còn trống" }
    elseif ($freePct -lt 20) { Add-Warn "Ổ C còn ít: $freePct% còn trống" }
    else { Add-Good "Ổ C dung lượng ổn: $freePct% trống" }
}
catch { Add-Warn "Không kiểm tra được ổ C" }

# NODE PROCESS
Section 'PI NODE PROCESS'
$processNames = @('Pi Network','PiNode','Pi Node','PiDesktop','PiDesktopApp')
$nodeProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $n = $_.ProcessName
    ($processNames | Where-Object { $n -like "*$_*" }).Count -gt 0
})

$Report.nodeProcess.detected = ($nodeProcs.Count -gt 0)
$Report.nodeProcess.processes = @()

if ($nodeProcs.Count -gt 0) {
    foreach ($p in $nodeProcs) {
        $memMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
        Write-Output "Process  : $($p.ProcessName) | PID=$($p.Id) | RAM=$memMB MB"
        $Report.nodeProcess.processes += [ordered]@{
            name=$p.ProcessName; pid=$p.Id; memoryMB=$memMB
        }
    }
    Add-Good "Đã phát hiện tiến trình Pi Node/Pi Desktop"
}
else {
    Write-Output "Process  : Pi Node/Pi Desktop không được phát hiện"
    Add-Warn "Không phát hiện tiến trình Pi Node/Pi Desktop (có thể App dùng tên process khác)"
}

# DOCKER
Section 'DOCKER'
$dockerOK = $false
$dockerVersion = $null
try {
    $dockerVersion = (docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $dockerVersion) {
        $dockerOK = $true
        Write-Output "Docker   : OK"
        Write-Output $dockerVersion
        Add-Good "Docker Client/Server phản hồi"
    }
    else {
        Write-Output "Docker   : unavailable"
        Add-Issue "Docker không phản hồi"
    }
}
catch {
    Write-Output "Docker   : unavailable"
    Add-Issue "Không gọi được Docker CLI"
}

$Report.docker.available = $dockerOK
$Report.docker.version = $dockerVersion
$Report.docker.running = @()
$Report.docker.stopped = @()

if ($dockerOK) {
    try {
        $running = @(docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>$null)
        foreach ($line in $running) {
            Write-Output "RUNNING  : $line"
            $parts = $line -split '\|',3
            $Report.docker.running += [ordered]@{
                name=$parts[0]; status=$parts[1]; image=$parts[2]
            }
        }

        if ($running.Count -eq 0) {
            Add-Issue "Không có Docker container đang chạy"
        } else {
            Add-Good "Có $($running.Count) Docker container đang chạy"
        }

        # Các container one-shot bình thường của Pi Desktop (không coi là lỗi)
        $NormalOneShot = @('pi-port-checker', 'portschecker', 'port-checker', 'node-port-test')
        $all = @(docker ps -a --format '{{.Names}}|{{.Status}}' 2>$null)
        foreach ($line in $all) {
            if ($line -match '\|(Exited|Created|Dead|Restarting)') {
                $parts = $line -split '\|',2
                $cname = $parts[0].ToLower()
                $isOneShot = $false
                foreach ($n in $NormalOneShot) {
                    if ($cname -like "*$n*") { $isOneShot = $true; break }
                }
                if ($isOneShot) {
                    Write-Output "ONESHOT  : $line (bình thường - công cụ kiểm tra cổng)"
                    # Không đưa vào stopped/problem
                } else {
                    Write-Output "PROBLEM  : $line"
                    $Report.docker.stopped += [ordered]@{
                        name=$parts[0]; status=$parts[1]
                    }
                }
            }
        }

        if ($Report.docker.stopped.Count -gt 0) {
            Add-Warn "Có $($Report.docker.stopped.Count) container stopped/problem"
        } else {
            # Nếu chỉ còn one-shot thì không cảnh báo
        }
    }
    catch {
        Add-Warn "Không đọc được danh sách Docker container"
    }
}

# WSL
Section 'WSL'
try {
    $wslLines = @(wsl --list --verbose 2>$null)
    if ($LASTEXITCODE -eq 0 -and $wslLines.Count -gt 0) {
        $Report.wsl.available = $true
        $Report.wsl.lines = $wslLines
        $wslLines | ForEach-Object { Write-Output $_ }
        Add-Good "WSL phản hồi"
    }
    else {
        $Report.wsl.available = $false
        Write-Output "WSL: unavailable/not detected"
        Add-Warn "Không đọc được WSL"
    }
}
catch {
    $Report.wsl.available = $false
    Add-Warn "Không kiểm tra được WSL"
}

# PORTS
Section 'PI NODE PORTS'
foreach ($port in @(31401,31402,31403)) {
    $open = $false
    try {
        $test = Test-NetConnection 127.0.0.1 -Port $port -WarningAction SilentlyContinue
        $open = [bool]$test.TcpTestSucceeded
    } catch {}

    Write-Output "Port $port : $open"
    $Report.ports += [ordered]@{ port=$port; open=$open }

    if ($open) { Add-Good "Port $port đang mở" }
    else { Add-Warn "Port $port không mở" }
}

# NETWORK
Section 'NETWORK'
try {
    $net = Test-NetConnection 1.1.1.1 -Port 443 -WarningAction SilentlyContinue
    $Report.network.internet443 = [bool]$net.TcpTestSucceeded
    Write-Output "Internet TCP/443 : $($net.TcpTestSucceeded)"
    if ($net.TcpTestSucceeded) { Add-Good "Internet TCP/443 OK" }
    else { Add-Issue "Không kết nối được Internet TCP/443" }
}
catch {
    Add-Warn "Không kiểm tra được Internet"
}

# HISTORY
Section 'NODE HISTORY'
$history = @()
if (Test-Path -LiteralPath $HistoryPath) {
    try {
        $raw = Get-Content -LiteralPath $HistoryPath -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        if ($obj -is [array]) { $history = @($obj) } else { $history = @($obj) }

        Write-Output "File     : $HistoryPath"
        Write-Output "Records  : $($history.Count)"

        $Report.history.file = $HistoryPath
        $Report.history.records = $history.Count

        if ($history.Count -gt 0) {
            $last = $history[-1]
            Write-Output "Latest   :"
            Write-Output ($last | ConvertTo-Json -Depth 6 -Compress)

            $temps = @(Get-MetricValues $history @('Temperature','Temp','temperature','temp'))
            $rams  = @(Get-MetricValues $history @('RAM','Ram','ram','MemoryPercent','Memory'))
            $cpus  = @(Get-MetricValues $history @('CPU','Cpu','cpu','CPUPercent'))

            $Report.history.metrics = [ordered]@{}

            foreach ($item in @(
                @{Key='temperature'; Name='Temperature'; Values=$temps},
                @{Key='ram'; Name='RAM'; Values=$rams},
                @{Key='cpu'; Name='CPU'; Values=$cpus}
            )) {
                $s = Stats $item.Values
                if ($null -ne $s) {
                    $Report.history.metrics[$item.Key] = $s
                    Write-Output "$($item.Name): min=$($s.Min) max=$($s.Max) avg=$($s.Average) median=$($s.Median) n=$($s.Count)"
                }
            }

            # Recent 7-day window when timestamps are available
            $dated = @($history | Where-Object { $null -ne (Get-TimeValue $_) })
            if ($dated.Count -gt 0) {
                $cut = $Now.AddDays(-7)
                $recent = @($dated | Where-Object { (Get-TimeValue $_) -ge $cut })
                $Report.history.recent7dRecords = $recent.Count
                Write-Output "Recent 7d records: $($recent.Count)"

                if ($recent.Count -gt 0) {
                    $recentTemps = @(Get-MetricValues $recent @('Temperature','Temp','temperature','temp'))
                    if ($recentTemps.Count -gt 0) {
                        $s7 = Stats $recentTemps
                        $Report.history.recent7dTemperature = $s7
                        Write-Output "Recent 7d temperature: min=$($s7.Min) max=$($s7.Max) avg=$($s7.Average) median=$($s7.Median)"
                    }
                }
            }

            Add-Good "Đọc được node_history.json: $($history.Count) record"
        }
        else {
            Add-Warn "node_history.json tồn tại nhưng không có record"
        }
    }
    catch {
        Write-Output "History error: $($_.Exception.Message)"
        Add-Warn "Không đọc được node_history.json"
    }
}
else {
    Write-Output "No node_history.json"
    Add-Warn "Chưa có node_history.json"
}

# SUMMARY / SCORE
Section 'SMART DIAGNOSTIC SUMMARY'

$score = 100 - ($Issues.Count * 25) - ($Warnings.Count * 8)
if ($score -lt 0) { $score = 0 }

if ($Issues.Count -eq 0 -and $Warnings.Count -eq 0) {
    $result = 'HEALTHY'
}
elseif ($Issues.Count -eq 0) {
    $result = 'HEALTHY_WITH_WARNINGS'
}
else {
    $result = 'NEEDS_ATTENTION'
}

$Report.score = $score
$Report.result = $result
$Report.good = @($Good)
$Report.warnings = @($Warnings)
$Report.issues = @($Issues)

Write-Output "Score    : $score/100"
Write-Output "Result   : $result"
Write-Output ""
Write-Output "OK       : $($Good.Count)"
$Good | ForEach-Object { Write-Output "  [OK] $_" }
Write-Output ""
Write-Output "WARNING  : $($Warnings.Count)"
$Warnings | ForEach-Object { Write-Output "  [WARN] $_" }
Write-Output ""
Write-Output "ISSUES   : $($Issues.Count)"
$Issues | ForEach-Object { Write-Output "  [ERROR] $_" }

# Save machine-readable result for Controller/Gemini
try {
    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
    Write-Output ""
    Write-Output "JSON     : $JsonPath"
}
catch {
    Write-Output "JSON     : failed to write"
}

Write-Output ""
Write-Output "=============================================="
Write-Output " AI_READY: diagnostic_latest.json created for Controller/Gemini"`nWrite-Output " Diagnostic completed - READ ONLY"
Write-Output " No system changes were made."
Write-Output "=============================================="

if ($result -eq 'HEALTHY') { exit 0 }
elseif ($result -eq 'HEALTHY_WITH_WARNINGS') { exit 1 }
else { exit 2 }
