# PI NODE TELEGRAM CONTROLLER PRO
# Windows PowerShell 5.1 - UTF-8 BOM
# Central Config + integrated scheduler + single-instance mutex
$ErrorActionPreference = 'Stop'
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
  $PSDefaultParameterValues['*:Encoding'] = 'utf8'
  chcp 65001 | Out-Null
} catch {}
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot = Split-Path -Parent $ScriptRoot
$ConfigFile = Join-Path $AppRoot 'Config\PiNode_Config.ps1'
if (!(Test-Path -LiteralPath $ConfigFile)) { throw "Khong tim thay Config trung tam: $ConfigFile" }
. $ConfigFile
$BASE_DIR=$AppRoot; $CONTROLLER_LOG=$ControllerLog; $LOG_DIR=$LogDir; $HISTORY_FILE=$HistoryFile
$CHAT_HISTORY_FILE = if ($ChatHistoryFile) { $ChatHistoryFile } else { Join-Path $DataDir 'chat_history.json' }
$CHAT_HISTORY_MAX = if ($ChatHistoryMaxRecords) { [int]$ChatHistoryMaxRecords } else { 500 }
$CHAT_HISTORY_CONTEXT_TURNS = if ($ChatHistoryContextTurns) { [int]$ChatHistoryContextTurns } else { 8 }
$REQUEST_TIMEOUT=$RequestTimeout; $POLL_TIMEOUT=$PollingTimeout; $MAX_LOG_BYTES=$MaxLogBytes
$HERMES_CONTAINER=$HermesContainer; $HERMES_TIMEOUT_SEC=$HermesTimeoutSec; $HERMES_INCLUDE_NODE_CONTEXT=$HermesIncludeNodeContext
$REGISTERED=$Registered
$BOT_TOKEN=$BotToken
$CHAT_ID=$ChatId
New-Item -ItemType Directory -Force -Path $BASE_DIR,$LOG_DIR,$StateDir | Out-Null
if ([string]::IsNullOrWhiteSpace($BotToken)) { throw 'CHUA CO BOT TOKEN trong Config\PiNode_Config.ps1' }
if ([string]::IsNullOrWhiteSpace($ChatId)) { throw 'CHUA CO CHAT ID trong Config\PiNode_Config.ps1' }
$script:ControllerMutex=New-Object System.Threading.Mutex($false,'Global\PiNodeTelegramControllerPRO')
try{$script:MutexOwned=$script:ControllerMutex.WaitOne(0,$false)}catch{$script:MutexOwned=$false}
if(-not $script:MutexOwned){exit 0}
$PID_FILE=Join-Path $StateDir 'controller.pid'
$SCHED_STATE=Join-Path $StateDir 'scheduler_state.json'
Set-Content -LiteralPath $PID_FILE -Value $PID -Encoding ASCII
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { try { Cleanup-Controller } catch {} } | Out-Null
function Cleanup-Controller { try{Remove-Item -LiteralPath $PID_FILE -Force -ErrorAction SilentlyContinue}catch{}; try{if($script:MutexOwned){$script:ControllerMutex.ReleaseMutex()|Out-Null}}catch{}; try{$script:ControllerMutex.Dispose()}catch{} }

function Write-Log {
    param([string]$Text)
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Text"
        Add-Content -Path $CONTROLLER_LOG -Value $line -Encoding UTF8
        if ((Test-Path $CONTROLLER_LOG) -and ((Get-Item $CONTROLLER_LOG).Length -gt $MAX_LOG_BYTES)) {
            Move-Item $CONTROLLER_LOG "$CONTROLLER_LOG.old" -Force
        }
    } catch {}
}


if ([string]::IsNullOrWhiteSpace($CHAT_ID)) {
    Write-Log 'CHUA CO CHAT_ID trong PiNode_Telegram_Config.ps1'
    throw 'CHUA CO CHAT_ID trong Config\PiNode_Config.ps1'
}

$script:PendingMaintenance = $false
$script:PendingMaintenanceAt = $null
$script:PendingReset = $false
$script:PendingResetAt = $null
$script:Offset = 0

function Invoke-Telegram {
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Body = @{},
        [int]$TimeoutSec = $REQUEST_TIMEOUT
    )
    $uri = "https://api.telegram.org/bot$BOT_TOKEN/$Method"
    try {
        # Gui JSON UTF-8 de tieng Viet co dau khong bi loi
        $json = $Body | ConvertTo-Json -Compress -Depth 8
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
    } catch {
        Write-Log "Telegram API loi $Method : $($_.Exception.Message)"
        return $null
    }
}

