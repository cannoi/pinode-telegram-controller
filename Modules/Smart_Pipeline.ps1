# ============================================================
# Smart_Pipeline.ps1  (COMPLETE vs proposal 2026-08-22)
# Normalize -> Intent -> Context/Trend -> Rules -> Gemini JSON
# -> Quality Gate -> Memory Fallback -> Composer -> Learn
# PowerShell 5.1 UTF-8 BOM
# ============================================================

function Get-SmartMemoryPaths {
    $root = $null
    try {
        if ($DataDir) { $root = Join-Path $DataDir 'SmartMemory' }
        elseif ($AppRoot) { $root = Join-Path $AppRoot 'Data\SmartMemory' }
    } catch {}
    if (-not $root) {
        try { $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'Data\SmartMemory' } catch { $root = 'Data\SmartMemory' }
    }
    New-Item -ItemType Directory -Path $root -Force -ErrorAction SilentlyContinue | Out-Null
    return @{
        Root            = $root
        QuestionMemory  = (Join-Path $root 'question_memory.json')
        DiagnosisMemory = (Join-Path $root 'diagnosis_memory.json')
        ResponseMemory  = (Join-Path $root 'response_memory.json')
        AnomalyMemory   = (Join-Path $root 'anomaly_memory.json')
        FeedbackLog     = (Join-Path $root 'feedback_log.jsonl')
    }
}

function Normalize-UserQuestion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (($Text.Trim()) -replace '\s+', ' ')
}

function Get-SmartQuestionIntent {
    param([Parameter(Mandatory)][string]$UserQuery)
    $q = $UserQuery.ToLowerInvariant()

    if ($q -match 'ram|bo nho|b[oộ] nh[ớơ]|memory') { return 'RAM' }
    if ($q -match 'cpu|processor') { return 'CPU' }
    if ($q -match 'nhiet|n[oó]ng|temp|temperature') { return 'TEMP' }
    if ($q -match 'disk|o dia|[oổ] c:|dung luong|free space') { return 'DISK' }
    if ($q -match 'docker|container') { return 'DOCKER' }
    if ($q -match 'port|cong 3140|c[oổ]ng 3140') { return 'PORT' }
    if ($q -match 'peer|incoming|outgoing') { return 'PEERS' }
    if ($q -match 'block|dong bo|[dđ][oồ]ng b[oộ]|sync|ledger|lech block') { return 'BLOCK_SYNC' }
    if ($q -match 'tai sao|t[aạ]i sao|vi sao|v[iì] sao|loi |l[oỗ]i|cham |ch[aậ]m|bat thuong|su co|s[uự] c[oố]') { return 'DIAGNOSIS' }
    if ($q -match 'xu huong|trend|on dinh|[oổ]n [dđ][iị]nh') { return 'TREND' }
    if ($q -match 'nen lam|de xuat|[dđ][eề] xu[aấ]t|khuyen nghi') { return 'RECOMMENDATION' }
    if ($q -match 'on khong|[oổ]n kh[oô]ng|khoe|tinh trang|status|trang thai|node sao|may toi|the nao|th[eế] n[aà]o') { return 'NODE_HEALTH' }
    return 'GENERAL'
}

function Get-HistorySampleValue {
    param($row, [string[]]$Names)
    foreach ($n in $Names) {
        try {
            $p = $row.PSObject.Properties[$n]
            if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
        } catch {}
    }
    return $null
}

function Convert-ToLongSafe($v) {
    if ($null -eq $v) { return $null }
    if ("$v" -match '^-?\d+$') { return [long]$v }
    return $null
}
function Convert-ToDblSafe($v) {
    try { return [double]$v } catch { return $null }
}