function Send-Text {
    param(
        [string]$Text,
        [switch]$Remember
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($Text.Length -gt 3900) { $Text = $Text.Substring(0,3890) + "`n...[rut gon]" }
    Invoke-Telegram 'sendMessage' @{ chat_id=$CHAT_ID; text=$Text; disable_web_page_preview='true' } | Out-Null
    # Ghi nhớ phản hồi bot khi được yêu cầu (hoặc theo cờ phiên NL)
    if ($Remember -or $script:RememberReply) {
        try {
            $intent = if ($script:LastChatIntent) { [string]$script:LastChatIntent } else { '' }
            $src = if ($script:LastChatSource) { [string]$script:LastChatSource } else { 'reply' }
            # Bỏ qua tin xác nhận ngắn để khỏi làm nhiễu ngữ cảnh
            if ($Text -notmatch '^📩 Đã nhận yêu cầu') {
                Add-ChatTurn -Role 'assistant' -Text $Text -Intent $intent -Source $src
            }
        } catch {}
        $script:RememberReply = $false
    }
}

function Send-Photo {
    param([string]$Path,[string]$Caption='')
    if (!(Test-Path -LiteralPath $Path)) { return $false }
    try {
        $uri = "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto"
        if ([string]::IsNullOrWhiteSpace($Caption)) {
            & curl.exe -sS --max-time 40 -X POST $uri -F "chat_id=$CHAT_ID" -F "photo=@$Path" | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        if ($Caption.Length -gt 1000) { $Caption = $Caption.Substring(0,990) + '...' }
        # Caption UTF-8 qua file tam (tranh loi dau tieng Viet)
        $capFile = Join-Path $env:TEMP ("pinode_cap_{0}.txt" -f $PID)
        [System.IO.File]::WriteAllText($capFile, $Caption, [System.Text.UTF8Encoding]::new($false))
        & curl.exe -sS --max-time 40 -X POST $uri -F "chat_id=$CHAT_ID" -F "photo=@$Path" -F "caption=<$capFile" | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
        Remove-Item -LiteralPath $capFile -Force -ErrorAction SilentlyContinue
        return $ok
    } catch {
        Write-Log "SendPhoto loi: $($_.Exception.Message)"
        return $false
    }
}

function Send-PhotoUrl {
    param([string]$Url,[string]$Caption='')
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $uri = "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto"
        $body = @{ chat_id = $CHAT_ID; photo = $Url }
        if (-not [string]::IsNullOrWhiteSpace($Caption)) {
            if ($Caption.Length -gt 1000) { $Caption = $Caption.Substring(0,990) + '...' }
            $body.caption = $Caption
        }
        Invoke-Telegram 'sendPhoto' $body | Out-Null
        return $true
    } catch {
        Write-Log "SendPhotoUrl loi: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Donate {
    $qrUrl = 'https://img.vietqr.io/image/MB-0905428801-compact2.png?accountName=TRAN%20HUU%20NGHI&addInfo=Ung%20ho%20Pi%20Node'
    $caption = @"
☕  ỦNG HỘ TÁC GIẢ
──────────────
Cảm ơn anh chị!
Mạnh tay ủng hộ — quán cà phê là vui 😄

🏦  MB Bank
💳  0905428801
👤  TRAN HUU NGHI

Chúc Node full bonus 🚀
"@
    $ok = $false
    try { $ok = Send-PhotoUrl -Url $qrUrl -Caption $caption } catch { $ok = $false }
    if ($ok) { return }

    $tmp = Join-Path $env:TEMP ("pinode_qr_{0}.png" -f $PID)
    try {
        Invoke-WebRequest -Uri $qrUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 25
        if (Test-Path -LiteralPath $tmp) { $ok = Send-Photo -Path $tmp -Caption $caption }
    } catch { Write-Log "QR download: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($ok) { return }
    Send-Text ($caption + "`n`n📱 " + $qrUrl)
}




function Get-ChatHistory {
    if (!(Test-Path -LiteralPath $CHAT_HISTORY_FILE)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $CHAT_HISTORY_FILE -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    } catch {
        Write-Log "Khong doc duoc chat_history.json: $($_.Exception.Message)"
        return @()
    }
}

function Save-ChatHistory {
    param([array]$Records)
    try {
        $dir = Split-Path -Parent $CHAT_HISTORY_FILE
        if ($dir -and !(Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $max = [math]::Max(50, $CHAT_HISTORY_MAX)
        if ($Records.Count -gt $max) {
            $Records = @($Records | Select-Object -Last $max)
        }
        ($Records | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $CHAT_HISTORY_FILE -Encoding UTF8
    } catch {
        Write-Log "Khong ghi duoc chat_history.json: $($_.Exception.Message)"
    }
}

function Add-ChatTurn {
    param(
        [Parameter(Mandatory)][ValidateSet('user','assistant','system')][string]$Role,
        [Parameter(Mandatory)][string]$Text,
        [string]$Intent = '',
        [string]$Source = 'natural'
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        $clip = $Text.Trim()
        if ($clip.Length -gt 1500) { $clip = $clip.Substring(0, 1500) + '…' }

        $records = @(Get-ChatHistory)
        $records += [pscustomobject]@{
            id     = [guid]::NewGuid().ToString('N').Substring(0, 12)
            time   = (Get-Date).ToString('o')
            role   = $Role
            text   = $clip
            intent = $Intent
            source = $Source
        }
        Save-ChatHistory -Records $records
    } catch {
        Write-Log "Add-ChatTurn loi: $($_.Exception.Message)"
    }
}

function Get-ChatHistoryContext {
    param([int]$Turns = 0)
    if ($Turns -le 0) { $Turns = $CHAT_HISTORY_CONTEXT_TURNS }
    $all = @(Get-ChatHistory)
    if ($all.Count -eq 0) { return 'CHUA CO LICH SU TRO CHUYEN.' }
    $recent = @($all | Select-Object -Last ([math]::Max(1, $Turns * 2)))
    $lines = @()
    foreach ($r in $recent) {
        $who = if ($r.role -eq 'user') { 'Nguoi dung' } elseif ($r.role -eq 'assistant') { 'Bot' } else { 'He thong' }
        $t = [string]$r.text
        if ($t.Length -gt 280) { $t = $t.Substring(0, 280) + '…' }
        $lines += ("[{0}] {1}: {2}" -f $r.time, $who, $t)
    }
    return ($lines -join "`n")
}

function Get-ChatHistoryInsights {
    # Tong hop de sau nay goi y nang cap app
    $all = @(Get-ChatHistory)
    if ($all.Count -eq 0) {
        return [pscustomobject]@{ total=0; user_messages=0; intents=@{}; top_topics=@() } | ConvertTo-Json -Compress
    }
    $users = @($all | Where-Object { $_.role -eq 'user' })
    $intentCount = @{}
    foreach ($u in $users) {
        $i = if ([string]::IsNullOrWhiteSpace([string]$u.intent)) { 'UNKNOWN' } else { [string]$u.intent }
        if (-not $intentCount.ContainsKey($i)) { $intentCount[$i] = 0 }
        $intentCount[$i]++
    }
    $topics = @{
        temperature = @($users | Where-Object { $_.text -match 'nóng|nong|nhiệt|nhiet|temp' }).Count
        ram = @($users | Where-Object { $_.text -match 'ram|bộ nhớ|bo nho' }).Count
        cpu = @($users | Where-Object { $_.text -match 'cpu' }).Count
        disk = @($users | Where-Object { $_.text -match 'ổ cứng|o cung|disk|dung lượng|dung luong' }).Count
        upgrade = @($users | Where-Object { $_.text -match 'nâng cấp|nang cap|upgrade' }).Count
        docker = @($users | Where-Object { $_.text -match 'docker|container' }).Count
        diagnostic = @($users | Where-Object { $_.text -match 'chẩn đoán|chan doan|lỗi|loi' }).Count
        status = @($users | Where-Object { $_.text -match 'thế nào|the nao|tình trạng|tinh trang' }).Count
    }
    return [pscustomobject]@{
        total = $all.Count
        user_messages = $users.Count
        intents = $intentCount
        top_topics = $topics
        first_time = $all[0].time
        last_time = $all[-1].time
    } | ConvertTo-Json -Depth 5 -Compress
}

function Get-NodeHistory {
    if (!(Test-Path -LiteralPath $HISTORY_FILE)) { return @() }
    try {
        $raw = Get-Content $HISTORY_FILE -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $x = $raw | ConvertFrom-Json
        if ($x -is [array]) { return @($x) }
        return @($x)
    } catch {
        Write-Log "Khong doc duoc node_history.json: $($_.Exception.Message)"
        return @()
    }
}

function To-Num($v) {
    try { return [double]$v } catch { return $null }
}

function Get-NodeStatus {
    $h = @(Get-NodeHistory)
    if ($h.Count -eq 0) {
        return "⚠️ Chưa có dữ liệu.`n👉 Gửi /monitor để kiểm tra."
    }
    $x = $h[-1]
    $time = try { ([datetime]$x.time).ToString('dd/MM HH:mm') } catch { "$($x.time)" }
    $problem = 0; $critical = 0; $severity = 'OK'
    try { $problem = [int]$x.problems } catch {}
    try { $critical = [int]$x.critical } catch {}
    try { if ($x.severity) { $severity = [string]$x.severity } } catch {}
    $sync = [string]$x.sync
    $tempRaw = "$($x.temp)"
    $temp = if ($tempRaw -and $tempRaw -ne '' -and $tempRaw -ne 'N/A' -and $tempRaw -ne '0') { $tempRaw } else { '—' }
    # Ổn định khi sync+docker+port tốt và không có critical (warnings tài nguyên không làm đỏ cả node)
    $good = ($sync -eq 'Dong bo tot' -and [string]$x.docker -eq 'RUNNING' -and [string]$x.port -eq 'OPEN' -and $critical -eq 0 -and $severity -ne 'CRITICAL')
    $warnOnly = ($good -eq $false -and $critical -eq 0 -and $severity -eq 'WARNING')

    $head = if ($good) { "🟢 TRẠNG THÁI NODE — ỔN ĐỊNH" }
            elseif ($warnOnly) { "🟡 TRẠNG THÁI NODE — CÓ CẢNH BÁO" }
            else { "🔴 TRẠNG THÁI NODE — CẦN XEM" }
    $sI = if ($sync -eq 'Dong bo tot') { '✅' } elseif ($sync -match 'dong bo|Sync') { '🔄' } else { '⚠️' }
    $dI = if ([string]$x.docker -eq 'RUNNING') { '✅' } else { '❌' }
    $pI = if ([string]$x.port -eq 'OPEN') { '✅' } else { '❌' }

    $t = "$head`n"
    $t += "──────────────`n"
    $t += "🕐 $time`n"
    $syncShow = if ($sync -eq 'Dong bo tot') { 'Đồng bộ tốt' } elseif ($sync -eq 'Dang dong bo') { 'Đang đồng bộ' } elseif ($sync -eq 'Chua dong bo' -or $sync -eq 'Lech khoi') { 'Chưa đồng bộ' } else { $sync }
    $t += "$sI  Đồng bộ · $syncShow`n"
    $t += "📦  Khối · $($x.local) / $($x.latest)`n"
    $t += "🐳  Docker · $($x.docker) $dI`n"
    $t += "🔌  Cổng · $($x.port) $pI`n"
    $t += "🧠  RAM · $($x.ram_sys)%   ⚙️ CPU · $($x.cpu_sys)%`n"
    $t += "🌡️  Nhiệt độ · $temp°C"
    if ($critical -gt 0) { $t += "`n🚨  Sự cố nghiêm trọng · $critical" }
    elseif ($severity -eq 'WARNING' -and $problem -gt 0) { $t += "`n⚠️  Cảnh báo · $problem" }
    return $t
}

function Get-NodeReport {
    param([int]$Days = 1)
    if ($Days -lt 1) { $Days = 1 }
    $h = @(Get-NodeHistory)
    if ($h.Count -eq 0) { return "⚠️ Chưa có dữ liệu history.`n👉 Gửi /monitor để tạo dữ liệu." }

    $cut = (Get-Date).AddDays(-$Days)
    $day = @($h | Where-Object { try { [datetime]$_.time -ge $cut } catch { $false } })
    if ($day.Count -eq 0) { return "⚠️ Không có dữ liệu trong $Days ngày vừa qua.`n👉 Hãy chạy /monitor thường xuyên hơn để có đủ dữ liệu thống kê." }

    $problems = @($day | Where-Object { try { [int]$_.problems -gt 0 } catch { $false } }).Count
    $syncOk = @($day | Where-Object { [string]$_.sync -eq 'Dong bo tot' }).Count
    $dockerOk = @($day | Where-Object { [string]$_.docker -eq 'RUNNING' }).Count
    $portOk = @($day | Where-Object { [string]$_.port -eq 'OPEN' }).Count
    $temps = @($day | ForEach-Object { To-Num $_.temp } | Where-Object { $null -ne $_ })
    $rams = @($day | ForEach-Object { To-Num $_.ram_sys } | Where-Object { $null -ne $_ })
    $cpus = @($day | ForEach-Object { To-Num $_.cpu_sys } | Where-Object { $null -ne $_ })
    $tempText = if ($temps.Count) { "{0}–{1}°C" -f [math]::Round(($temps|Measure-Object -Minimum).Minimum,0), [math]::Round(($temps|Measure-Object -Maximum).Maximum,0) } else { '—' }
    $ramText = if ($rams.Count) { "{0}–{1}%" -f [math]::Round(($rams|Measure-Object -Minimum).Minimum,0), [math]::Round(($rams|Measure-Object -Maximum).Maximum,0) } else { '—' }
    $cpuText = if ($cpus.Count) { "{0}–{1}%" -f [math]::Round(($cpus|Measure-Object -Minimum).Minimum,0), [math]::Round(($cpus|Measure-Object -Maximum).Maximum,0) } else { '—' }

    $ok = ($problems -eq 0 -and $syncOk -eq $day.Count -and $dockerOk -eq $day.Count -and $portOk -eq $day.Count)
    $periodText = if ($Days -eq 1) { '24H' } elseif ($Days -eq 7) { '7 NGÀY' } elseif ($Days -eq 30) { '30 NGÀY' } else { "$Days NGÀY" }
    $head = if ($ok) { "🟢  BÁO CÁO $periodText · ỔN ĐỊNH" } else { "🟠  BÁO CÁO $periodText · CẦN THEO DÕI" }

    $t = "$head`n"
    $t += "━━━━━━━━━━━━━━━━━━`n"
    $t += "📅  Khoảng thời gian · $Days ngày`n"
    $t += "📋  Lần quét · $($day.Count)`n"
    $t += "✅  Đồng bộ · $syncOk/$($day.Count)`n"
    $t += "🐳  Docker · $dockerOk/$($day.Count)`n"
    $t += "🔌  Cổng · $portOk/$($day.Count)`n"
    $t += "🧠  RAM · $ramText`n"
    $t += "⚙️  CPU · $cpuText`n"
    $t += "🌡️  Nhiệt độ · $tempText`n"
    $t += "⚠️  Lần có vấn đề · $problems`n"
    if ($ok) { $t += "`n💡 Kết luận: Pi Node hoạt động ổn định trong khoảng thời gian đã chọn." }
    else { $t += "`n💡 Kết luận: Có ít nhất một chỉ số bất thường. Nên chạy /monitor hoặc /diagnostic để kiểm tra chi tiết." }
    return $t
}

function Get-StatPeriodLabel {
    param([int]$Days)
    if($Days -eq 1){return '24 giờ'}
    if($Days -eq 7){return '7 ngày'}
    if($Days -eq 30){return '30 ngày'}
    if($Days -eq 90){return '90 ngày'}
    if($Days -eq 365){return '365 ngày'}
    return "$Days ngày"
}

function Get-HistoryRows {
    param([int]$Days = 7)
    $h=@(Get-NodeHistory)
    if($h.Count -eq 0){ return @() }
    $cut=(Get-Date).AddDays(-[math]::Max(1,$Days))
    return @($h | Where-Object { try {[datetime]$_.time -ge $cut} catch {$false} })
}

function Get-StatNumberArray {
    param([array]$Rows,[string]$Property)
    $vals = @($Rows | ForEach-Object { To-Num $_.$Property } | Where-Object { $null -ne $_ })
    # Nhiệt độ 0 hoặc ngoài 15–120°C coi như không hợp lệ (thường do thiếu sensor/PiCheck)
    if ($Property -match 'temp') {
        $vals = @($vals | Where-Object { $_ -ge 15 -and $_ -le 120 })
    }
    return $vals
}

function Get-StatAverage {
    param([array]$Values)
    if(!$Values -or $Values.Count -eq 0){return $null}
    return [math]::Round((($Values | Measure-Object -Average).Average),1)
}

function Get-StatMedian {
    param([array]$Values)
    if(!$Values -or $Values.Count -eq 0){return $null}
    $a=@($Values | Sort-Object)
    $n=$a.Count
    if($n % 2){ return [math]::Round([double]$a[[int]($n/2)],1) }
    return [math]::Round((([double]$a[$n/2-1]+[double]$a[$n/2])/2),1)
}

function Get-TemperatureAnalysis {
    param([int]$Days=7)
    $rows=@(Get-HistoryRows -Days $Days)
    $period=Get-StatPeriodLabel -Days $Days
    if($rows.Count -eq 0){return "⚠️ Không có dữ liệu nhiệt độ trong $period vừa qua.`n👉 Hãy chạy /monitor để tạo history."}
    $vals=@(Get-StatNumberArray -Rows $rows -Property 'temp')
    if($vals.Count -eq 0){return "⚠️ Có $($rows.Count) bản ghi nhưng chưa có dữ liệu nhiệt độ."}

    $min=[math]::Round(($vals|Measure-Object -Minimum).Minimum,1)
    $max=[math]::Round(($vals|Measure-Object -Maximum).Maximum,1)
    $avg=Get-StatAverage $vals
    $median=Get-StatMedian $vals
    $p25=[math]::Round((($vals|Sort-Object)[[math]::Max(0,[math]::Floor(($vals.Count-1)*0.25))]),1)
    $p75=[math]::Round((($vals|Sort-Object)[[math]::Max(0,[math]::Floor(($vals.Count-1)*0.75))]),1)

    # Practical monitoring bands for the report. These are informational thresholds, not hardware safety limits.
    $cool=@($vals|Where-Object {$_ -lt 50}).Count
    $normal=@($vals|Where-Object {$_ -ge 50 -and $_ -lt 60}).Count
    $warm=@($vals|Where-Object {$_ -ge 60 -and $_ -lt 70}).Count
    $high=@($vals|Where-Object {$_ -ge 70 -and $_ -lt 80}).Count
    $veryHigh=@($vals|Where-Object {$_ -ge 80}).Count
    $hot=$high+$veryHigh
    $hotPct=[math]::Round(($hot*100.0/$vals.Count),1)

    $peak=$null
    try { $peak=$rows | ForEach-Object { [pscustomobject]@{time=$_.time;temp=(To-Num $_.temp)} } | Where-Object {$null -ne $_.temp} | Sort-Object temp -Descending | Select-Object -First 1 } catch {}
    $peakText='Không xác định'
    if($peak){try{$peakText="{0} · {1}°C" -f ([datetime]$peak.time).ToString('dd/MM HH:mm'),([math]::Round($peak.temp,1))}catch{$peakText="$($peak.time) · $($peak.temp)°C"}}

    $status=if($veryHigh -gt 0){'🔴 Có thời điểm rất cao (≥80°C)'}elseif($high -gt 0){'🟠 Có thời điểm cao (70–79°C)'}elseif($warm -gt 0){'🟡 Có thời điểm ấm (60–69°C), nhìn chung ổn'}else{'🟢 Không thấy mức nhiệt cao'}
    $conclusion = if($veryHigh -gt 0){"Máy có lúc nóng cao trong $period. Nên kiểm tra tản nhiệt / luồng gió."}
                  elseif($high -gt 0){"Máy có một số thời điểm nhiệt cao trong $period, nhưng chưa kéo dài liên tục."}
                  elseif($avg -ge 65){"Nhiệt độ trung bình hơi ấm trong $period ($avg°C). Vẫn trong mức theo dõi bình thường."}
                  else{"Máy chạy không nóng trong $period. Nhiệt độ ổn định."}

    $t="🌡️ NHIỆT ĐỘ · $period`n"
    $t+="🔎 $conclusion`n`n"
    $t+="📋 Mẫu đo · $($vals.Count) bản ghi`n"
    $t+="📉 Thấp nhất · $min°C`n"
    $t+="📈 Cao nhất · $max°C`n"
    $t+="📊 Trung bình · $avg°C · Trung vị · $median°C`n"
    $t+="📐 Phổ biến (25–75%) · $p25–$p75°C`n"
    $t+="🔥 Đỉnh · $peakText`n`n"
    $t+="Phân bố:`n"
    $t+="• <50°C: $cool · 50–59°C: $normal · 60–69°C: $warm`n"
    $t+="• 70–79°C: $high · ≥80°C: $veryHigh`n"
    $t+="• Tỷ lệ ≥70°C: $hotPct%`n`n"
    $t+="$status"
    return $t
}

function Get-DynamicStatistics {
    param([Parameter(Mandatory)][string]$Question,[int]$Days=7)
    $q=$Question.ToLowerInvariant()
    # Temperature is the most specific metric: answer it directly instead of returning a generic report.
    if($q -match 'nhiệt|nhiet|nong|nóng|temperature|temp|nhiet do|nhiệt độ') { return Get-TemperatureAnalysis -Days $Days }

    $rows=@(Get-HistoryRows -Days $Days)
    $period=Get-StatPeriodLabel -Days $Days
    if($rows.Count -eq 0){return "⚠️ Không có dữ liệu trong $period vừa qua."}

    if($q -match 'ram|bộ nhớ|bo nho|memory'){
        $v=@(Get-StatNumberArray -Rows $rows -Property 'ram_sys'); if(!$v.Count){return '⚠️ Chưa có dữ liệu RAM.'}
        $mi=[math]::Round(($v|Measure-Object -Minimum).Minimum,1);$ma=[math]::Round(($v|Measure-Object -Maximum).Maximum,1);$av=Get-StatAverage $v
        return "🧠 PHÂN TÍCH RAM · $period`n━━━━━━━━━━━━━━━━━━`n📋 Mẫu đo · $($v.Count)`n📉 Thấp nhất · $mi%`n📈 Cao nhất · $ma%`n📊 Trung bình · $av%`n🎯 Trung vị · $(Get-StatMedian $v)%"
    }
    if($q -match 'cpu|processor|vi xu ly|vi xử lý'){
        $v=@(Get-StatNumberArray -Rows $rows -Property 'cpu_sys'); if(!$v.Count){return '⚠️ Chưa có dữ liệu CPU.'}
        $mi=[math]::Round(($v|Measure-Object -Minimum).Minimum,1);$ma=[math]::Round(($v|Measure-Object -Maximum).Maximum,1);$av=Get-StatAverage $v
        return "⚙️ PHÂN TÍCH CPU · $period`n━━━━━━━━━━━━━━━━━━`n📋 Mẫu đo · $($v.Count)`n📉 Thấp nhất · $mi%`n📈 Cao nhất · $ma%`n📊 Trung bình · $av%`n🎯 Trung vị · $(Get-StatMedian $v)%"
    }
    # If the user asks a history/statistics question without a specific metric, keep the full report.
    return Get-NodeReport -Days $Days
}

function Get-Logs {
    $files = @()
    if (Test-Path $CONTROLLER_LOG) { $files += Get-Item $CONTROLLER_LOG }
    if (Test-Path $LOG_DIR) { $files += @(Get-ChildItem $LOG_DIR -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3) }
    if ($files.Count -eq 0) { return "Chua co log." }

    $out = "📝 LOG GAN NHAT`n`n"
    foreach ($f in $files) {
        $out += "=== $($f.Name) ===`n"
        try {
            $lines = Get-Content $f.FullName -Tail 12 -ErrorAction Stop
            $out += (($lines -join "`n") + "`n")
        } catch {
            $out += "Khong doc duoc file.`n"
        }
    }
    return $out
}

function Get-DockerStatus {
    try {
        $svc = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
        $docker = (& docker version --format '{{.Server.Version}}' 2>$null)
        $containers = (& docker ps --format '{{.Names}}|{{.Status}}' 2>$null)
        $text = "🐳 DOCKER`n`n"
        $text += "Service: " + $(if ($svc) { $svc.Status } else { 'N/A' }) + "`n"
        $text += "Engine: " + $(if ($docker) { "OK ($docker)" } else { 'Khong truy cap duoc' }) + "`n"
        if ($containers) {
            $text += "Container dang chay:`n" + ($containers -join "`n")
        } else {
            $text += "Container dang chay: Khong thay"
        }
        return $text
    } catch {
        return "🔴 Docker check loi: $($_.Exception.Message)"
    }
}

function Get-DiskStatus {
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $total = [math]::Round($d.Size/1GB,1)
        $free = [math]::Round($d.FreeSpace/1GB,1)
        $used = [math]::Round(100*(1-$d.FreeSpace/$d.Size),1)
        return "💽 O C:`n`nTong: $total GB`nTrong: $free GB`nDa dung: $used%"
    } catch {
        return "🔴 Khong doc duoc o C: $($_.Exception.Message)"
    }
}

function Get-HermesContainer {
    # Neu cau hinh HERMES_CONTAINER, dung container do.
    # Neu de trong, tu dong tim container co ten chua "hermes".
    try {
        if (-not [string]::IsNullOrWhiteSpace($HERMES_CONTAINER)) {
            $exists = (& docker inspect $HERMES_CONTAINER --format '{{.State.Running}}' 2>$null)
            if ([string]$exists -eq 'true') { return $HERMES_CONTAINER }
            Write-Log "Hermes container cau hinh khong chay: $HERMES_CONTAINER"
            return $null
        }

        $names = @(& docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -match '(?i)hermes' })
        if ($names.Count -eq 1) { return [string]$names[0] }
        if ($names.Count -gt 1) {
            Write-Log "Tim thay nhieu Hermes container: $($names -join ', '). Hay dien HERMES_CONTAINER."
            return $null
        }

        Write-Log "Khong tim thay container Hermes dang chay."
        return $null
    } catch {
        Write-Log "Get-HermesContainer loi: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-Hermes {
    param([Parameter(Mandatory)][string]$Question)

    $container = Get-HermesContainer
    if ([string]::IsNullOrWhiteSpace($container)) {
        return "🔴 KHONG KET NOI DUOC HERMES.`n`nKhong tim thay container Hermes dang chay.`n`nHay kiem tra HERMES_CONTAINER trong PiNode_Telegram_Config.ps1 va chay:`ndocker ps"
    }
    # /ask la kenh chat AI truc tiep.
    # Khong chen RAM/Docker/Disk/Pi Node context vao moi cau hoi.
    # Hermes se nhan dung noi dung nguoi dung da go sau /ask.
    $context = $Question.Trim()

    if ([string]::IsNullOrWhiteSpace($context)) {
        return "🟡 Hay nhap cau hoi sau /ask. Vi du:`n/ask tiếp tục phân tích chuyên sâu GCV"
    }

    # Quote mot argument theo quy tac command-line cua Windows.
    function ConvertTo-WindowsArgument {
        param([AllowNull()][string]$Value)

        if ($null -eq $Value) { return '""' }
        if ($Value -notmatch '[\s"]') { return $Value }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0

        foreach ($ch in $Value.ToCharArray()) {
            if ($ch -eq '\') {
                $slashes++
                continue
            }

            if ($ch -eq '"') {
                if ($slashes -gt 0) {
                    [void]$sb.Append(('\' * ($slashes * 2)))
                    $slashes = 0
                }
                [void]$sb.Append('\"')
                continue
            }

            if ($slashes -gt 0) {
                [void]$sb.Append(('\' * $slashes))
                $slashes = 0
            }
            [void]$sb.Append($ch)
        }

        if ($slashes -gt 0) {
            [void]$sb.Append(('\' * ($slashes * 2)))
        }

        [void]$sb.Append('"')
        return $sb.ToString()
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = 'docker.exe'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Hermes tra ve UTF-8. Ep PowerShell doc stdout/stderr bang UTF-8
    # de tranh loi tieng Viet kieu "PH├éN T├ìCH..." tren Telegram.
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    # QUAN TRỌNG: truyền prompt trực tiếp sau -z.
    $containerArg = ConvertTo-WindowsArgument $container
    $contextArg   = ConvertTo-WindowsArgument $context
    $psi.Arguments = "exec $containerArg hermes -z $contextArg"

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        Write-Log "Gui cau hoi sang Hermes container=$container"
        if (-not $proc.Start()) {
            return "🔴 Khong khoi dong duoc tien trinh Hermes."
        }

        $timeoutMs = [int]($HERMES_TIMEOUT_SEC * 1000)
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill() } catch {}
            Write-Log "Hermes timeout sau $HERMES_TIMEOUT_SEC giay."
            return "⏱️ HERMES KHONG PHAN HOI TRONG $HERMES_TIMEOUT_SEC GIAY.`n`nNode Controller van dang hoat dong binh thuong."
        }

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $exitCode = $proc.ExitCode

        if ($exitCode -ne 0) {
            Write-Log "Hermes exit code=$exitCode stderr=$stderr"
            $err = if ([string]::IsNullOrWhiteSpace($stderr)) { "Khong co thong tin loi." } else { $stderr.Trim() }
            if ($err.Length -gt 1200) { $err = $err.Substring(0,1200) + "..." }
            return "🔴 HERMES LOI (ExitCode $exitCode)`n`n$err"
        }

        $answer = $stdout.Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return "🟡 Hermes da xu ly nhung khong tra ve noi dung."
        }

        Write-Log "Hermes tra loi thanh cong. Length=$($answer.Length)"
        return "🤖 HERMES`n`n$answer"
    } catch {
        Write-Log "Invoke-Hermes loi: $($_.Exception.Message)"
        return "🔴 Loi ket noi Hermes:`n$($_.Exception.Message)"
    } finally {
        $proc.Dispose()
    }
}

function Invoke-HermesQuestion {
    param([string]$Question)
    if ([string]::IsNullOrWhiteSpace($Question)) {
        Send-Text "❓ Cach dung:`n/ask <cau hoi cho Hermes>`n`nVi du:`n/ask Phan tich tinh trang Pi Node hien tai cua toi."
        return
    }

    Send-Text "🤖 Hermes dang xu ly cau hoi...`n⏳ Co the mat den $HERMES_TIMEOUT_SEC giay.`n📝 Dang phan tich, vui long cho."
    $answer = Invoke-Hermes -Question $Question
    Send-Text $answer
}


# ============================================================
# GEMINI NATURAL LANGUAGE + APP KNOWLEDGE BASE
# ============================================================
$script:GeminiKnowledge = @'
PI NODE TELEGRAM CONTROLLER PRO - KIEN THUC HE THONG

MUC DICH UNG DUNG:
- Bo dieu khien va giam sat Pi Node tren Windows qua Telegram.
- Theo doi Pi Node/PiCheck, Docker, CPU, RAM, o C:, log, scheduler va lich su node.
- Cho phep dieu khien tu xa cac tac vu an toan va cac tac vu nguy hiem co xac nhan.
- Gemini la lop AI hieu ngon ngu tu nhien; khong tu y chay PowerShell. Controller moi la thanh phan thuc thi.
- Hermes la kenh AI truc tiep cho /ask. Gemini Natural Language duoc dung de hieu tin nhan tu nhien va tra loi cac cau hoi ve app.

CAU TRUC:
- Config/PiNode_Config.ps1: cau hinh Telegram BotToken, ChatId, GeminiApiKey, danh sach model Gemini, Hermes container, timeout, nguong canh bao, lich scheduler va duong dan module.
- Controller/PiNode_Telegram_Controller_PRO_v2.0.ps1: bo nao trung tam; nhan Telegram, dieu phoi lenh, scheduler, log, goi module, gui text/photo.
- Data/PiNode_SmartMonitor_v9_CentralConfig.ps1: monitor Pi Node; doc thong tin tu cua so PiCheck, OCR/AI, kiem tra CPU/RAM/nhiet do/sync/ledger/port theo logic cua script va ghi history.
- Data/CleanRAM_PiNode.ps1: don RAM va rac he thong theo logic module; dung khi may nang.
- Data/Weekly_Maintenance.ps1: bao tri dinh ky; cleanup he thong/Docker va cac tac vu toi uu theo script. /maintenance luon yeu cau /confirm khi nguoi dung goi thu cong.
- Data/Diagnostic.ps1: chan doan nhanh cac van de cua Node/he thong.
- Data/Reset_Node_Network.ps1: xu ly mang/Node; co the dat IP, firewall port 31401-31410, reset Docker/WSL theo tuy chon cua script. Day la tac vu nguy hiem va phai xac nhan /confirmreset.
- Data/send_tele.ps1: tien ich gui Telegram.
- Setup_Config.ps1: nhap/cap nhat Bot Token, Chat ID, Gemini API Key, chu ky monitor va nguong RAM.
- Setup_Config.bat: goi Setup_Config.ps1.
- Check_Installation.bat: kiem tra cac file/cau hinh can thiet va mot so dieu kien moi truong.
- Install_Controller_Task.bat: cai Controller vao Task Scheduler de tu chay.
- Start_Controller.bat: khoi dong Controller.
- Start_Controller_Hidden.bat: khoi dong Controller an cua so.
- Stop_Controller.bat: dung Controller.
- Commands/commands.json: danh sach lenh chuan.
- Logs/: controller.log va log hoat dong.
- State/: PID, scheduler state, welcome flag va trang thai noi bo.
- Data/node_history.json: du lieu lich su monitor neu Smart Monitor da tao.

CAI DAT:
1. Giai nen bo app vao thu muc co quyen ghi.
2. Mo Setup_Config.bat hoac chay Setup_Config.ps1.
3. Nhap Telegram Bot Token, Chat ID va Gemini API Key.
4. Kiem tra Check_Installation.bat.
5. Chay Start_Controller.bat.
6. Gui /help, /status va /monitor de kiem tra.
7. Neu muon tu dong khi Windows khoi dong, dung Install_Controller_Task.bat.
8. PiCheck/Pi Desktop can san sang de Smart Monitor doc man hinh neu monitor yeu cau.

LENH CHUAN:
/help = menu huong dan
/status = doc trang thai gan nhat tu node_history.json
/monitor = chay Smart Monitor ngay
/monitors = alias /monitor
/report = bao cao 24 gio tu history
/diagnostic = chan doan
/cleanram = don RAM
/screenshot = chup man hinh va gui anh
/logs = doc log gan day
/docker = kiem tra Docker
/disk = kiem tra o C:
/scheduler = xem scheduler
/maintenance = yeu cau xac nhan bao tri; sau do /confirm
/confirm = xac nhan maintenance dang cho
/reset = yeu cau xac nhan reset mang + Node; sau do /confirmreset
/confirmreset = xac nhan reset dang cho
/cancel = huy thao tac dang cho
/ask <cau hoi> = hoi Hermes AI truc tiep
/donate = gui QR ung ho neu chuc nang duoc cau hinh

VI DU NGON NGU TU NHIEN:
- "May toi the nao roi?" -> STATUS
- "Tien hanh bao cao nhanh" -> MONITOR
- "May ngay nay Pi Node toi on khong?" -> REPORT
- "Cho toi xem Docker" -> DOCKER
- "O C con bao nhieu?" -> DISK
- "Chup anh man hinh" -> SCREENSHOT
- "Don RAM giup toi" -> CLEANRAM
- "Chan doan Node" -> DIAGNOSTIC
- "Bao tri may" -> MAINTENANCE_CONFIRM
- "Reset Node" -> RESET_CONFIRM
- "Scheduler dang chay khong?" -> SCHEDULER
- "Xem log" -> LOGS
- "Pi Node Controller nay dung de lam gi?" -> KNOWLEDGE

NGUYEN TAC AI:
- Khong doan trang thai may. Cau hoi ve trang thai thuc te phai goi module/controller de lay du lieu.
- Khong tu y reset, maintenance, xoa du lieu hoac thao tac nguy hiem. Chi tao yeu cau xac nhan dung quy trinh cua Controller.
- Neu khong phai lenh he thong va la cau hoi kien thuc, tra loi ngan gon dua tren Knowledge Base.
- Neu nguoi dung hoi ve mot ket qua thuc te ma controller khong co du lieu, noi ro khong co du lieu thay vi bịa.
- Khong tiet lo Bot Token, Chat ID, Gemini API Key, secret, duong dan nhay cam.
- Uu tien tieng Viet, ngan gon, ro rang, co emoji vua phai.
'@

function Invoke-GeminiAPI {
    param([Parameter(Mandatory)][string]$Prompt)
    if (-not $GeminiNaturalLanguageEnabled) { return $null }
    if ([string]::IsNullOrWhiteSpace($GeminiApiKey)) { return $null }
    foreach ($model in @($GeminiModels)) {
        try {
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/$model`:generateContent?key=$GeminiApiKey"
            $body = @{ contents = @(@{ parts = @(@{ text = $Prompt }) }); generationConfig = @{ temperature = 0.1; maxOutputTokens = 700 } } | ConvertTo-Json -Depth 8
            $r = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $RequestTimeout
            $txt = [string]$r.candidates[0].content.parts[0].text
            if (-not [string]::IsNullOrWhiteSpace($txt)) { return $txt.Trim() }
        } catch {
            Write-Log "Gemini model $model loi: $($_.Exception.Message)"
        }
    }
    return $null
}

function Get-RequestedPeriodDays {
    param([Parameter(Mandatory)][string]$Question)
    $q = $Question.ToLowerInvariant()
    if ($q -match '(hôm nay|hom nay|today|24h|24 giờ|24 gio|một ngày|mot ngay)') { return 1 }
    if ($q -match '(hôm qua|hom qua|yesterday)') { return 1 }
    if ($q -match '(tuần này|tuan nay|7 ngày|7 ngay|một tuần|mot tuan|1 tuần|1 tuan)') { return 7 }
    if ($q -match '(2 tuần|2 tuan|14 ngày|14 ngay)') { return 14 }
    if ($q -match '(tháng này|thang nay|30 ngày|30 ngay|một tháng|mot thang|1 tháng|1 thang)') { return 30 }
    if ($q -match '(3 tháng|3 thang|90 ngày|90 ngay|quý này|quy nay)') { return 90 }
    if ($q -match '(6 tháng|6 thang|180 ngày|180 ngay)') { return 180 }
    if ($q -match '(năm này|nam nay|1 năm|1 nam|365 ngày|365 ngay)') { return 365 }
    # "30 ngày vừa qua", "7 ngày gần đây", "qua 14 ngày"...
    $m = [regex]::Match($q, '(\d+)\s*(ngày|ngay|day|days|tuần|tuan|week|weeks|tháng|thang|month|months)\s*(vừa qua|vua qua|gần đây|gan day|qua|trước|truoc)?')
    if ($m.Success) {
        $n=[int]$m.Groups[1].Value; $u=$m.Groups[2].Value
        if ($u -match 'tuan|week') { return $n*7 }
        if ($u -match 'thang|month') { return $n*30 }
        return $n
    }
    $m2 = [regex]::Match($q, '(?:trong|khoảng|qua|gần đây|gan day|last|recent|suốt|suot|vừa qua|vua qua)\s*(\d+)\s*(ngày|ngay|day|days|tuần|tuan|week|weeks|tháng|thang|month|months)')
    if ($m2.Success) {
        $n=[int]$m2.Groups[1].Value; $u=$m2.Groups[2].Value
        if ($u -match 'tuan|week') { return $n*7 }
        if ($u -match 'thang|month') { return $n*30 }
        return $n
    }
    # Câu hỏi chỉ số (nóng/nhiệt/RAM/CPU) không nêu khoảng thời gian → mặc định 7 ngày
    if ($q -match 'nóng|nong|nhiệt|nhiet|temperature|temp|ram|cpu|bộ nhớ|bo nho') { return 7 }
    return 1
}

function Get-HistoryContextForAI {
    param([int]$Days = 7, [int]$MaxRecords = 120)
    $h=@(Get-NodeHistory)
    if($h.Count -eq 0){ return 'KHONG CO NODE_HISTORY.' }
    $cut=(Get-Date).AddDays(-[math]::Max(1,$Days))
    $sel=@($h | Where-Object { try {[datetime]$_.time -ge $cut} catch {$false} } | Select-Object -Last $MaxRecords)
    if($sel.Count -eq 0){ return 'KHONG CO DU LIEU TRONG KHOANG THOI GIAN DUOC YEU CAU.' }
    try { return ($sel | ConvertTo-Json -Depth 5 -Compress) } catch { return 'KHONG THE DOC HISTORY.' }
}


function Get-HistoricalEvidenceForAI {
    param([int]$Days = 30, [int]$MaxRecords = 500)

    $rows = @(Get-HistoryRows -Days $Days)
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{
            period_days=$Days
            records=0
            message='KHONG CO DU LIEU TRONG KHOANG THOI GIAN'
        } | ConvertTo-Json -Depth 8 -Compress
    }

    $problems = @($rows | Where-Object { try { [int]$_.problems -gt 0 } catch { $false } })
    $syncBad = @($rows | Where-Object { [string]$_.sync -notin @('Dong bo tot','SYNCED','Synced','') })
    $dockerBad = @($rows | Where-Object { [string]$_.docker -notin @('RUNNING','Running','OK','') })
    $portBad = @($rows | Where-Object { [string]$_.port -notin @('OPEN','Open','OK','') })

    $temps=@(Get-StatNumberArray -Rows $rows -Property 'temp')
    $rams=@(Get-StatNumberArray -Rows $rows -Property 'ram_sys')
    $cpus=@(Get-StatNumberArray -Rows $rows -Property 'cpu_sys')

    function _range([array]$v) {
        if(!$v.Count){ return $null }
        return [pscustomobject]@{
            min=[math]::Round(($v|Measure-Object -Minimum).Minimum,1)
            max=[math]::Round(($v|Measure-Object -Maximum).Maximum,1)
            avg=[math]::Round(($v|Measure-Object -Average).Average,1)
            median=(Get-StatMedian $v)
        }
    }

    # Keep only meaningful incident records in the raw evidence. This lets Gemini
    # reason over actual events without flooding the prompt with every normal sample.
    $incidents = @($rows | Where-Object {
        $p=$false
        try {$p=([int]$_.problems -gt 0)} catch {}
        $s=[string]$_.sync
        $d=[string]$_.docker
        $po=[string]$_.port
        $p -or ($s -and $s -notin @('Dong bo tot','SYNCED','Synced')) -or
        ($d -and $d -notin @('RUNNING','Running','OK')) -or
        ($po -and $po -notin @('OPEN','Open','OK'))
    } | Select-Object -Last 120)

    # Detect high resource samples for historical questions.
    $resourceEvents=@($rows | Where-Object {
        $hot=$false;$ramHigh=$false;$cpuHigh=$false
        try {$hot=((To-Num $_.temp) -ge 70)} catch {}
        try {$ramHigh=((To-Num $_.ram_sys) -ge 85)} catch {}
        try {$cpuHigh=((To-Num $_.cpu_sys) -ge 85)} catch {}
        $hot -or $ramHigh -or $cpuHigh
    } | Select-Object -Last 120)

    $sample=@($rows | Select-Object -Last ([math]::Min($MaxRecords,$rows.Count)))

    [pscustomobject]@{
        period_days=$Days
        records=$rows.Count
        first_time=$rows[0].time
        last_time=$rows[-1].time
        incidents=$problems.Count
        sync_abnormal=$syncBad.Count
        docker_abnormal=$dockerBad.Count
        port_abnormal=$portBad.Count
        temperature=(_range $temps)
        ram=(_range $rams)
        cpu=(_range $cpus)
        incident_samples=$incidents | ForEach-Object { $_ } | Select-Object -First 120
        abnormal_records=$incidents
        resource_events=$resourceEvents
        recent_samples=$sample
    } | ConvertTo-Json -Depth 10 -Compress
}

function Invoke-HistoricalAIAnalysis {
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][int]$Days
    )

    $evidence = Get-HistoricalEvidenceForAI -Days $Days -MaxRecords 500

    $prompt=@"
BAN LA CHUYEN GIA PHAN TICH LICH SU PI NODE CHO TELEGRAM.

CAU HOI NGUOI DUNG:
$Question

NGU CANH TRO CHUYEN GAN DAY:
$(Get-ChatHistoryContext -Turns 6)

KHOANG THOI GIAN:
$Days ngay

DU LIEU THUC TE TU node_history.json:
$evidence

NHIEM VU:
Phân tích dữ liệu thực tế để trả lời đúng câu hỏi. Đây không phải câu hỏi STATUS hiện tại.
Nếu người dùng hỏi "có sự cố gì không", phải tìm sự cố trong toàn bộ khoảng thời gian, không chỉ nhìn bản ghi mới nhất.

Hãy kiểm tra:
1. Có bao nhiêu bản ghi và khoảng thời gian thực tế có dữ liệu.
2. Có bao nhiêu lần problems > 0.
3. Có bất thường về sync, Docker hoặc port không.
4. Nhiệt độ: thấp nhất, cao nhất, trung bình, mức phổ biến và các thời điểm đáng chú ý nếu dữ liệu có.
5. RAM và CPU: min, max, trung bình và các thời điểm cao bất thường nếu dữ liệu có.
6. Nếu có sự cố lặp lại, hãy nhận diện xu hướng.
7. Phân biệt sự cố thực sự với một vài mẫu đo bất thường đơn lẻ.
8. Nếu không có đủ dữ liệu để kết luận, nói rõ thiếu dữ liệu.
9. Không được coi bản ghi hiện tại là đại diện cho cả giai đoạn.

TRẢ LỜI TELEGRAM:
🔎 Kết luận
Nói rõ trong $Days ngày qua có hay không có dấu hiệu sự cố.

📅 Dữ liệu đã phân tích
Nêu số mẫu và khoảng thời gian thực tế.

🔴 Sự cố
Nếu có, liệt kê lỗi/sự cố, số lần và mức độ ảnh hưởng.

🟡 Bất thường
Nêu các chỉ số cao hoặc bất thường nhưng chưa đủ để gọi là lỗi.

📊 Xu hướng
Nêu những thay đổi hoặc mẫu lặp lại đáng chú ý.

🟢 Điểm tốt
Nêu những thành phần ổn định nếu dữ liệu chứng minh được.

💡 Đề xuất
Đưa 1 đến 3 gợi ý phù hợp nhất. Không nói đã sửa nếu chưa có thao tác sửa.

QUY TẮC:
- Không trả JSON.
- Không dùng bảng Markdown.
- Không dùng dòng trang trí ====, ----, **** hoặc ━━━━━.
- Không trả về một báo cáo STATUS hiện tại.
- Không chỉ nói "ổn định" dựa vào bản ghi mới nhất.
- Không bịa số liệu.
- Không biến "không có sự cố" thành "không có dữ liệu".
- Nếu không có sự cố trong dữ liệu, nói rõ "Không phát hiện sự cố được ghi nhận trong dữ liệu đã có".
- Dùng tiếng Việt, câu ngắn, xuống dòng dễ đọc.
- Icon vừa phải.
"@

    $answer=Invoke-GeminiAPI -Prompt $prompt
    if([string]::IsNullOrWhiteSpace($answer)){ return $null }
    return $answer.Trim()
}

function Invoke-GeminiNaturalLanguage {
    param([Parameter(Mandatory)][string]$Question)
    $periodDays=Get-RequestedPeriodDays -Question $Question
    $historyContext=Get-HistoryContextForAI -Days $periodDays
    $chatCtx=Get-ChatHistoryContext -Turns $CHAT_HISTORY_CONTEXT_TURNS
    $prompt = @"
BAN LA AI ROUTER CUA PI NODE TELEGRAM CONTROLLER PRO.
NHIEM VU: Hieu y dinh tin nhan tieng Viet tu nhien va chon intent.
INTENT: STATUS, MONITOR, REPORT, STATISTICS, ADVICE, DOCKER, DISK, SCREENSHOT, LOGS, SCHEDULER, DIAGNOSTIC, CLEANRAM, MAINTENANCE_CONFIRM, RESET_CONFIRM, HELP, DONATE, ASK_HERMES, KNOWLEDGE, UNKNOWN.

QUY TAC:
- may toi the nao/tinh trang hien tai (KHONG hoi nong/nhiet/RAM/CPU theo thoi gian) => STATUS.
- kiem tra/chay monitor/bao cao nhanh => MONITOR.
- cau hoi lich su/bao cao tong quat => REPORT. Cac cau nhu '30 ngay qua may toi co su co gi khong?' phai la REPORT, khong duoc chon STATUS.
- cau hoi nham vao mot chi so cu the (nhiet do, nong, RAM, CPU...) ke ca khi khong noi ro thoi gian => STATISTICS.
  Vi du BAT BUOC la STATISTICS:
  - "Thang nay may toi chay co nong khong?"
  - "30 ngay vua qua may toi chay co nong khong?"
  - "May toi chay co nong khong?"
  - "Tuan nay nhiet do the nao?"
  - "7 ngay qua RAM co cao khong?"
- Cau hoi ve 'su co/loi/bat thuong' trong mot khoang thoi gian ma khong chi ro chi so => REPORT de AI phan tich tong the.
- Docker/container => DOCKER; o C/o dia/dung luong => DISK; chup anh/man hinh => SCREENSHOT.
- don RAM => CLEANRAM; bao tri => MAINTENANCE_CONFIRM; reset => RESET_CONFIRM.
- hoi cach cai dat, script nao lam gi, app dung de lam gi => KNOWLEDGE.
- khong duoc dung KNOWLEDGE cho cau hoi can du lieu may thuc te.
- cau hoi tu van nang cap / nen mua gi / uu tien RAM hay CPU hay o cung / phan cung nao can nang cap => ADVICE.
  Vi du BAT BUOC la ADVICE:
  - "Toi nen nang cap gi truoc: ram, cpu, hay o cung?"
  - "May toi nen nang cap RAM khong?"
  - "Nen them RAM hay doi o SSD?"
- KHONG BAO GIO tra STATUS cho cau hoi ve nong/nhiet do/RAM/CPU theo thoi gian.
- KHONG BAO GIO tra STATISTICS don le khi cau hoi la tu van nang cap nhieu thanh phan.
- Neu REPORT hoac STATISTICS, periodDays=$periodDays. Neu nguoi dung noi tuan nay=7, thang nay=30, nam nay=365. Neu khong noi thoi gian nhung hoi nong/nhiet => 7 ngay.

KNOWLEDGE BASE:
$script:GeminiKnowledge

DU LIEU HISTORY THUC TE CUA NODE (chi dung de phan tich khi cau hoi can lich su):
$historyContext

LICH SU TRO CHUYEN GAN DAY (de hieu ngu canh, khong duoc biа):
$chatCtx

TIN NHAN HIEN TAI:
$Question

Neu intent thuc thi: dong dau tien chi duoc la mot intent.
Neu KNOWLEDGE: tra ve KNOWLEDGE roi cau tra loi tieng Viet ngan gon.
Neu cau hoi la follow-up (vi du "con RAM thi sao?", "the con o cung?"), hay dung lich su de hieu dung y.
"@
    $out = Invoke-GeminiAPI -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    return $out.Trim()
}

function Get-NaturalLanguageFallbackIntent {
    param([Parameter(Mandatory)][string]$Question)
    $q = $Question.ToLowerInvariant().Trim()
    # Deterministic fallback: natural language still works when Gemini is unavailable,
    # returns malformed output, or the model is temporarily rate-limited.
    if ($q -match '^(help|trợ giúp|huong dan|hướng dẫn)$' -or $q -match 'cach dung|cách dùng|lenh nao|lệnh nào') { return 'HELP' }
    if ($q -match 'chup.*(anh|hinh|màn hình|man hinh)|screenshot|ảnh màn hình|hinh man hinh') { return 'SCREENSHOT' }
    if ($q -match 'don.*ram|dọn.*ram|giai phong ram|giải phóng ram|ram.*day|ram.*cao|ram.*nang') { return 'CLEANRAM' }
    if ($q -match 'bao tri|bảo trì|maintenance|toi uu may|tối ưu máy') { return 'MAINTENANCE_CONFIRM' }
    if ($q -match 'reset.*(node|mang|mạng)|khoi phuc mang|khôi phục mạng|dat lai node|đặt lại node') { return 'RESET_CONFIRM' }
    if ($q -match 'docker|container') { return 'DOCKER' }
    if ($q -match 'o c|ổ c|o dia|ổ đĩa|dung luong|dung lượng|disk|free space') { return 'DISK' }
    if ($q -match 'scheduler|task scheduler|lich chay|lịch chạy|tu dong khoi dong|tự động khởi động|tắt lịch|tat lich|bật lịch|bat lich|chu kỳ quét|chu ky quet|interval') { return 'SCHEDULER' }
    if ($q -match 'log|nhat ky|nhật ký') { return 'LOGS' }
    if ($q -match 'chan doan|chẩn đoán|tai sao.*loi|tại sao.*lỗi|nguyen nhan|nguyên nhân') { return 'DIAGNOSTIC' }

    # Tư vấn nâng cấp phần cứng => ADVICE
    if ($q -match 'nâng cấp|nang cap|nên mua|nen mua|ưu tiên.*(?:ram|cpu|ổ|o cứng|o cung|ssd)|nên thêm|nen them|upgrade|phần cứng|phan cung') { return 'ADVICE' }

    # Metric + (time window OR heat/load question) => STATISTICS (order-independent)
    $hasMetric = $q -match 'nhiệt|nhiet|nóng|nong|temperature|temp|nhiet do|nhiệt độ|ram|bộ nhớ|bo nho|cpu|processor'
    $hasTimeWindow = $q -match 'tháng|thang|tuần|tuan|ngày|ngay|hôm qua|hom qua|mấy ngày|may ngay|vừa qua|vua qua|gần đây|gan day|lịch sử|lich su|30\s*ngày|7\s*ngày|14\s*ngày'
    $isHeatQuestion = $q -match 'có nóng|co nong|bị nóng|bi nong|nóng không|nong khong|nóng quá|nong qua|nhiệt độ|nhiet do'
    $isLoadQuestion = $q -match 'ram.*(cao|thế nào|the nao|sao)|cpu.*(cao|thế nào|the nao|sao)|máy.*(nặng|nang|nóng|nong)'
    $isAdvice = $q -match 'nâng cấp|nang cap|nên mua|nen mua|ưu tiên|uu tien|upgrade'

    if ($hasMetric -and ($hasTimeWindow -or $isHeatQuestion -or $isLoadQuestion) -and -not $isAdvice) { return 'STATISTICS' }
    if ($isHeatQuestion -and -not $isAdvice) { return 'STATISTICS' }

    if ($q -match 'may ngay|mấy ngày|hom qua|hôm qua|tuan nay|tuần này|thang nay|tháng này|lich su|lịch sử|on khong|ổn không|bao cao|báo cáo|thong ke|thống kê|vừa qua|vua qua') { return 'REPORT' }
    if ($q -match 'monitor|kiem tra ngay|kiểm tra ngay|kiem tra node|kiểm tra node|tien hanh|tiến hành|kiem tra nhanh|kiểm tra nhanh') { return 'MONITOR' }

    # STATUS chỉ khi hỏi tình trạng hiện tại, không có từ khóa lịch sử/nhiệt
    if ($q -match 'may toi|máy tôi|tinh trang|tình trạng|node.*the nao|node.*thế nào|node.*sao|dang chay|đang chạy') {
        if (-not $hasMetric -and -not $hasTimeWindow -and -not $isHeatQuestion) { return 'STATUS' }
    }
    if ($q -match 'ung dung nay|ứng dụng này|app nay|app này|controller nay|controller này|cai dat|cài đặt|file nao|file nào|script nao|script nào|lam gi|làm gì|su dung|sử dụng|chuc nang|chức năng') { return 'KNOWLEDGE' }
    if ($q -match 'hermes|phan tich sau|phân tích sâu|hoi ai|hỏi ai') { return 'ASK_HERMES' }
    return 'UNKNOWN'
}

function Get-MetricSummary {
    param([int]$Days = 30, [string]$Property)
    $rows = @(Get-HistoryRows -Days $Days)
    $vals = @(Get-StatNumberArray -Rows $rows -Property $Property)
    if ($vals.Count -eq 0) {
        return [pscustomobject]@{ samples=0; min=$null; max=$null; avg=$null; median=$null }
    }
    return [pscustomobject]@{
        samples = $vals.Count
        min = [math]::Round(($vals | Measure-Object -Minimum).Minimum, 1)
        max = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1)
        avg = Get-StatAverage $vals
        median = Get-StatMedian $vals
    }
}

function Get-HardwareAdviceEvidence {
    param([int]$Days = 30)

    $ram = Get-MetricSummary -Days $Days -Property 'ram_sys'
    $cpu = Get-MetricSummary -Days $Days -Property 'cpu_sys'
    $temp = Get-MetricSummary -Days $Days -Property 'temp'

    $diskTotal = $null; $diskFree = $null; $diskUsedPct = $null
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $diskTotal = [math]::Round($d.Size/1GB, 1)
        $diskFree = [math]::Round($d.FreeSpace/1GB, 1)
        $diskUsedPct = [math]::Round(100 * (1 - $d.FreeSpace / $d.Size), 1)
    } catch {}

    $statusNow = $null
    try {
        $h = @(Get-NodeHistory)
        if ($h.Count -gt 0) { $statusNow = $h[-1] }
    } catch {}

    $physRamGB = $null
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $physRamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    } catch {}

    $cpuName = $null; $cpuCores = $null
    try {
        $proc = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cpuName = [string]$proc.Name
        $cpuCores = [int]$proc.NumberOfLogicalProcessors
    } catch {}

    return [pscustomobject]@{
        period_days = $Days
        ram_history = $ram
        cpu_history = $cpu
        temp_history = $temp
        disk_c_total_gb = $diskTotal
        disk_c_free_gb = $diskFree
        disk_c_used_pct = $diskUsedPct
        physical_ram_gb = $physRamGB
        cpu_name = $cpuName
        cpu_logical_cores = $cpuCores
        latest_status = $statusNow
    } | ConvertTo-Json -Depth 8 -Compress
}

function Invoke-HardwareAdvice {
    param(
        [Parameter(Mandatory)][string]$Question,
        [int]$Days = 30
    )

    $evidence = Get-HardwareAdviceEvidence -Days $Days
    $period = Get-StatPeriodLabel -Days $Days

    $prompt = @"
Bạn là chuyên gia tư vấn nâng cấp phần cứng cho máy chạy Pi Node (Windows + Docker).

CÂU HỎI NGƯỜI DÙNG:
$Question

NGỮ CẢNH TRÒ CHUYỆN GẦN ĐÂY:
$(Get-ChatHistoryContext -Turns 6)

KHOẢNG DỮ LIỆU LỊCH SỬ: $Days ngày ($period)

BẰNG CHỨNG THỰC TẾ TỪ MÁY:
$evidence

NHIỆM VỤ:
Dựa trên dữ liệu thực tế, tư vấn nên nâng cấp gì TRƯỚC (RAM / CPU / ổ cứng / tản nhiệt / không cần nâng cấp).
Không được bịa số liệu. Không trả STATUS snapshot đơn thuần.

CÁCH ĐÁNH GIÁ:
1. RAM: nếu trung bình thường xuyên >75% hoặc đỉnh >90% → ưu tiên RAM.
2. CPU: nếu trung bình >70% hoặc đỉnh kéo dài >90% → cân nhắc CPU (hoặc tối ưu phần mềm trước).
3. Ổ C: nếu còn trống <15% hoặc <50GB → ưu tiên ổ cứng / dọn dẹp.
4. Nhiệt độ: nếu thường xuyên ≥70°C hoặc đỉnh ≥80°C → ưu tiên tản nhiệt / vệ sinh trước khi nâng cấp mạnh.
5. Nếu tất cả chỉ số ổn → nói rõ không cần nâng cấp ngay, gợi ý tối ưu phần mềm nếu hữu ích.

TRẢ LỜI TELEGRAM (tiếng Việt, ngắn, rõ):
🔎 Kết luận
Nêu rõ nên ưu tiên nâng cấp gì trước (hoặc chưa cần).

📊 Bằng chứng
Tóm tắt ngắn RAM / CPU / Ổ đĩa / Nhiệt trong khoảng thời gian (dùng số liệu từ evidence).

💡 Lý do
1–3 lý do ngắn dựa trên dữ liệu.

🛠️ Gợi ý tiếp theo
1–3 bước thực tế (mua thêm bao nhiêu, dọn ổ, kiểm tra tản nhiệt...).

QUY TẮC:
- Không dùng bảng Markdown, không ==== / ---- / ━━━.
- Không bịa thông số phần cứng nếu evidence thiếu.
- Icon vừa phải, dễ đọc trên Telegram.
- Nếu thiếu dữ liệu history, nói rõ và dựa vào số liệu hiện có.
"@

    $answer = Invoke-GeminiAPI -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($answer)) {
        # Fallback deterministic advice without Gemini
        $ev = $evidence | ConvertFrom-Json
        $lines = @()
        $lines += "🔎 TƯ VẤN NÂNG CẤP · $period"
        $lines += ""
        $ramAvg = $ev.ram_history.avg
        $cpuAvg = $ev.cpu_history.avg
        $tempMax = $ev.temp_history.max
        $diskFree = $ev.disk_c_free_gb
        $diskUsed = $ev.disk_c_used_pct

        $priority = @()
        if ($null -ne $diskUsed -and ($diskUsed -ge 85 -or ($null -ne $diskFree -and $diskFree -lt 50))) {
            $priority += "Ổ cứng (C: còn ít dung lượng)"
        }
        if ($null -ne $ramAvg -and $ramAvg -ge 75) {
            $priority += "RAM (trung bình cao)"
        }
        if ($null -ne $tempMax -and $tempMax -ge 80) {
            $priority += "Tản nhiệt (đỉnh nhiệt cao)"
        }
        if ($null -ne $cpuAvg -and $cpuAvg -ge 70) {
            $priority += "CPU (tải trung bình cao)"
        }

        if ($priority.Count -eq 0) {
            $lines += "🔎 Kết luận: Hiện tại chưa thấy áp lực rõ ràng cần nâng cấp ngay."
        } else {
            $lines += "🔎 Kết luận: Nên ưu tiên → $($priority[0])"
        }
        $lines += ""
        $lines += "📊 Bằng chứng ($period):"
        if ($null -ne $ramAvg) { $lines += "• RAM TB $($ramAvg)% (min $($ev.ram_history.min) · max $($ev.ram_history.max))" }
        if ($null -ne $cpuAvg) { $lines += "• CPU TB $($cpuAvg)% (min $($ev.cpu_history.min) · max $($ev.cpu_history.max))" }
        if ($null -ne $tempMax) { $lines += "• Nhiệt max $($tempMax)°C · TB $($ev.temp_history.avg)°C" }
        if ($null -ne $diskFree) { $lines += "• Ổ C: còn $diskFree GB (đã dùng $diskUsed%)" }
        if ($ev.physical_ram_gb) { $lines += "• RAM vật lý: $($ev.physical_ram_gb) GB" }
        $lines += ""
        $lines += "💡 Gợi ý: Theo dõi thêm 7–14 ngày. Nếu RAM/CPU/ổ đĩa vượt ngưỡng trên, hãy nâng cấp đúng thành phần được ưu tiên."
        return ($lines -join "`n")
    }
    return $answer.Trim()
}

function Test-ReplyMatchesQuestion {
    param([string]$Question, [string]$Answer, [string]$Intent)
    if ([string]::IsNullOrWhiteSpace($Answer) -or [string]::IsNullOrWhiteSpace($Question)) { return $true }
    $q = $Question.ToLowerInvariant()
    $a = $Answer.ToLowerInvariant()
    # Báo cáo / lịch sử mà trả về toàn ổ đĩa → lệch
    if ($Intent -eq 'REPORT' -or $q -match 'báo cáo|bao cao|ngày qua|ngay qua') {
        if ($a -match 'o c:|ổ c:|tong:.*gb|trong:.*gb' -and $a -notmatch 'đồng bộ|dong bo|nhiệt|nhiet|ram|cpu|node|báo cáo|bao cao') {
            return $false
        }
    }
    # Hỏi nóng/nhiệt mà không nhắc nhiệt
    if ($Intent -eq 'STATISTICS' -and $q -match 'nóng|nong|nhiệt|nhiet') {
        if ($a -notmatch 'nhiệt|nhiet|°c|do c|nóng|nong') { return $false }
    }
    # Hỏi nâng cấp mà chỉ 1 chỉ số RAM không có kết luận ưu tiên
    if ($Intent -eq 'ADVICE' -and $q -match 'nâng cấp|nang cap') {
        if ($a -match 'phân tích ram' -and $a -notmatch 'ưu tiên|ket luan|kết luận|nên') { return $false }
    }
    return $true
}

function Invoke-NaturalLanguageMessage {
    param([string]$Question)
    if ([string]::IsNullOrWhiteSpace($Question)) { Send-Text (Show-Help); return }
    # Fast visual acknowledgement prevents the user from thinking Telegram/Controller is frozen.
    Send-Text "📩 Đã nhận yêu cầu`n`n📝 $Question`n`n🤖 Tôi đang xác định cách kiểm tra phù hợp...`n⏳ Vui lòng chờ kết quả."

    # First ask Gemini. If its answer is not an exact supported intent, use the local
    # deterministic resolver so the user never falls back to "không xác định" for
    # common phrases.
    $ai = Invoke-GeminiNaturalLanguage -Question $Question
    $first = ''
    $answer = $null
    if (-not [string]::IsNullOrWhiteSpace($ai)) {
        $lines = $ai -split "`r?`n",2
        $first = $lines[0].Trim().ToUpperInvariant()
        if ($first -eq 'KNOWLEDGE') {
            $answer = if ($lines.Count -gt 1) { $lines[1].Trim() } else { '' }
        }
    }

    $allowed = @('STATUS','MONITOR','REPORT','STATISTICS','ADVICE','DOCKER','DISK','SCREENSHOT','LOGS','SCHEDULER','DIAGNOSTIC','CLEANRAM','MAINTENANCE_CONFIRM','RESET_CONFIRM','HELP','DONATE','ASK_HERMES','KNOWLEDGE')
    if ($first -notin $allowed) {
        $first = Get-NaturalLanguageFallbackIntent -Question $Question
    }

    # Deterministic semantic guard: historical questions must not fall back to STATUS.
    # Broad historical questions (including "có sự cố gì không") are sent to Gemini
    # with the actual history evidence for analysis.
    $qNorm=$Question.ToLowerInvariant()
    $hasHistoryWindow=($qNorm -match 'tuần|tuan|tháng|thang|ngày|ngay|hôm qua|hom qua|lịch sử|lich su|mấy ngày|may ngay|gần đây|gan day|vừa qua|vua qua|qua\s+\d+|30\s*ngày|7\s*ngày|14\s*ngày|90\s*ngày|180\s*ngày|365\s*ngày')
    $hasMetric=($qNorm -match 'nhiệt|nhiet|nóng|nong|temperature|temp|nhiệt độ|nhiet do|ram|bộ nhớ|bo nho|cpu')
    $isHeatQuestion=($qNorm -match 'có nóng|co nong|bị nóng|bi nong|nóng không|nong khong|nóng quá|nong qua')
    $isAdviceQuestion=($qNorm -match 'nâng cấp|nang cap|nên mua|nen mua|ưu tiên|uu tien|nên thêm|nen them|nên đổi|nen doi|upgrade|phần cứng|phan cung|nên nâng|nen nang')
    $broadHistorical=($qNorm -match 'có.*(sự cố|su co|lỗi|loi|bất thường|bat thuong)|xảy ra.*(lỗi|loi|sự cố|su co)|có vấn đề|co van de|ổn không|on khong|hoạt động.*(thế nào|the nao)')
    $isReportQuestion=($qNorm -match 'báo cáo|bao cao|report|thống kê tổng|thong ke tong')
    # Tư vấn nâng cấp nhiều thành phần → ADVICE (không ép STATISTICS)
    if($isAdviceQuestion) { $first='ADVICE' }
    # Báo cáo / lịch sử tổng quát → REPORT (kể cả Gemini trả nhầm DISK/STATUS)
    elseif($isReportQuestion -or ($hasHistoryWindow -and $broadHistorical)) { $first='REPORT' }
    elseif($hasHistoryWindow -and $first -in @('STATUS','UNKNOWN','REPORT','DISK','DOCKER')) { $first='REPORT' }
    # Chỉ ép STATISTICS khi hỏi chỉ số thuần (nóng/nhiệt/RAM/CPU), không phải tư vấn nâng cấp
    elseif(($hasMetric -or $isHeatQuestion) -and -not $isAdviceQuestion -and -not $isReportQuestion) { $first='STATISTICS' }

    Write-Log "NaturalLanguage intent=$first question=$Question"
    # User turn đã được ghi ở Handle-Message; cập nhật intent chi tiết sau khi phân loại
    $script:LastChatIntent = $first
    $script:LastChatSource = 'natural'
    $script:RememberReply = $true
    try {
        # Cập nhật intent của tin user gần nhất (nếu có) để insights chính xác hơn
        $recs = @(Get-ChatHistory)
        if ($recs.Count -gt 0) {
            $last = $recs[-1]
            if ($last.role -eq 'user') {
                $last.intent = $first
                $recs[-1] = $last
                Save-ChatHistory -Records $recs
            }
        }
    } catch {}
    if ($first -eq 'KNOWLEDGE') {
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = "Tôi có thể hướng dẫn cài đặt, giải thích từng script, chức năng Controller, Monitor, CleanRAM, Maintenance, Diagnostic, Reset, Docker/WSL, Telegram, Gemini và Hermes. Bạn muốn biết phần nào?"
        }
        Send-Text "🤖 AI APP GUIDE`n`n$answer"
        return
    }

    switch ($first) {
        'STATUS' { Send-Text (Get-NodeStatus); break }
        'MONITOR' { Invoke-SmartMonitor; break }
        'REPORT' {
            $days=Get-RequestedPeriodDays -Question $Question
            $analysis=Invoke-HistoricalAIAnalysis -Question $Question -Days $days
            if([string]::IsNullOrWhiteSpace($analysis)){
                $analysis = Get-NodeReport -Days $days
            }
            if($analysis.Length -gt 3800){$analysis=$analysis.Substring(0,3770)+"`n`n… Nội dung đã được rút gọn."}
            if (-not (Test-ReplyMatchesQuestion -Question $Question -Answer $analysis -Intent 'REPORT')) {
                Write-Log "QA: REPORT answer mismatched, fallback Get-NodeReport days=$days"
                $analysis = Get-NodeReport -Days $days
            }
            Send-Text $analysis
            break
        }
        'STATISTICS' {
            $days=Get-RequestedPeriodDays -Question $Question
            $qLow=$Question.ToLowerInvariant()
            # Câu hỏi chỉ số cụ thể (nhiệt/RAM/CPU): dùng thống kê động trước (số liệu chính xác)
            if($qLow -match 'nhiệt|nhiet|nóng|nong|temperature|temp|ram|bộ nhớ|bo nho|cpu'){
                $stats = Get-DynamicStatistics -Question $Question -Days $days
                # Bổ sung phân tích AI ngắn nếu có Gemini (không bắt buộc)
                $aiExtra = Invoke-HistoricalAIAnalysis -Question $Question -Days $days
                if(-not [string]::IsNullOrWhiteSpace($aiExtra) -and $aiExtra.Length -lt 1200){
                    # Chỉ lấy phần kết luận ngắn nếu AI trả về dài
                    Send-Text ($stats + "`n`n" + $aiExtra)
                } else {
                    Send-Text $stats
                }
            } else {
                $analysis=Invoke-HistoricalAIAnalysis -Question $Question -Days $days
                if([string]::IsNullOrWhiteSpace($analysis)){
                    Send-Text (Get-DynamicStatistics -Question $Question -Days $days)
                } else {
                    if($analysis.Length -gt 3800){$analysis=$analysis.Substring(0,3770)+"`n`n… Nội dung đã được rút gọn."}
                    Send-Text $analysis
                }
            }
            break
        }
        'ADVICE' {
            $days = Get-RequestedPeriodDays -Question $Question
            if ($days -lt 7) { $days = 30 }  # tư vấn nâng cấp nên nhìn rộng hơn
            $advice = Invoke-HardwareAdvice -Question $Question -Days $days
            if ([string]::IsNullOrWhiteSpace($advice)) {
                Send-Text "⚠️ Chưa đủ dữ liệu để tư vấn nâng cấp. Hãy chạy /monitor vài ngày rồi hỏi lại."
            } else {
                if ($advice.Length -gt 3800) { $advice = $advice.Substring(0,3770) + "`n`n… Nội dung đã được rút gọn." }
                Send-Text $advice
            }
            break
        }
        'DOCKER' { Send-Text (Get-DockerStatus); break }
        'DISK' { Send-Text (Get-DiskStatus); break }
        'SCREENSHOT' { Invoke-Screenshot; break }
        'LOGS' { Send-Text (Get-Logs); break }
        'SCHEDULER' {
            $qLow = $Question.ToLowerInvariant()
            if ($qLow -match '(tắt|tat|off|dừng|dung).*lịch|lịch.*(tắt|tat|off)') {
                Handle-SchedulerCommand -ArgsText 'off'
            } elseif ($qLow -match '(bật|bat|on|mở|mo).*lịch|lịch.*(bật|bat|on)') {
                Handle-SchedulerCommand -ArgsText 'on'
            } elseif ($qLow -match '(?:mỗi|moi|interval|chu kỳ|chu ky)\s*(\d+)\s*(?:phút|phut)?') {
                Handle-SchedulerCommand -ArgsText ("interval " + $Matches[1])
            } else {
                Send-Text (Get-SchedulerStatus)
            }
            break
        }
        'DIAGNOSTIC' { Invoke-DiagnosticAI -UserQuestion $Question; break }
        'CLEANRAM' { Invoke-RegisteredProgram '/cleanram'; break }
        'HELP' { Send-Text (Show-Help); break }
        'DONATE' { Invoke-Donate; break }
        'ASK_HERMES' { Invoke-HermesQuestion -Question $Question; break }
        'MAINTENANCE_CONFIRM' {
            $script:PendingMaintenance = $true; $script:PendingMaintenanceAt = Get-Date
            Send-Text "🛠️ BẢO TRÌ — XÁC NHẬN`n`nAI hiểu yêu cầu của bạn là bảo trì hệ thống.`nGửi /confirm trong $ConfirmTimeout giây để thực hiện.`nGửi /cancel để hủy."
            break
        }
        'RESET_CONFIRM' {
            $script:PendingReset = $true; $script:PendingResetAt = Get-Date
            Send-Text "🛠️ RESET NODE/MẠNG — XÁC NHẬN`n`nAI hiểu yêu cầu là reset mạng + Node.`nGửi /confirmreset trong $ConfirmTimeout giây để thực hiện.`nGửi /cancel để hủy."
            break
        }
        default {
            Send-Text "🤖 Tôi chưa chắc bạn muốn thực hiện thao tác nào.`n`nBạn có thể nói tự nhiên, ví dụ:`n• Máy tôi thế nào rồi?`n• Tiến hành kiểm tra Node`n• Mấy ngày nay Node ổn không?`n• Cho tôi xem Docker`n• Chụp ảnh màn hình`n• Dọn RAM giúp tôi`n• App này dùng để làm gì?`n
Hoặc gửi /help để xem toàn bộ chức năng."
            break
        }
    }
}


function Invoke-DiagnosticAI {
    param([string]$UserQuestion = 'Chẩn đoán máy tôi')

    $dataDir = Join-Path $AppRoot 'Data'
    $scriptPath = Join-Path $dataDir 'Pi_Node_Diagnostic_PRO.ps1'
    $jsonPath = Join-Path $dataDir 'diagnostic_latest.json'

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Send-Text "🔴 Không tìm thấy trình chẩn đoán trong thư mục Data."
        Write-Log "DIAGNOSTIC missing: $scriptPath"
        return
    }

    Send-Text "🔎 Đang kiểm tra máy, Docker, Node, cổng mạng và dữ liệu lịch sử...`n⏳ Vui lòng chờ kết quả."

    try {
        Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue

        $out = Join-Path $env:TEMP "pinode_diagnostic_$PID.out.txt"
        $err = Join-Path $env:TEMP "pinode_diagnostic_$PID.err.txt"

        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"") `
            -WorkingDirectory $dataDir `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $out `
            -RedirectStandardError $err

        $exitCode = if ($null -ne $p) { [int]$p.ExitCode } else { -1 }
        Write-Log "DIAGNOSTIC PRO ExitCode=$exitCode"

        if (-not (Test-Path -LiteralPath $jsonPath)) {
            $errText = ''
            if (Test-Path -LiteralPath $err) {
                $errText = ((Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue).Trim())
            }
            if ($errText.Length -gt 800) { $errText = $errText.Substring(0,800) }
            $msg = "🔴 Chẩn đoán đã chạy nhưng chưa tạo được dữ liệu kết quả."
            if ($errText) { $msg += "`n`nChi tiết kỹ thuật: $errText" }
            Send-Text $msg
            return
        }

        try {
            $diagnostic = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Send-Text "🔴 Đã có file kết quả nhưng Controller không đọc được dữ liệu chẩn đoán."
            Write-Log "DIAGNOSTIC JSON parse error: $($_.Exception.Message)"
            return
        }

        # Build compact evidence for Gemini. JSON remains factual evidence.
        $evidence = $diagnostic | ConvertTo-Json -Depth 12

        $prompt = @"
Bạn là trợ lý chẩn đoán Pi Node qua Telegram.

Câu hỏi gốc của người dùng:
$UserQuestion

Dữ liệu Diagnostic PRO dưới đây là bằng chứng thực tế từ máy. Chỉ được kết luận dựa trên dữ liệu này. Không được bịa số liệu.

$evidence

Hãy trả lời bằng tiếng Việt, rõ ràng và dễ đọc trên Telegram.

YÊU CẦU TRÌNH BÀY:
🔎 Kết luận
Nói ngay máy/Node hiện đang ở mức nào.

Nếu có lỗi:
🔴 Vấn đề cần xử lý
Nêu đúng lỗi đã được Diagnostic xác nhận.

Nếu có cảnh báo:
🟡 Cần theo dõi
Nêu những điểm chưa nghiêm trọng nhưng đáng chú ý.

Nếu có chỉ số quan trọng:
🖥️ Hệ thống
Nêu CPU, RAM, ổ C khi có dữ liệu.

🐳 Docker
Nêu trạng thái Docker và container khi có dữ liệu.

🔌 Kết nối Node
Nêu port nào đang mở hoặc không mở khi có dữ liệu.

📈 Lịch sử
Chỉ nêu lịch sử nếu dữ liệu có sẵn. Không biến dữ liệu toàn lịch sử thành dữ liệu 7 ngày.

💡 Gợi ý
Đưa ra 1 đến 3 bước tiếp theo, theo thứ tự ưu tiên. Đây là gợi ý, không phải thao tác đã thực hiện.

QUY TẮC:
- Không trả JSON.
- Không dùng các dòng trang trí như ====, ----, ****, ━━━━━.
- Không dùng bảng Markdown.
- Không lặp lại câu hỏi của người dùng.
- Không nói "Diagnostic đã sửa" hoặc "đã khắc phục" vì Diagnostic chỉ đọc.
- Nếu chưa đủ dữ liệu để kết luận nguyên nhân, nói rõ "chưa đủ dữ liệu".
- Mỗi ý một dòng hoặc một đoạn ngắn.
- Dùng icon vừa phải.
- Ưu tiên câu trả lời ngắn gọn nhưng có phân tích.
"@

        $ai = Invoke-GeminiAPI -Prompt $prompt

        if ([string]::IsNullOrWhiteSpace($ai)) {
            # Deterministic fallback: user still gets a useful answer if Gemini is unavailable.
            $score = if ($null -ne $diagnostic.score) { $diagnostic.score } else { '?' }
            $status = [string]$diagnostic.result
            $lines = New-Object System.Collections.Generic.List[string]
            [void]$lines.Add("🔎 CHẨN ĐOÁN PI NODE")
            [void]$lines.Add("")
            [void]$lines.Add("📊 Sức khỏe: $score/100")
            if ($status -eq 'HEALTHY') { [void]$lines.Add("🟢 Trạng thái: Hoạt động tốt") }
            elseif ($status -eq 'HEALTHY_WITH_WARNINGS') { [void]$lines.Add("🟡 Trạng thái: Hoạt động nhưng cần theo dõi") }
            else { [void]$lines.Add("🔴 Trạng thái: Cần kiểm tra") }

            if (@($diagnostic.issues).Count -gt 0) {
                [void]$lines.Add("")
                [void]$lines.Add("🔴 Vấn đề")
                foreach ($x in @($diagnostic.issues)) { [void]$lines.Add("• $x") }
            }
            if (@($diagnostic.warnings).Count -gt 0) {
                [void]$lines.Add("")
                [void]$lines.Add("🟡 Cần theo dõi")
                foreach ($x in @($diagnostic.warnings)) { [void]$lines.Add("• $x") }
            }
            [void]$lines.Add("")
            [void]$lines.Add("💡 Gemini hiện không trả lời được. Kết quả trên là dữ liệu Diagnostic trực tiếp.")
            $answer = $lines -join "`n"
        } else {
            $answer = $ai.Trim()
        }

        if ($answer.Length -gt 3800) {
            $answer = $answer.Substring(0,3770) + "`n`n… Nội dung đã được rút gọn."
        }

        Send-Text $answer
    }
    catch {
        Write-Log "DIAGNOSTIC AI exception: $($_.Exception.Message)"
        Send-Text "🔴 Không thể hoàn tất phân tích chẩn đoán.`n`nChi tiết: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RegisteredProgram {
    param([string]$Key, [switch]$Silent)

    try {
        if ($Key -eq '/diagnostic') {
            Invoke-DiagnosticAI -UserQuestion 'Chẩn đoán hệ thống Pi Node'
            return
        }

        if ($null -eq $REGISTERED) {
            Send-Text "🔴 REGISTERED rong - kiem tra Config"
            return
        }
        # OrderedDictionary / Hashtable
        $has = $false
        try { $has = $REGISTERED.ContainsKey($Key) } catch { $has = ($null -ne $REGISTERED[$Key]) }
        if (-not $has) {
            Send-Text "🔴 Lenh chua duoc dang ky: $Key`nKeys: $(($REGISTERED.Keys | ForEach-Object { $_ }) -join ', ')"
            return
        }

        $path = [string]$REGISTERED[$Key]
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            Send-Text "🔴 Khong tim thay file:`n$path"
            Write-Log "Khong tim thay $Key : $path"
            return
        }

        $workDir = Split-Path -Parent $path
        $name = [IO.Path]::GetFileName($path)
        $out = Join-Path $env:TEMP "pinode_reg_${Key.TrimStart('/')}_$PID.out.txt"
        $err = Join-Path $env:TEMP "pinode_reg_${Key.TrimStart('/')}_$PID.err.txt"

        if (-not $Silent) {
            $desc = switch ($Key) {
                '/cleanram' { "🧹 Dọn RAM an toàn`n• Tắt Chrome, Edge, Search rác`n• Xóa file tạm (Temp)`n• Làm mới DNS`n• Không đụng tới Pi Node / Docker" }
                '/maintenance' { "🛠️ Bảo trì định kỳ`n• Dọn rác, cache, thùng rác`n• Dọn Docker volume / image treo`n• Chống ngủ máy + TRIM ổ đĩa`n• SFC/DISM nếu đúng lịch đầu tháng" }
                '/reset' { "🛠️ Reset mạng + Node`n• Khắc phục sự cố mạng (troubleshoot)`n• Gán IP tĩnh = IP máy đang dùng`n• Mở cổng firewall 31401–31410`n• Reset Docker / WSL (tạo lại sạch)" }
                '/diagnostic' { "🔍 Chẩn đoán hệ thống`n• Kiểm tra nhanh máy và dịch vụ liên quan Node" }
                default { "⚙️ Đang chạy $Key" }
            }
            Send-Text "$desc`n`n⏳ Vui lòng chờ, đang xử lý..."
        } else { Write-Log "Silent run $Key" }
        Write-Log "Bat dau $Key : $path cwd=$workDir"

        # GIONG /monitor (da chay OK): Start-Process + ArgumentList array + -Wait + Redirect
        $oldEnv = [Environment]::GetEnvironmentVariable('PINODE_CONTROLLER', 'Process')
        [Environment]::SetEnvironmentVariable('PINODE_CONTROLLER', '1', 'Process')
        try {
            $p = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$path`"") `
                -WorkingDirectory $workDir `
                -Wait -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $out `
                -RedirectStandardError $err

            $code = 0
            if ($null -ne $p) { try { $code = [int]$p.ExitCode } catch { $code = -1 } }
            Write-Log "$Key ExitCode=$code"

            $extra = ''
            try {
                $lines = @()
                if (Test-Path -LiteralPath $out) {
                    $lines += @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Where-Object { $_.ToString().Trim() } | Select-Object -Last 12)
                }
                if (Test-Path -LiteralPath $err) {
                    $el = @(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue | Where-Object { $_.ToString().Trim() } | Select-Object -Last 6)
                    if ($el.Count) { $lines += '--- stderr ---'; $lines += $el }
                }
                if ($lines.Count) { $extra = "`n`n📄 Output:`n" + ($lines -join "`n") }
            } catch {}

            $maintLog = Join-Path $workDir 'pinode_safe_maintenance.log'
            if ($Key -eq '/maintenance' -and (Test-Path -LiteralPath $maintLog)) {
                try {
                    $tail = @(Get-Content -LiteralPath $maintLog -Tail 8 -ErrorAction SilentlyContinue)
                    if ($tail.Count) { $extra += "`n`n📝 Log:`n" + ($tail -join "`n") }
                } catch {}
            }
            if ($extra.Length -gt 2800) { $extra = $extra.Substring(0, 2780) + "`n...[rut gon]" }

            if ($code -eq 0) {
                if (-not $Silent) { Send-Text "✅ $Key đã hoàn tất." } else { Write-Log "$Key OK (silent) Exit=0" }
            } else {
                # Loi khi chay tu lich -> bao dong; thu cong van gui
                if ($Silent) {
                    Send-AlertNotice "$Key that bai. ExitCode: $code`nFile: $name$extra"
                } else {
                    Send-Text "🟡 $Key ket thuc.`nExitCode: $code`nFile: $name$extra"
                }
            }
        } finally {
            Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
            try {
                if ($null -eq $oldEnv) {
                    [Environment]::SetEnvironmentVariable('PINODE_CONTROLLER', $null, 'Process')
                } else {
                    [Environment]::SetEnvironmentVariable('PINODE_CONTROLLER', $oldEnv, 'Process')
                }
            } catch {}
        }
    } catch {
        if ($Silent) {
            Send-AlertNotice "$Key exception: $($_.Exception.Message)"
        } else {
            Send-Text "🔴 $Key loi: $($_.Exception.Message)"
        }
        Write-Log "$Key exception: $($_.Exception.Message)"
    }
}

function Invoke-Screenshot {
    Send-Text "📸 Đang chụp màn hình...`n⏳ Vui lòng chờ."
    $file = Join-Path $env:TEMP 'pinode_telegram_screenshot.png'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $screen.Width,$screen.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($screen.Left,$screen.Top,0,0,$bmp.Size)
        $bmp.Save($file,[System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose()
        $bmp.Dispose()
        if (Send-Photo -Path $file -Caption "PI NODE SCREENSHOT - $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')") {
            Send-Text "✅ Da gui anh man hinh."
        } else {
            Send-Text "🔴 Gui anh that bai."
        }
    } catch {
        Send-Text "🔴 Screenshot loi: $($_.Exception.Message)"
        Write-Log "Screenshot loi: $($_.Exception.Message)"
    } finally {
        if (Test-Path $file) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}


function Get-DonateText {
    return @"
☕ UNG HO TAC GIA
━━━━━━━━━━━━━━
🏦 MB Bank
💳 0905428801
👤 TRAN HUU NGHI

📱 QR se gui kem anh (lenh /donate)
"@
}



function Get-DailyDonateTip {
    $tips = @(
        "☕ Một ly cà phê ủng hộ tác giả: MB 0905428801 — TRAN HUU NGHI · /donate",
        "🚀 Node ổn định rồi thì mạnh tay ủng hộ nhé: /donate",
        "😄 Quan cà phê cho dev — STK MB 0905428801 · /donate",
        "💛 Ủng hộ dự án Pi Node Controller: /donate"
    )
    return $tips[(Get-Random -Maximum $tips.Count)]
}

function Show-Help {
    return @"
🤖 PI NODE CONTROLLER

Chào mừng bạn đến với Pi Node Controller.

Bot giúp bạn giám sát • bảo trì • xử lý sự cố Pi Node trực tiếp qua Telegram.

━━━━━━━━━━━━━━

📊 GIÁM SÁT
/status — Trạng thái Node
/monitor — Kiểm tra chuyên sâu
/report — Báo cáo hệ thống
/scheduler — Xem & chỉnh lịch tự động

🛠️ BẢO TRÌ
/cleanram — Dọn RAM an toàn
/maintenance — Bảo trì định kỳ
/diagnostic — Chẩn đoán hệ thống
/reset — Reset mạng + Docker
/cancel — Hủy thao tác

🖥️ HỆ THỐNG
/docker — Kiểm tra Docker
/disk — Kiểm tra ổ đĩa
/logs — Xem nhật ký
/screenshot — Chụp màn hình
/insights — Thống kê tương tác (gợi ý nâng cấp app)

💬 TIỆN ÍCH
/ask <câu hỏi> — Hỏi Hermes
/help — Xem hướng dẫn
/donate — Ủng hộ dự án

━━━━━━━━━━━━━━

⚙️ TỰ ĐỘNG HÓA

• Kiểm tra Node mỗi 60 phút
• Phát hiện lỗi → gửi cảnh báo Telegram
• Lỗi đồng bộ / port lặp lại → tự xử lý
• Báo cáo hệ thống lúc 07:00 & 18:00

🔐 An toàn • Tự động • Ổn định

Pi Node Controller đang giám sát hệ thống của bạn.

☕ Ủng hộ: MB Bank 0905428801 — TRAN HUU NGHI
   Quan cà phê cho tác giả là vui rồi 😄 · /donate
"@
}









# ===== SCHEDULER RUNTIME SETTINGS (Telegram có thể chỉnh) =====
$SCHED_SETTINGS = Join-Path $StateDir 'scheduler_settings.json'

function Get-DefaultSchedulerSettings {
    return [ordered]@{
        enabled                 = [bool]$SchedulerEnabled
        monitorIntervalMinutes  = [int]$MonitorIntervalMinutes
        problemRescanMinutes    = [int]$ProblemRescanMinutes
        dailyReportHours        = @($DailyReportHours)
        maintenanceDayOfWeek    = [int]$MaintenanceDayOfWeek
        weeklyMaintenanceTime   = [string]$WeeklyMaintenanceTime
        autoResetOnSyncPortFail = [bool]$AutoResetOnSyncPortFail
        problemStreakBeforeReset= [int]$ProblemStreakBeforeReset
    }
}

function Read-SchedulerSettings {
    $defaults = Get-DefaultSchedulerSettings
    if (!(Test-Path -LiteralPath $SCHED_SETTINGS)) { return $defaults }
    try {
        $raw = Get-Content -LiteralPath $SCHED_SETTINGS -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = [ordered]@{}
        foreach ($k in $defaults.Keys) {
            if ($null -ne $raw.PSObject.Properties[$k]) {
                $o[$k] = $raw.$k
            } else {
                $o[$k] = $defaults[$k]
            }
        }
        # Chuẩn hoá kiểu
        $o.enabled = [bool]$o.enabled
        $o.monitorIntervalMinutes = [int]$o.monitorIntervalMinutes
        $o.problemRescanMinutes = [int]$o.problemRescanMinutes
        $o.maintenanceDayOfWeek = [int]$o.maintenanceDayOfWeek
        $o.weeklyMaintenanceTime = [string]$o.weeklyMaintenanceTime
        $o.autoResetOnSyncPortFail = [bool]$o.autoResetOnSyncPortFail
        $o.problemStreakBeforeReset = [int]$o.problemStreakBeforeReset
        if ($o.dailyReportHours -is [System.Array]) {
            $o.dailyReportHours = @($o.dailyReportHours | ForEach-Object { [int]$_ })
        } else {
            $o.dailyReportHours = @([int]$o.dailyReportHours)
        }
        return $o
    } catch {
        Write-Log "Doc scheduler_settings.json loi: $($_.Exception.Message)"
        return $defaults
    }
}

function Save-SchedulerSettings {
    param($Settings)
    try {
        if (!(Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        ($Settings | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $SCHED_SETTINGS -Encoding UTF8
        Write-Log "Da luu scheduler_settings.json"
    } catch {
        Write-Log "Luu scheduler_settings.json loi: $($_.Exception.Message)"
    }
}

function Apply-SchedulerSettings {
    param($Settings)
    $script:SchedEnabled = [bool]$Settings.enabled
    $script:SchedMonitorInterval = [math]::Max(5, [math]::Min(1440, [int]$Settings.monitorIntervalMinutes))
    $script:SchedRescanMinutes = [math]::Max(3, [math]::Min(180, [int]$Settings.problemRescanMinutes))
    $script:SchedReportHours = @($Settings.dailyReportHours | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 -and $_ -le 23 } | Select-Object -Unique)
    if ($script:SchedReportHours.Count -eq 0) { $script:SchedReportHours = @(7, 18) }
    $script:SchedMaintDay = [math]::Max(0, [math]::Min(6, [int]$Settings.maintenanceDayOfWeek))
    $t = [string]$Settings.weeklyMaintenanceTime
    if ($t -notmatch '^\d{1,2}:\d{2}$') { $t = '23:00' }
    $script:SchedMaintTime = $t
    $script:SchedAutoReset = [bool]$Settings.autoResetOnSyncPortFail
    $script:SchedStreakNeed = [math]::Max(1, [math]::Min(20, [int]$Settings.problemStreakBeforeReset))
}

# Load runtime settings (ghi đè Config nếu user đã chỉnh qua Telegram)
$script:SchedSettings = Read-SchedulerSettings
Apply-SchedulerSettings -Settings $script:SchedSettings

function Get-SchedulerDayName([int]$d) {
    switch ($d) {
        0 { return 'Chủ nhật' }
        1 { return 'Thứ 2' }
        2 { return 'Thứ 3' }
        3 { return 'Thứ 4' }
        4 { return 'Thứ 5' }
        5 { return 'Thứ 6' }
        6 { return 'Thứ 7' }
        default { return "Day $d" }
    }
}

function Read-SchedulerState { if(Test-Path -LiteralPath $SCHED_STATE){try{return Get-Content -LiteralPath $SCHED_STATE -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}; return [pscustomobject]@{nextMonitor=(Get-Date).AddMinutes($MonitorIntervalMinutes).ToString('o');lastReportKey='';lastMaintenanceKey='';problemStreak=0;lastProblemAt='';lastAutoResetKey=''} }

function Save-SchedulerState($s){try{$s|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $SCHED_STATE -Encoding UTF8}catch{Write-Log "Scheduler state save loi: $($_.Exception.Message)"}}
$script:SchedulerState=Read-SchedulerState
function Send-AlertNotice {
    param([string]$Reason)
    $msg = Get-NodeStatus
    $full = "🚨 CANH BAO NODE`n━━━━━━━━━━━━━━`n$Reason`n`n$msg`n`n🕐 $(Get-Date -Format 'dd/MM HH:mm')"
    Write-Log "ALERT: $Reason"
    $n = 3
    try { if ([int]$AlertRepeat -gt 0) { $n = [int]$AlertRepeat } } catch {}
    $delay = 2
    try { if ([int]$AlertRepeatDelaySec -gt 0) { $delay = [int]$AlertRepeatDelaySec } } catch {}
    for ($i = 1; $i -le $n; $i++) {
        Send-Text $full
        if ($AlertPlaySound) {
            try { [console]::beep(1200, 300); [console]::beep(800, 200) } catch {}
        }
        if ($i -lt $n) { Start-Sleep -Seconds $delay }
    }
}

function Invoke-SmartMonitor {
    param([switch]$Silent)

    if (!(Test-Path -LiteralPath $MonitorScript)) {
        if (-not $Silent) { Send-Text "🔴 Smart Monitor khong ton tai:`n$MonitorScript" }
        Write-Log "Smart Monitor khong ton tai: $MonitorScript"
        return $false
    }

    if (-not $Silent) {
        Send-Text "🔍 Đang kiểm tra Node...`n⏳ Vui lòng chờ (có thể 1–2 phút)."
    } else {
        Write-Log "Scheduler: chay Smart Monitor (im lang neu an toan)"
    }

    $before = @(Get-NodeHistory).Count
    $out = Join-Path $env:TEMP "pinode_monitor_$PID.out.txt"
    $err = Join-Path $env:TEMP "pinode_monitor_$PID.err.txt"

    try {
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$MonitorScript`"") `
            -WorkingDirectory $DataDir `
            -Wait -PassThru -WindowStyle Minimized `
            -RedirectStandardOutput $out `
            -RedirectStandardError $err

        $code = [int]$p.ExitCode
        $hist = @(Get-NodeHistory)
        $new = $false
        if ($hist.Count -gt $before) { $new = $true }
        elseif ($hist.Count) {
            try { $new = ([datetime]$hist[-1].time -ge (Get-Date).AddMinutes(-10)) } catch {}
        }

        if ($code -eq 0 -or $code -eq 2) {
            if (-not $new) {
                $d = 'Monitor ket thuc nhung khong tao ban ghi node_history moi.'
                $ml = Join-Path $DataDir 'Monitor_Node.log'
                if (Test-Path -LiteralPath $ml) {
                    $d += "`n`n" + ((Get-Content -LiteralPath $ml -Tail 15 -ErrorAction SilentlyContinue) -join "`n")
                }
                # Day la bat thuong -> luon bao
                Send-AlertNotice $d
                Write-Log $d
                return $false
            }

            $last = $hist[-1]
            $problems = 0
            try { $problems = [int]$last.problems } catch {}

            if ($problems -gt 0) {
                # CO VAN DE -> bao dong manh
                Send-AlertNotice "Smart Monitor phat hien $problems van de."
                Write-Log "Smart Monitor ALERT Exit=$code Problems=$problems"
                return $true
            }

            # AN TOAN: chi reply khi goi thu cong
            if (-not $Silent) {
                Send-Text (Get-NodeStatus)
            } else {
                Write-Log "Smart Monitor OK (im lang) Exit=$code Problems=0"
            }
            return $true
        }

        # Loi thuc thi -> luon bao
        $d = "Smart Monitor loi. ExitCode: $code`nPath: $MonitorScript"
        if (Test-Path -LiteralPath $err) {
            $e = (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)
            if ($e) { $d += "`n`n$e".Trim() }
        }
        $ml = Join-Path $DataDir 'Monitor_Node.log'
        if (Test-Path -LiteralPath $ml) {
            $d += "`n`nLog:`n" + ((Get-Content -LiteralPath $ml -Tail 15 -ErrorAction SilentlyContinue) -join "`n")
        }
        Send-AlertNotice $d
        Write-Log $d
        return $false
    } catch {
        Send-AlertNotice "Smart Monitor loi khi khoi chay:`n$($_.Exception.Message)"
        Write-Log "Monitor exception: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Get-SchedulerStatus {
    $s = $script:SchedulerState
    $on = if ($script:SchedEnabled) { 'BẬT ✅' } else { 'TẮT ⏸️' }
    $auto = if ($script:SchedAutoReset) { 'Bật' } else { 'Tắt' }
    $hours = ($script:SchedReportHours | ForEach-Object { '{0:00}:00' -f $_ }) -join ', '
    $dayName = Get-SchedulerDayName $script:SchedMaintDay
    $next = $s.nextMonitor
    try { $next = ([datetime]$s.nextMonitor).ToString('dd/MM HH:mm') } catch {}
    $t = "⚙️ LỊCH TỰ ĐỘNG · $on`n"
    $t += "──────────────`n"
    $t += "🔍 Quét Node: mỗi $($script:SchedMonitorInterval) phút`n"
    $t += "⏭ Lần quét tới: $next`n"
    $t += "🔁 Rescan khi lỗi: $($script:SchedRescanMinutes) phút`n"
    $t += "📊 Báo cáo ngày: $hours`n"
    $t += "🛠️ Bảo trì: $dayName $($script:SchedMaintTime)`n"
    $t += "🚨 Tự reset khi lỗi liên tiếp: $auto (sau $($script:SchedStreakNeed) lần)`n"
    $t += "📉 Chuỗi lỗi hiện tại: $($s.problemStreak)`n`n"
    $t += "Điều khiển:`n"
    $t += "/scheduler on|off`n"
    $t += "/scheduler interval 59`n"
    $t += "/scheduler rescan 10`n"
    $t += "/scheduler report 7,18`n"
    $t += "/scheduler maintenance 23:00`n"
    $t += "/scheduler day 0   (0=CN … 6=T7)`n"
    $t += "/scheduler autoreset on|off`n"
    $t += "/scheduler streak 3`n"
    $t += "/scheduler defaults"
    return $t
}

function Handle-SchedulerCommand {
    param([string]$ArgsText)
    $a = if ($null -eq $ArgsText) { '' } else { $ArgsText.Trim() }
    if ([string]::IsNullOrWhiteSpace($a)) {
        Send-Text (Get-SchedulerStatus)
        return
    }

    $parts = @($a -split '\s+', 2)
    $cmd = $parts[0].ToLowerInvariant()
    $val = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

    $settings = Read-SchedulerSettings
    $changed = $false
    $msg = ''

    switch -Regex ($cmd) {
        '^(on|bat|bật|enable|start)$' {
            $settings.enabled = $true
            $changed = $true
            $msg = '✅ Đã BẬT lịch tự động.'
        }
        '^(off|tat|tắt|disable|stop)$' {
            $settings.enabled = $false
            $changed = $true
            $msg = '⏸️ Đã TẮT lịch tự động. Các lệnh thủ công (/monitor, /status…) vẫn dùng được.'
        }
        '^(interval|phut|phút|moi|mỗi)$' {
            if ($val -notmatch '^\d+$') {
                Send-Text "⚠️ Dùng: /scheduler interval 59`n(5–1440 phút)"
                return
            }
            $n = [int]$val
            if ($n -lt 5 -or $n -gt 1440) {
                Send-Text "⚠️ Khoảng cho phép: 5–1440 phút."
                return
            }
            $settings.monitorIntervalMinutes = $n
            $changed = $true
            $msg = "✅ Chu kỳ quét Node: mỗi $n phút."
            # Cập nhật lần quét tới
            try {
                $script:SchedulerState.nextMonitor = (Get-Date).AddMinutes($n).ToString('o')
                Save-SchedulerState $script:SchedulerState
            } catch {}
        }
        '^(rescan|rescane|lai|lại)$' {
            if ($val -notmatch '^\d+$') {
                Send-Text "⚠️ Dùng: /scheduler rescan 10`n(3–180 phút)"
                return
            }
            $n = [int]$val
            if ($n -lt 3 -or $n -gt 180) {
                Send-Text "⚠️ Khoảng cho phép: 3–180 phút."
                return
            }
            $settings.problemRescanMinutes = $n
            $changed = $true
            $msg = "✅ Rescan khi có lỗi: mỗi $n phút."
        }
        '^(report|baocao|báo cáo|bao cao)$' {
            if ([string]::IsNullOrWhiteSpace($val)) {
                Send-Text "⚠️ Dùng: /scheduler report 7,18`n(các giờ 0–23, cách nhau bằng dấu phẩy)"
                return
            }
            $hours = @()
            foreach ($h in ($val -split '[,;\s]+')) {
                if ($h -match '^\d{1,2}$') {
                    $hi = [int]$h
                    if ($hi -ge 0 -and $hi -le 23) { $hours += $hi }
                }
            }
            $hours = @($hours | Select-Object -Unique | Sort-Object)
            if ($hours.Count -eq 0) {
                Send-Text "⚠️ Không parse được giờ. Ví dụ: /scheduler report 7,12,18"
                return
            }
            $settings.dailyReportHours = $hours
            $changed = $true
            $msg = "✅ Báo cáo ngày lúc: " + (($hours | ForEach-Object { '{0:00}:00' -f $_ }) -join ', ')
        }
        '^(maintenance|baotri|bảo trì|time|gio|giờ)$' {
            if ($val -notmatch '^(\d{1,2}):(\d{2})$') {
                Send-Text "⚠️ Dùng: /scheduler maintenance 23:00"
                return
            }
            $hh = [int]$Matches[1]; $mm = [int]$Matches[2]
            if ($hh -gt 23 -or $mm -gt 59) {
                Send-Text "⚠️ Giờ không hợp lệ."
                return
            }
            $settings.weeklyMaintenanceTime = ('{0:00}:{1:00}' -f $hh, $mm)
            $changed = $true
            $msg = "✅ Giờ bảo trì tuần: $($settings.weeklyMaintenanceTime)"
        }
        '^(day|thu|thứ|ngay)$' {
            if ($val -notmatch '^\d+$') {
                Send-Text "⚠️ Dùng: /scheduler day 0`n0=Chủ nhật … 6=Thứ 7"
                return
            }
            $n = [int]$val
            if ($n -lt 0 -or $n -gt 6) {
                Send-Text "⚠️ Ngày: 0 (CN) đến 6 (T7)."
                return
            }
            $settings.maintenanceDayOfWeek = $n
            $changed = $true
            $msg = "✅ Ngày bảo trì: $(Get-SchedulerDayName $n)"
        }
        '^(autoreset|auto-reset|tureset)$' {
            if ($val -match '^(on|bat|bật|1|true)$') {
                $settings.autoResetOnSyncPortFail = $true
                $changed = $true
                $msg = '✅ Đã BẬT tự reset khi lỗi đồng bộ/port liên tiếp.'
            } elseif ($val -match '^(off|tat|tắt|0|false)$') {
                $settings.autoResetOnSyncPortFail = $false
                $changed = $true
                $msg = '⏸️ Đã TẮT tự reset.'
            } else {
                Send-Text "⚠️ Dùng: /scheduler autoreset on|off"
                return
            }
        }
        '^(streak|chuoi|chuỗi)$' {
            if ($val -notmatch '^\d+$') {
                Send-Text "⚠️ Dùng: /scheduler streak 3`n(1–20)"
                return
            }
            $n = [int]$val
            if ($n -lt 1 -or $n -gt 20) {
                Send-Text "⚠️ Khoảng: 1–20."
                return
            }
            $settings.problemStreakBeforeReset = $n
            $changed = $true
            $msg = "✅ Số lần lỗi liên tiếp trước khi tự reset: $n"
        }
        '^(defaults|default|macdinh|mặc định|reset)$' {
            $settings = Get-DefaultSchedulerSettings
            $changed = $true
            $msg = '♻️ Đã khôi phục tham số lịch về mặc định trong Config.'
            try {
                $script:SchedulerState.nextMonitor = (Get-Date).AddMinutes([int]$settings.monitorIntervalMinutes).ToString('o')
                Save-SchedulerState $script:SchedulerState
            } catch {}
        }
        '^(help|huongdan|hướng dẫn|\?)$' {
            Send-Text (Get-SchedulerStatus)
            return
        }
        default {
            Send-Text "⚠️ Không hiểu tham số.`n`n$(Get-SchedulerStatus)"
            return
        }
    }

    if ($changed) {
        Save-SchedulerSettings -Settings $settings
        $script:SchedSettings = $settings
        Apply-SchedulerSettings -Settings $settings
        Send-Text ($msg + "`n`n" + (Get-SchedulerStatus))
    }
}


function Invoke-SchedulerTick {
    if (-not $script:SchedEnabled) { return }
    $now = Get-Date

    $rescanMin = $script:SchedRescanMinutes
    $autoReset = $script:SchedAutoReset
    $streakNeed = $script:SchedStreakNeed
    $intervalDefault = $script:SchedMonitorInterval

    # --- Monitor định kỳ; nếu đang lỗi thì rescan nhanh hơn ---
    try { $next = [datetime]$script:SchedulerState.nextMonitor }
    catch { $next = $now.AddMinutes($intervalDefault) }

    if ($now -ge $next) {
        $interval = $intervalDefault
        $streak = 0
        try { $streak = [int]$script:SchedulerState.problemStreak } catch {}
        if ($streak -gt 0) { $interval = $rescanMin }

        $script:SchedulerState.nextMonitor = $now.AddMinutes($interval).ToString('o')
        Save-SchedulerState $script:SchedulerState

        $ok = Invoke-SmartMonitor -Silent
        $hist = @(Get-NodeHistory)
        $problems = 0
        $critical = 0
        $severity = 'OK'
        $syncBad = $false
        $portBad = $false
        $dockerBad = $false
        $netBad = $false
        if ($hist.Count) {
            $last = $hist[-1]
            try { $problems = [int]$last.problems } catch {}
            try { $critical = [int]$last.critical } catch { $critical = 0 }
            try { $severity = [string]$last.severity } catch { $severity = 'OK' }
            $sync = [string]$last.sync
            $port = [string]$last.port
            $docker = [string]$last.docker
            # Chỉ coi sync xấu khi lệch/chưa đồng bộ rõ ràng — không tính "Chua ro" (thiếu PiCheck)
            if ($sync -in @('Lech khoi','Chua dong bo')) { $syncBad = $true }
            if ($port -eq 'CLOSED') { $portBad = $true }
            if ($docker -eq 'STOPPED') { $dockerBad = $true }
            try {
                if ($last.internet -eq 'ERROR' -or $last.internet -eq 'OFFLINE') { $netBad = $true }
            } catch {}
        }

        # Su co THUC: critical severity hoặc port/docker/sync xấu
        $realProblem = ($severity -eq 'CRITICAL' -or $critical -gt 0 -or $syncBad -or $portBad -or $dockerBad -or $netBad)
        # Reset chỉ khi CÓ ÍT NHẤT 2 điều kiện nghiêm trọng cùng lúc HOẶC port+docker cùng xấu
        $severeCount = 0
        if ($syncBad) { $severeCount++ }
        if ($portBad) { $severeCount++ }
        if ($dockerBad) { $severeCount++ }
        if ($netBad) { $severeCount++ }
        $resetEligible = ($severeCount -ge 2) -or ($portBad -and $dockerBad) -or ($portBad -and $syncBad)

        if ($realProblem) {
            $streak = $streak + 1
            $script:SchedulerState.problemStreak = $streak
            $script:SchedulerState.lastProblemAt = $now.ToString('o')
            $script:SchedulerState.nextMonitor = $now.AddMinutes($rescanMin).ToString('o')
            Save-SchedulerState $script:SchedulerState

            $reason = "Sự cố THỰC (lần $streak, severity=$severity). Quét lại sau $rescanMin phút.`n"
            $reason += "Critical=$critical | SyncBad=$syncBad | PortBad=$portBad | DockerBad=$dockerBad | NetBad=$netBad"
            Send-AlertNotice $reason

            if ($autoReset -and $resetEligible -and $streak -ge $streakNeed) {
                $resetKey = $now.ToString('yyyy-MM-dd-HH')
                if ([string]$script:SchedulerState.lastAutoResetKey -ne $resetKey) {
                    $script:SchedulerState.lastAutoResetKey = $resetKey
                    $script:SchedulerState.problemStreak = 0
                    Save-SchedulerState $script:SchedulerState
                    Send-AlertNotice "Đủ điều kiện reset: $severeCount tín hiệu nghiêm trọng × $streakNeed lần.`nĐang TỰ ĐỘNG chạy /reset..."
                    Invoke-RegisteredProgram -Key '/reset' -Silent
                }
            } elseif ($autoReset -and $streak -ge $streakNeed -and -not $resetEligible) {
                Write-Log "Streak=$streak nhưng chưa đủ đa điều kiện để reset (severeCount=$severeCount)"
            }
        } else {
            if ($streak -gt 0) {
                Write-Log "Node phục hồi sau $streak lần lỗi - về lịch $intervalDefault phút"
                Send-Text "✅ Node đã ổn định trở lại.`nVề lịch quét mỗi $intervalDefault phút."
            }
            $script:SchedulerState.problemStreak = 0
            $script:SchedulerState.nextMonitor = $now.AddMinutes($intervalDefault).ToString('o')
            Save-SchedulerState $script:SchedulerState
        }
    }

    # --- Báo cáo theo giờ cấu hình ---
    $reportKey = "$($now.ToString('yyyy-MM-dd'))-$($now.Hour)"
    if ($script:SchedReportHours -contains $now.Hour -and $now.Minute -lt 5 -and [string]$script:SchedulerState.lastReportKey -ne $reportKey) {
        $script:SchedulerState.lastReportKey = $reportKey
        Save-SchedulerState $script:SchedulerState
        Write-Log "Scheduler: gửi báo cáo $reportKey"
        $h = @(Get-NodeHistory)
        if ($h.Count -eq 0) {
            Send-AlertNotice "Báo cáo định kỳ: KHÔNG CÓ dữ liệu node_history.json"
        } else {
            Send-Text ((Get-NodeReport) + "`n`n" + (Get-DailyDonateTip))
            $problems = 0
            try { $problems = [int]$h[-1].problems } catch {}
            if ($problems -gt 0) {
                Send-AlertNotice "Báo cáo định kỳ: còn $problems vấn đề"
            }
        }
    }

    # --- Bảo trì tuần theo ngày + giờ cấu hình ---
    $maintKey = "$($now.ToString('yyyy-MM-dd'))-$($script:SchedMaintTime)"
    $isMaintDay = ([int]$now.DayOfWeek -eq [int]$script:SchedMaintDay)
    if ($isMaintDay -and $now.ToString('HH:mm') -eq $script:SchedMaintTime -and [string]$script:SchedulerState.lastMaintenanceKey -ne $maintKey) {
        $script:SchedulerState.lastMaintenanceKey = $maintKey
        Save-SchedulerState $script:SchedulerState
        Write-Log "Scheduler: Weekly Maintenance (silent)"
        Invoke-RegisteredProgram -Key '/maintenance' -Silent
    }
}

function Handle-Message {
    param($m)
    if (!$m.message -or !$m.message.chat) { return }
    $chat = [string]$m.message.chat.id
    $text = [string]$m.message.text
    if ($null -eq $text) { $text = '' }
    $text = $text.Trim()

    if ($chat -ne [string]$CHAT_ID) {
        Write-Log "Bo qua tin nhan tu Chat ID $chat"
        return
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    # Ghi nhận tin người dùng (lệnh hoặc tự nhiên) để bộ nhớ hội thoại + phân tích sau này
    $cmdIntent = 'NATURAL'
    if ($text -match '^/') {
        $cmdIntent = ($text -split '\s+')[0].ToLowerInvariant() -replace '@\w+$',''
    }
    Add-ChatTurn -Role 'user' -Text $text -Intent $cmdIntent -Source $(if ($text -match '^/') { 'command' } else { 'natural' })
    $script:LastChatIntent = $cmdIntent
    $script:LastChatSource = $(if ($text -match '^/') { 'command' } else { 'natural' })
    $script:RememberReply = $true

    switch -Regex ($text) {
        '(?i)^/help(@\w+)?$'       { Send-Text (Show-Help); break }
        '(?i)^/donate(@\w+)?$'     { Invoke-Donate; break }
        '(?i)^/ask(?:@\w+)?\s+(.+)$' { Invoke-HermesQuestion -Question $Matches[1].Trim(); break }
        '(?i)^/status(@\w+)?$'     { Send-Text (Get-NodeStatus); break }
        '(?i)^/monitor(s)?(@\w+)?$' { Invoke-SmartMonitor; break }
        '(?i)^/scheduler(?:@\w+)?(?:\s+(.*))?$' { Handle-SchedulerCommand -ArgsText $Matches[1]; break }
        '(?i)^/report(@\w+)?$'     { Send-Text ((Get-NodeReport) + "`n`n" + (Get-DailyDonateTip)); break }
        '(?i)^/logs(@\w+)?$'       { Send-Text (Get-Logs); break }
        '(?i)^/docker(@\w+)?$'     { Send-Text (Get-DockerStatus); break }
        '(?i)^/disk(@\w+)?$'       { Send-Text (Get-DiskStatus); break }
        '(?i)^/insights(@\w+)?$'   {
            $raw = Get-ChatHistoryInsights
            try {
                $ins = $raw | ConvertFrom-Json
                $t = "📈 INSIGHTS TƯƠNG TÁC`n"
                $t += "Tổng tin: $($ins.total) · Tin user: $($ins.user_messages)`n"
                if ($ins.first_time) { $t += "Từ: $($ins.first_time)`n" }
                if ($ins.last_time) { $t += "Đến: $($ins.last_time)`n`n" }
                $t += "Chủ đề hay hỏi:`n"
                if ($ins.top_topics) {
                    $ins.top_topics.PSObject.Properties | ForEach-Object {
                        $t += "• $($_.Name): $($_.Value)`n"
                    }
                }
                $t += "`nIntent:`n"
                if ($ins.intents) {
                    $ins.intents.PSObject.Properties | Sort-Object { [int]$_.Value } -Descending | ForEach-Object {
                        $t += "• $($_.Name): $($_.Value)`n"
                    }
                }
                $t += "`n💡 Dùng dữ liệu này để ưu tiên tính năng app sau này.`nFile: Data/chat_history.json"
                Send-Text $t
            } catch {
                Send-Text "📈 Insights:`n$raw"
            }
            break
        }
        '(?i)^/diagnostic(@\w+)?$' { Invoke-DiagnosticAI -UserQuestion 'Chẩn đoán hệ thống Pi Node'; break }
        '(?i)^/cleanram(@\w+)?$'   { Invoke-RegisteredProgram '/cleanram'; break }
        '(?i)^/screenshot(@\w+)?$' { Invoke-Screenshot; break }
        '(?i)^/maintenance(@\w+)?$' {
            $script:PendingMaintenance = $true
            $script:PendingMaintenanceAt = Get-Date
            Send-Text @"
🛠️ BẢO TRÌ ĐỊNH KỲ — XÁC NHẬN
━━━━━━━━━━━━━━
Sẽ thực hiện:
• Tắt app rác (Chrome, Edge…) — không đụng Pi/Docker
• Xóa file tạm, cache
• Dọn Docker volume / image treo
• Làm mới DNS, chống ngủ máy
• TRIM ổ đĩa (nếu CPU rảnh)
• SFC/DISM nếu đúng lịch đầu tháng

Gửi /confirm trong $ConfirmTimeout giây để chạy.
Gửi /cancel để hủy.
⏳ Đang chờ xác nhận...
"@
            break
        }
        '(?i)^/confirm(@\w+)?$' {
            if ($script:PendingMaintenance -and $script:PendingMaintenanceAt -and ((Get-Date) - $script:PendingMaintenanceAt).TotalSeconds -le $ConfirmTimeout) {
                $script:PendingMaintenance = $false
                $script:PendingMaintenanceAt = $null
                Invoke-RegisteredProgram '/maintenance'
            } else {
                $script:PendingMaintenance = $false
                $script:PendingMaintenanceAt = $null
                Send-Text "⚠️ Het thoi gian xac nhan hoac khong co bao tri dang cho.`nGui lai /maintenance neu can."
            }
            break
        }
        
        '(?i)^/reset(@\w+)?$' {
            $script:PendingReset = $true
            $script:PendingResetAt = Get-Date
            Send-Text @"
🛠️ RESET MẠNG + NODE — XÁC NHẬN
━━━━━━━━━━━━━━
Dùng khi: không đồng bộ, cổng đóng, mất mạng.

Sẽ thực hiện:
1) Khắc phục sự cố mạng (troubleshoot)
2) Gán IP tĩnh = IP máy đang dùng
3) Mở firewall cổng 31401–31410
4) Reset Docker / WSL (tạo lại sạch)
5) Bật chống ngủ máy, ưu tiên Docker

⚠️ Docker sẽ tạm dừng rồi tạo lại — cần mở lại Pi Node.
Cần quyền Administrator.

Gửi /confirmreset trong $ConfirmTimeout giây để chạy.
Gửi /cancel để hủy.
⏳ Đang chờ xác nhận...
"@
            break
        }
        '(?i)^/confirmreset(@\w+)?$' {
            if ($script:PendingReset -and $script:PendingResetAt -and ((Get-Date) - $script:PendingResetAt).TotalSeconds -le $ConfirmTimeout) {
                $script:PendingReset = $false
                $script:PendingResetAt = $null
                Invoke-RegisteredProgram '/reset'
            } else {
                $script:PendingReset = $false
                $script:PendingResetAt = $null
                Send-Text "⚠️ Het han xac nhan reset. Gui lai /reset neu can."
            }
            break
        }

        '(?i)^/cancel(@\w+)?$' {
            $script:PendingMaintenance = $false
            $script:PendingMaintenanceAt = $null
            $script:PendingReset = $false
            $script:PendingResetAt = $null
            Send-Text "✅ Đã hủy thao tác đang chờ."
            break
        }
        default {
            # Tin nhan tu nhien duoc Gemini hieu y dinh; lenh co san van uu tien.
            Invoke-NaturalLanguageMessage -Question $text
            break
        }
    }
}

Write-Log "Controller v2.0 khoi dong. PID=$PID"
try {
  foreach ($k in @($REGISTERED.Keys)) {
    $rp = [string]$REGISTERED[$k]
    $ex = Test-Path -LiteralPath $rp
    Write-Log "Registered $k => $rp exists=$ex"
  }
} catch { Write-Log "Registered dump loi: $($_.Exception.Message)" }
Invoke-Telegram 'deleteWebhook' @{} | Out-Null
# Menu mo dau: chi gui 1 lan (kem ung ho). Lan sau chi bao san sang ngan.
try {
  $welcomeFlag = Join-Path $StateDir 'welcome_sent.flag'
  if (-not (Test-Path -LiteralPath $welcomeFlag)) {
    $intro = @"
🤖 PI NODE CONTROLLER

Chào mừng bạn đến với Pi Node Controller.

Bot giúp bạn giám sát • bảo trì • xử lý sự cố Pi Node trực tiếp qua Telegram.

━━━━━━━━━━━━━━

📊 GIÁM SÁT
/status — Trạng thái Node
/monitor — Kiểm tra chuyên sâu
/report — Báo cáo hệ thống
/scheduler — Xem & chỉnh lịch tự động

🛠️ BẢO TRÌ
/cleanram — Dọn RAM an toàn
/maintenance — Bảo trì định kỳ
/diagnostic — Chẩn đoán hệ thống
/reset — Reset mạng + Docker
/cancel — Hủy thao tác

🖥️ HỆ THỐNG
/docker · /disk · /logs · /screenshot

💬 /ask · /help · /donate

━━━━━━━━━━━━━━

⚙️ TỰ ĐỘNG HÓA
• Kiểm tra Node mỗi 60 phút
• Phát hiện lỗi → cảnh báo Telegram
• Lỗi đồng bộ / port lặp lại → tự xử lý
• Báo cáo lúc 07:00 & 18:00

🔐 An toàn • Tự động • Ổn định

"@
    Send-Text $intro
    Start-Sleep -Milliseconds 500
    Invoke-Donate
    try {
      New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction SilentlyContinue | Out-Null
      Set-Content -LiteralPath $welcomeFlag -Value (Get-Date).ToString('o') -Encoding UTF8
    } catch {}
  } else {
    Send-Text "🟢 Pi Node Controller đang giám sát hệ thống của bạn.`n/status · /monitor · /help"
  }
} catch {
  Send-Text "🟢 Controller sẵn sàng · /help"
  Write-Log "Welcome loi: $($_.Exception.Message)"
}

while ($true) {
    try {
        Invoke-SchedulerTick
        $body = @{ timeout=$POLL_TIMEOUT; offset=$script:Offset; allowed_updates='message' }
        $r = Invoke-Telegram 'getUpdates' $body ($POLL_TIMEOUT + 10)
        if ($r -and $r.ok -and $r.result) {
            foreach ($u in $r.result) {
                $script:Offset = [int64]$u.update_id + 1
                if ($u.message) { Handle-Message $u }
            }
        }
    } catch {
        Write-Log "Vong lap loi: $($_.Exception.Message)"
        Start-Sleep -Seconds 5
    }
}