function Get-NodeTelemetryContext {
    param([int]$Window = 10)

    $hist = @()
    try {
        if (Get-Command Get-NodeHistory -ErrorAction SilentlyContinue) {
            $hist = @(Get-NodeHistory)
        }
    } catch {}
    if (-not $hist -or $hist.Count -eq 0) {
        try {
            if (Get-Command Get-LatestLiveRecord -ErrorAction SilentlyContinue) {
                $one = Get-LatestLiveRecord
                if ($one) { $hist = @($one) }
            }
        } catch {}
    }
    if (-not $hist -or $hist.Count -eq 0) { return $null }

    $recent = @($hist | Select-Object -Last $Window)
    $latest = $recent[-1]
    $first = $recent[0]

    $localNow = Convert-ToLongSafe (Get-HistorySampleValue $latest @('local','local_block','ledger'))
    $netNow   = Convert-ToLongSafe (Get-HistorySampleValue $latest @('network','network_block'))
    $localFirst = Convert-ToLongSafe (Get-HistorySampleValue $first @('local','local_block','ledger'))
    $gap = $null
    if ($null -ne $localNow -and $null -ne $netNow) { $gap = $netNow - $localNow }
    $blockProgress = $null
    if ($null -ne $localNow -and $null -ne $localFirst) { $blockProgress = $localNow - $localFirst }

    $ramNow = Convert-ToDblSafe (Get-HistorySampleValue $latest @('ram_sys','ram','RAM'))
    $cpuNow = Convert-ToDblSafe (Get-HistorySampleValue $latest @('cpu_sys','cpu','CPU'))
    $ramFirst = Convert-ToDblSafe (Get-HistorySampleValue $first @('ram_sys','ram','RAM'))
    $cpuFirst = Convert-ToDblSafe (Get-HistorySampleValue $first @('cpu_sys','cpu','CPU'))
    $age = Convert-ToDblSafe (Get-HistorySampleValue $latest @('ledger_age','age'))
    $inP = Get-HistorySampleValue $latest @('incoming','peer_in','in')
    $outP = Get-HistorySampleValue $latest @('outgoing','peer_out','out')
    $docker = [string](Get-HistorySampleValue $latest @('docker','Docker'))
    $port = [string](Get-HistorySampleValue $latest @('port','ports','Ports'))
    $sync = [string](Get-HistorySampleValue $latest @('sync','Sync','Node'))
    $temp = Convert-ToDblSafe (Get-HistorySampleValue $latest @('temp','Temp'))

    $gaps = @()
    $rams = @()
    $cpus = @()
    foreach ($r in $recent) {
        $lb = Convert-ToLongSafe (Get-HistorySampleValue $r @('local','local_block','ledger'))
        $nb = Convert-ToLongSafe (Get-HistorySampleValue $r @('network','network_block'))
        if ($null -ne $lb -and $null -ne $nb) { $gaps += ($nb - $lb) }
        $rv = Convert-ToDblSafe (Get-HistorySampleValue $r @('ram_sys','ram'))
        $cv = Convert-ToDblSafe (Get-HistorySampleValue $r @('cpu_sys','cpu'))
        if ($null -ne $rv) { $rams += $rv }
        if ($null -ne $cv) { $cpus += $cv }
    }

    $gapTrend = 'unknown'
    if ($gaps.Count -ge 3) {
        $g0 = $gaps[0]; $g1 = $gaps[-1]
        if ($g1 -gt ($g0 + 5)) { $gapTrend = 'increasing' }
        elseif ($g1 -lt ($g0 - 5)) { $gapTrend = 'decreasing' }
        else { $gapTrend = 'stable' }
    }
    $ramTrend = 'unknown'
    if ($rams.Count -ge 3) {
        if ($rams[-1] -gt ($rams[0] + 5)) { $ramTrend = 'rising' }
        elseif ($rams[-1] -lt ($rams[0] - 5)) { $ramTrend = 'falling' }
        else { $ramTrend = 'stable' }
    }
    $cpuTrend = 'unknown'
    if ($cpus.Count -ge 3) {
        if ($cpus[-1] -gt ($cpus[0] + 8)) { $cpuTrend = 'rising' }
        elseif ($cpus[-1] -lt ($cpus[0] - 8)) { $cpuTrend = 'falling' }
        else { $cpuTrend = 'stable' }
    }

    $events = @()
    if ($docker -match 'STOP|EXIT|DEAD') { $events += 'docker_not_running' }
    elseif ($docker -match 'RUN|UP|OK') { $events += 'docker_running' }
    if ($port -match 'CLOSE|FAIL') { $events += 'ports_closed' }
    elseif ($port -match 'OPEN|LISTEN|OK') { $events += 'ports_ok' }
    if ($null -ne $age -and $age -gt 60) { $events += 'ledger_age_high' }
    if ($null -ne $blockProgress -and $blockProgress -le 0 -and $recent.Count -ge 3) { $events += 'block_stalled' }
    if ($null -ne $blockProgress -and $blockProgress -gt 0) { $events += 'block_advancing' }
    if ($gapTrend -eq 'increasing') { $events += 'gap_widening' }
    if ($ramTrend -eq 'rising') { $events += 'ram_rising' }
    if ($cpuTrend -eq 'rising') { $events += 'cpu_rising' }

    # Staleness: latest sample time if present
    $ageSec = $null
    try {
        $tstr = [string](Get-HistorySampleValue $latest @('time','Updated','timestamp','ts'))
        if ($tstr) {
            $dt = [datetime]::Parse($tstr)
            $ageSec = [int]((Get-Date) - $dt).TotalSeconds
        }
    } catch {}

    return [pscustomobject]@{
        Timestamp     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Samples       = $recent.Count
        DataAgeSec    = $ageSec
        LocalBlock    = $localNow
        NetworkBlock  = $netNow
        BlockGap      = $gap
        BlockProgress = $blockProgress
        GapTrend      = $gapTrend
        RamTrend      = $ramTrend
        CpuTrend      = $cpuTrend
        LedgerAge     = $age
        Sync          = $sync
        DockerStatus  = $docker
        Ports         = $port
        Incoming      = $inP
        Outgoing      = $outP
        CpuUsage      = $cpuNow
        RamUsage      = $ramNow
        CpuDelta      = if ($null -ne $cpuNow -and $null -ne $cpuFirst) { [math]::Round($cpuNow - $cpuFirst, 1) } else { $null }
        RamDelta      = if ($null -ne $ramNow -and $null -ne $ramFirst) { [math]::Round($ramNow - $ramFirst, 1) } else { $null }
        Temp          = $temp
        Events        = $events
    }
}

function Invoke-LocalRuleEngine {
    param($Context, [string]$Intent)

    $status = 'NORMAL'
    $findings = New-Object System.Collections.Generic.List[string]
    $actions = New-Object System.Collections.Generic.List[string]
    $priorityHigh = New-Object System.Collections.Generic.List[string]
    $priorityWatch = New-Object System.Collections.Generic.List[string]

    if ($null -ne $Context.DataAgeSec -and $Context.DataAgeSec -gt 180) {
        $priorityWatch.Add("Telemetry cu ($($Context.DataAgeSec)s) - Live Monitor co the cham")
    }

    if ($null -ne $Context.RamUsage) {
        if ($Context.RamUsage -ge 90) {
            $status = 'CRITICAL'
            $findings.Add("RAM $($Context.RamUsage)% CRITICAL")
            $priorityHigh.Add('Kiem tra Docker/WSL; can nhac /cleanram')
        } elseif ($Context.RamUsage -ge 80) {
            if ($status -eq 'NORMAL') { $status = 'WARNING' }
            $findings.Add("RAM $($Context.RamUsage)% cao")
            $priorityWatch.Add('Theo doi RAM; neu >85% keo dai thi don RAM')
        } else {
            $findings.Add("RAM $($Context.RamUsage)% binh thuong")
        }
        if ($Context.RamTrend -eq 'rising') { $priorityWatch.Add('RAM dang tang trong cua so gan day') }
    }

    if ($null -ne $Context.CpuUsage) {
        if ($Context.CpuUsage -ge 90) {
            $status = 'CRITICAL'
            $findings.Add("CPU $($Context.CpuUsage)% CRITICAL")
        } elseif ($Context.CpuUsage -ge 75) {
            if ($status -eq 'NORMAL') { $status = 'WARNING' }
            $findings.Add("CPU $($Context.CpuUsage)% cao")
        } else {
            $findings.Add("CPU $($Context.CpuUsage)% binh thuong")
        }
        if ($Context.CpuTrend -eq 'rising') { $priorityWatch.Add('CPU dang tang') }
    }

    $d = [string]$Context.DockerStatus
    if ($d -match 'STOP|EXIT|DEAD') {
        $status = 'CRITICAL'
        $findings.Add("Docker/container khong chay: $d")
        $priorityHigh.Add('Kiem tra /docker; chi restart khi xac nhan stopped')
    } elseif ($d) {
        $findings.Add("Docker: $d")
    }

    $p = [string]$Context.Ports
    if ($p -match 'CLOSE|FAIL') {
        if ($status -eq 'NORMAL') { $status = 'WARNING' }
        $findings.Add("Port van de: $p")
        $priorityWatch.Add('Kiem tra 31401-31403 LISTEN')
    } elseif ($p) {
        $findings.Add("Ports: $p")
    }

    if ($null -ne $Context.BlockGap) {
        $g = [long]$Context.BlockGap
        if ($g -gt 200) {
            if ($status -eq 'NORMAL') { $status = 'WARNING' }
            $findings.Add("Block gap = $g (network - local)")
            if ($Context.GapTrend -eq 'increasing') {
                $findings.Add('Gap dang mo rong')
                $priorityWatch.Add('Theo doi sync 5-10 phut')
            }
        } elseif ($g -lt -50) {
            $findings.Add("Local vuot network $([math]::Abs($g)) - bat thuong")
        } else {
            $findings.Add("Block gap = $g chap nhan duoc")
        }
    }
    if ($Context.Events -contains 'block_stalled') {
        if ($status -eq 'NORMAL') { $status = 'WARNING' }
        $findings.Add('Local block khong tien trong cua so gan day')
        $priorityWatch.Add('Kiem tra process Node va mang')
    }
    if ($Context.Events -contains 'block_advancing') {
        $findings.Add("Block progress +$($Context.BlockProgress)")
    }
    if ($null -ne $Context.LedgerAge -and $Context.LedgerAge -gt 120) {
        if ($status -eq 'NORMAL') { $status = 'WARNING' }
        $findings.Add("Ledger age $($Context.LedgerAge)s cao")
    }

    try {
        $iin = [double]$Context.Incoming
        $oout = [double]$Context.Outgoing
        if ($iin -eq 0 -and $oout -eq 0) {
            if ($status -eq 'NORMAL') { $status = 'WARNING' }
            $findings.Add('Peers In+Out = 0')
            $priorityWatch.Add('Kiem tra mang va port')
        } else {
            $findings.Add("Peers In=$($Context.Incoming) Out=$($Context.Outgoing)")
        }
    } catch {}

    if ($priorityHigh.Count -eq 0 -and $priorityWatch.Count -eq 0) {
        $actions.Add('Tiep tuc theo doi; chua can can thiep')
    }

    # Persist anomaly patterns
    try {
        if ($status -in @('WARNING','CRITICAL')) {
            $paths = Get-SmartMemoryPaths
            $am = @()
            if (Test-Path -LiteralPath $paths.AnomalyMemory) {
                try { $am = @(Get-Content -LiteralPath $paths.AnomalyMemory -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $am = @() }
            }
            $am = @($am) + @([pscustomobject]@{
                at = (Get-Date).ToString('o'); intent = $Intent; status = $status
                events = $Context.Events; gap = $Context.BlockGap
            })
            if ($am.Count -gt 80) { $am = $am | Select-Object -Last 80 }
            ($am | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $paths.AnomalyMemory -Encoding UTF8
        }
    } catch {}

    return [pscustomobject]@{
        Intent        = $Intent
        Status        = $status
        Findings      = @($findings)
        PriorityHigh  = @($priorityHigh)
        PriorityWatch = @($priorityWatch)
        Actions       = @($actions)
        Confidence    = 0.85
    }
}

function Invoke-SmartGeminiAnalysis {
    param([string]$Question, [string]$Intent, $Context, $LocalDiag)
    if (-not (Get-Command Invoke-GeminiAPI -ErrorAction SilentlyContinue)) { return $null }

    $ctxJson = ($Context | ConvertTo-Json -Compress -Depth 5)
    $diagJson = ($LocalDiag | ConvertTo-Json -Compress -Depth 5)
    $prompt = @"
You are PI NODE DIAGNOSTIC ENGINE. Return ONE JSON object only (no markdown).

Schema:
{"intent":"$Intent","status":"NORMAL|WARNING|CRITICAL|UNKNOWN","confidence":0.0,"summary":"vietnamese text","evidence":["..."],"causes":["..."],"actions":["..."],"next_check_sec":60}

Rules:
1. Use ONLY supplied telemetry. Never invent numbers.
2. FACT > TREND > local diagnosis > inference.
3. Match depth to question (simple = short).
4. No false alarms when data is normal.
5. Do not recommend restart for small block gaps.
6. summary/evidence/causes/actions in Vietnamese.
7. confidence 0-1.

USER QUESTION:
$Question

INTENT: $Intent

TELEMETRY:
$ctxJson

LOCAL DIAGNOSIS:
$diagJson
"@
    try {
        $raw = Invoke-GeminiAPI -Prompt $prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $raw = $raw.Trim()
        if ($raw -match '(?s)\{.*\}') { $raw = $Matches[0] }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log ("SmartGemini fail: " + $_.Exception.Message)
        }
        return $null
    }
}

function Test-SmartAIResponseQuality {
    param($AiObj, [string]$Intent)
    if (-not $AiObj) { return $false }
    try {
        $summary = [string]$AiObj.summary
        if ([string]::IsNullOrWhiteSpace($summary)) { return $false }
        if ($summary.Length -lt 20) { return $false }
        if ($summary -match "(?i)i can't|cannot help|as an ai|sorry,? i") { return $false }
        $st = [string]$AiObj.status
        if ($st -notin @('NORMAL','WARNING','CRITICAL','UNKNOWN')) { return $false }
        if ($Intent -in @('NODE_HEALTH','DIAGNOSIS','BLOCK_SYNC','TREND','GENERAL')) {
            $ev = @($AiObj.evidence)
            if ($ev.Count -lt 1) { return $false }
        }
        $conf = 0.5
        try { $conf = [double]$AiObj.confidence } catch {}
        if ($conf -lt 0.35) { return $false }
        # Must not invent obvious fake tokens when we have real telemetry
        return $true
    } catch { return $false }
}

function Find-ResponseMemoryHit {
    param([string]$Intent, [string]$Status)
    try {
        $paths = Get-SmartMemoryPaths
        if (-not (Test-Path -LiteralPath $paths.ResponseMemory)) { return $null }
        $rows = @(Get-Content -LiteralPath $paths.ResponseMemory -Raw -Encoding UTF8 | ConvertFrom-Json)
        $hit = $rows | Where-Object { $_.intent -eq $Intent -and $_.status -eq $Status } | Select-Object -Last 1
        if ($hit -and $hit.text) { return [string]$hit.text }
    } catch {}
    return $null
}

function Save-SmartLearning {
    param([string]$Question, [string]$Intent, $LocalDiag, [string]$FinalText, [bool]$UsedAI, [bool]$UsedFallback)
    try {
        $paths = Get-SmartMemoryPaths
        $entry = (@{
            at = (Get-Date).ToString('o'); question = $Question; intent = $Intent
            status = if ($LocalDiag) { [string]$LocalDiag.Status } else { '' }
            used_ai = $UsedAI; fallback = $UsedFallback
        } | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $paths.FeedbackLog -Value $entry -Encoding UTF8

        # question memory
        $qm = @()
        if (Test-Path -LiteralPath $paths.QuestionMemory) {
            try { $qm = @(Get-Content -LiteralPath $paths.QuestionMemory -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $qm = @() }
        }
        $pat = $Question.ToLowerInvariant()
        if ($pat.Length -gt 80) { $pat = $pat.Substring(0, 80) }
        $qm = @($qm) + @([pscustomobject]@{ pattern = $pat; intent = $Intent; at = (Get-Date).ToString('o') })
        if ($qm.Count -gt 200) { $qm = $qm | Select-Object -Last 200 }
        ($qm | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $paths.QuestionMemory -Encoding UTF8

        # diagnosis memory
        if ($LocalDiag) {
            $dm = @()
            if (Test-Path -LiteralPath $paths.DiagnosisMemory) {
                try { $dm = @(Get-Content -LiteralPath $paths.DiagnosisMemory -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $dm = @() }
            }
            $dm = @($dm) + @([pscustomobject]@{
                intent = $Intent; status = [string]$LocalDiag.Status
                findings = $LocalDiag.Findings; at = (Get-Date).ToString('o')
            })
            if ($dm.Count -gt 100) { $dm = $dm | Select-Object -Last 100 }
            ($dm | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $paths.DiagnosisMemory -Encoding UTF8
        }

        # response memory (successful templates)
        if (-not [string]::IsNullOrWhiteSpace($FinalText) -and $LocalDiag) {
            $rm = @()
            if (Test-Path -LiteralPath $paths.ResponseMemory) {
                try { $rm = @(Get-Content -LiteralPath $paths.ResponseMemory -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $rm = @() }
            }
            $rm = @($rm) + @([pscustomobject]@{
                intent = $Intent; status = [string]$LocalDiag.Status
                text = $FinalText; at = (Get-Date).ToString('o')
            })
            if ($rm.Count -gt 60) { $rm = $rm | Select-Object -Last 60 }
            ($rm | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $paths.ResponseMemory -Encoding UTF8
        }
    } catch {}
}

function Format-SmartResponse {
    param([string]$Intent, $Context, $LocalDiag, $AiObj)

    $status = 'UNKNOWN'
    $summary = ''
    $evidence = @()
    $actions = @()
    $high = @()
    $watch = @()

    if ($AiObj) {
        try { $status = [string]$AiObj.status } catch {}
        try { $summary = [string]$AiObj.summary } catch {}
        try { $evidence = @($AiObj.evidence) } catch {}
        try { $actions = @($AiObj.actions) } catch {}
    }
    if ($LocalDiag) {
        if ([string]::IsNullOrWhiteSpace($status) -or $status -eq 'UNKNOWN') { $status = [string]$LocalDiag.Status }
        if ($evidence.Count -eq 0) { $evidence = @($LocalDiag.Findings) }
        if ($actions.Count -eq 0) { $actions = @($LocalDiag.Actions) }
        $high = @($LocalDiag.PriorityHigh)
        $watch = @($LocalDiag.PriorityWatch)
    }

    $icon = switch ($status) {
        'CRITICAL' { '[CRIT]' }
        'WARNING'  { '[WARN]' }
        'NORMAL'   { '[OK]' }
        default    { '[?]' }
    }

    $title = switch ($Intent) {
        'RAM' { 'RAM' }
        'CPU' { 'CPU' }
        'TEMP' { 'NHIET DO' }
        'DOCKER' { 'DOCKER' }
        'PORT' { 'PORTS' }
        'PEERS' { 'PEERS' }
        'BLOCK_SYNC' { 'BLOCK / DONG BO' }
        'DISK' { 'DISK' }
        'DIAGNOSIS' { 'CHAN DOAN' }
        'TREND' { 'XU HUONG' }
        'RECOMMENDATION' { 'DE XUAT' }
        default { 'NODE HEALTH' }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$icon $title - $status")
    $lines.Add('')

    if ($null -ne $Context.DataAgeSec -and $Context.DataAgeSec -gt 120) {
        $lines.Add("Luu y: du lieu Live ~$($Context.DataAgeSec)s truoc.")
        $lines.Add('')
    }

    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        $lines.Add($summary)
        $lines.Add('')
    }

    if ($Intent -in @('NODE_HEALTH','DIAGNOSIS','BLOCK_SYNC','TREND','GENERAL','RECOMMENDATION') -and $Context) {
        $lines.Add('BANG CHUNG:')
        if ($null -ne $Context.LocalBlock) { $lines.Add("- Local block: $($Context.LocalBlock)") }
        if ($null -ne $Context.NetworkBlock) { $lines.Add("- Network block: $($Context.NetworkBlock)") }
        if ($null -ne $Context.BlockGap) { $lines.Add("- Gap (network-local): $($Context.BlockGap) | trend $($Context.GapTrend)") }
        if ($null -ne $Context.BlockProgress) { $lines.Add("- Progress (window): +$($Context.BlockProgress)") }
        if ($null -ne $Context.RamUsage) { $lines.Add("- RAM: $($Context.RamUsage)% (delta $($Context.RamDelta), trend $($Context.RamTrend))") }
        if ($null -ne $Context.CpuUsage) { $lines.Add("- CPU: $($Context.CpuUsage)% (delta $($Context.CpuDelta), trend $($Context.CpuTrend))") }
        if ($Context.DockerStatus) { $lines.Add("- Docker: $($Context.DockerStatus)") }
        if ($Context.Ports) { $lines.Add("- Ports: $($Context.Ports)") }
        $lines.Add("- Samples: $($Context.Samples)")
        $lines.Add('')
    } elseif ($Intent -eq 'RAM' -and $Context) {
        $lines.Add("Hien tai: $($Context.RamUsage)%")
        $lines.Add("Xu huong: $($Context.RamTrend) (delta $($Context.RamDelta))")
        $lines.Add('')
    } elseif ($Intent -eq 'CPU' -and $Context) {
        $lines.Add("Hien tai: $($Context.CpuUsage)%")
        $lines.Add("Xu huong: $($Context.CpuTrend) (delta $($Context.CpuDelta))")
        $lines.Add('')
    } elseif ($Intent -eq 'DOCKER' -and $Context) {
        $lines.Add("Trang thai: $($Context.DockerStatus)")
        $lines.Add('')
    } elseif ($Intent -eq 'TEMP' -and $Context) {
        $lines.Add("Nhiet: $($Context.Temp) C")
        $lines.Add('')
    }

    if ($high.Count -gt 0) {
        $lines.Add('UU TIEN CAO:')
        foreach ($h in $high) { $lines.Add("- $h") }
        $lines.Add('')
    }
    if ($watch.Count -gt 0) {
        $lines.Add('CAN THEO DOI:')
        foreach ($w in $watch) { $lines.Add("- $w") }
        $lines.Add('')
    }
    if ($actions.Count -gt 0) {
        $lines.Add('DE XUAT:')
        foreach ($a in ($actions | Select-Object -First 5)) { $lines.Add("- $a") }
    }

    $text = ($lines -join "`n").Trim()
    if ($text.Length -gt 3800) { $text = $text.Substring(0, 3770) + "`n...(rut gon)" }
    return $text
}

function Invoke-SmartQuestionPipeline {
    param(
        [Parameter(Mandatory)][string]$Question,
        [switch]$SkipAI
    )

    $q = Normalize-UserQuestion -Text $Question
    if ([string]::IsNullOrWhiteSpace($q)) { return $null }

    $intent = Get-SmartQuestionIntent -UserQuery $q
    $ctx = Get-NodeTelemetryContext -Window 10
    if (-not $ctx) {
        return "Chua co du lieu telemetry Live. Hay chay Start_Controller (cua so Live), cho 1-2 phut roi hoi lai."
    }

    $local = Invoke-LocalRuleEngine -Context $ctx -Intent $intent

    $aiObj = $null
    $usedAI = $false
    $fallback = $false

    if (-not $SkipAI) {
        $aiObj = Invoke-SmartGeminiAnalysis -Question $q -Intent $intent -Context $ctx -LocalDiag $local
        $usedAI = [bool]$aiObj
        if (-not (Test-SmartAIResponseQuality -AiObj $aiObj -Intent $intent)) {
            if ($aiObj) {
                $aiObj2 = Invoke-SmartGeminiAnalysis -Question ($q + " | Expand with evidence from telemetry only.") -Intent $intent -Context $ctx -LocalDiag $local
                if (Test-SmartAIResponseQuality -AiObj $aiObj2 -Intent $intent) { $aiObj = $aiObj2 }
                else { $aiObj = $null; $fallback = $true }
            } else {
                $fallback = $true
            }
        }
    } else {
        $fallback = $true
    }

    # Memory fallback template if AI failed
    if ($fallback -and -not $aiObj) {
        $mem = Find-ResponseMemoryHit -Intent $intent -Status ([string]$local.Status)
        if ($mem) {
            $text = $mem
            Save-SmartLearning -Question $q -Intent $intent -LocalDiag $local -FinalText $text -UsedAI $false -UsedFallback $true
            return $text
        }
    }

    $text = Format-SmartResponse -Intent $intent -Context $ctx -LocalDiag $local -AiObj $aiObj
    Save-SmartLearning -Question $q -Intent $intent -LocalDiag $local -FinalText $text -UsedAI $usedAI -UsedFallback $fallback
    return $text
}
