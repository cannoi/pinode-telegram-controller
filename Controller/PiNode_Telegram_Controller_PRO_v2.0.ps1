if (Test-Path "$PSScriptRoot/Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1" }
$SecurityModule = Join-Path (Split-Path -Parent $PSScriptRoot) "Modules\Security_Guard.ps1"
if (Test-Path -LiteralPath $SecurityModule) { . $SecurityModule }
# PI NODE TELEGRAM CONTROLLER PRO v11.1 — INTEGRATED LIVE READER
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
$HISTORY_ARCHIVE_DIR = Join-Path $DataDir 'History\Node'
$CHAT_HISTORY_FILE = if ($ChatHistoryFile) { $ChatHistoryFile } else { Join-Path $DataDir 'chat_history.json' }
$CHAT_HISTORY_MAX = if ($ChatHistoryMaxRecords) { [int]$ChatHistoryMaxRecords } else { 500 }
$CHAT_HISTORY_CONTEXT_TURNS = if ($ChatHistoryContextTurns) { [int]$ChatHistoryContextTurns } else { 8 }
$REQUEST_TIMEOUT=$RequestTimeout; $POLL_TIMEOUT=$PollingTimeout; $MAX_LOG_BYTES=$MaxLogBytes
$HERMES_CONTAINER=$HermesContainer; $HERMES_TIMEOUT_SEC=$HermesTimeoutSec; $HERMES_INCLUDE_NODE_CONTEXT=$HermesIncludeNodeContext
$REGISTERED=$Registered
$BOT_TOKEN=$BotToken
$CHAT_ID=$ChatId
New-Item -ItemType Directory -Force -Path $BASE_DIR,$LOG_DIR,$StateDir,$DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'PiNodeMonitorLive\history'), (Join-Path $DataDir 'History\Node') -ErrorAction SilentlyContinue | Out-Null
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
        # Never persist credentials or bearer-like secrets in logs.
        $safe = [string]$Text
        if (-not [string]::IsNullOrWhiteSpace($BOT_TOKEN)) { $safe = $safe.Replace([string]$BOT_TOKEN,'[REDACTED_BOT_TOKEN]') }
        if (-not [string]::IsNullOrWhiteSpace($GeminiApiKey)) { $safe = $safe.Replace([string]$GeminiApiKey,'[REDACTED_GEMINI_KEY]') }
        $safe = $safe -replace '(?i)(bot[0-9]{6,}:[A-Za-z0-9_-]{20,})','[REDACTED_BOT_TOKEN]'
        $safe = $safe -replace '(?i)(AQ\.[A-Za-z0-9_-]{20,})','[REDACTED_GEMINI_KEY]'
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $safe"
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
$script:PendingCleanRam = $false
$script:PendingCleanRamAt = $null
$script:PendingReset = $false
$script:PendingResetAt = $null
$script:PendingShell = $false
$script:PendingShellAt = $null
$script:PendingShellType = $null
$script:PendingShellCommand = $null
$script:PendingStopController = $false
$script:PendingStopControllerAt = $null
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

function Get-MainKeyboardJson {
    # JSON san cho Telegram (tranh ConvertTo-Json PS5.1 lam vo mang long nhau)
    return '{"inline_keyboard":[[{"text":"📊 Status","callback_data":"/status"},{"text":"📷 Capture","callback_data":"/screenshot"}],[{"text":"📡 Node","callback_data":"/node"},{"text":"🔗 Peers","callback_data":"/peers"},{"text":"📈 Report","callback_data":"/report"}],[{"text":"🐳 Docker","callback_data":"/docker"},{"text":"💽 Disk","callback_data":"/disk"},{"text":"📜 Logs","callback_data":"/logs"}],[{"text":"🛠️ Diagnostic","callback_data":"/diagnostic"},{"text":"⚙️ Settings","callback_data":"/settings"}],[{"text":"❓ Help","callback_data":"/help"},{"text":"🛑 Tắt Controller","callback_data":"/stopcontroller"}]]}'
}

function Send-Text {
    param(
        [string]$Text,
        [switch]$Remember,
        [switch]$WithKeyboard,
        [object]$Keyboard
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($Text.Length -gt 3900) { $Text = $Text.Substring(0,3890) + "`n...[rut gon]" }
    if ($WithKeyboard -or $Keyboard) {
        $kbJson = if ($Keyboard) {
            if ($Keyboard -is [string]) { $Keyboard } else { ($Keyboard | ConvertTo-Json -Compress -Depth 12) }
        } else { Get-MainKeyboardJson }
        # Ghep JSON thu cong de reply_markup la object hop le
        $esc = ($Text -replace '\\','\\' -replace '"','\"' -replace "`n",'\n' -replace "`r",'')
        $payload = "{`"chat_id`":`"$CHAT_ID`",`"text`":`"$esc`",`"disable_web_page_preview`":true,`"reply_markup`":$kbJson}"
        try {
            $uri = "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $REQUEST_TIMEOUT | Out-Null
        } catch {
            Write-Log "Send-Text keyboard loi: $($_.Exception.Message)"
            Invoke-Telegram 'sendMessage' @{ chat_id=$CHAT_ID; text=$Text; disable_web_page_preview='true' } | Out-Null
        }
    } else {
        Invoke-Telegram 'sendMessage' @{ chat_id=$CHAT_ID; text=$Text; disable_web_page_preview='true' } | Out-Null
    }
    if ($Remember -or $script:RememberReply) {
        try {
            $intent = if ($script:LastChatIntent) { [string]$script:LastChatIntent } else { '' }
            $src = if ($script:LastChatSource) { [string]$script:LastChatSource } else { 'reply' }
            if ($Text -notmatch '^📩 Đã nhận yêu cầu') {
                Add-ChatTurn -Role 'assistant' -Text $Text -Intent $intent -Source $src
            }
        } catch {}
        $script:RememberReply = $false
    }
}

function Answer-CallbackQuery {
    param([string]$Id, [string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    $body = @{ callback_query_id = $Id }
    if ($Text) { $body.text = $Text; $body.show_alert = $false }
    Invoke-Telegram 'answerCallbackQuery' $body | Out-Null
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

function Get-PiWindowCaptureBounds {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PiWinCapture {
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
 public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
 public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@ -ErrorAction SilentlyContinue
    $hits = New-Object System.Collections.Generic.List[object]
    $keywords = @('PiCheck','Pi Network','Pi Node','Pi Desktop')
    $cb = [PiWinCapture+EnumWindowsProc]{ param($h,$l)
        if(-not [PiWinCapture]::IsWindowVisible($h)){return $true}
        $sb=New-Object Text.StringBuilder 512; [void][PiWinCapture]::GetWindowText($h,$sb,$sb.Capacity)
        $title=$sb.ToString(); if([string]::IsNullOrWhiteSpace($title)){return $true}
        foreach($k in $keywords){ if($title -like "*$k*"){ $r=New-Object PiWinCapture+RECT; if([PiWinCapture]::GetWindowRect($h,[ref]$r)){ $w=$r.Right-$r.Left; $hgt=$r.Bottom-$r.Top; if($w -gt 300 -and $hgt -gt 200){ [void]$hits.Add([pscustomobject]@{Title=$title;Left=$r.Left;Top=$r.Top;Width=$w;Height=$hgt;Score=($k.Length*10000)+($w*$hgt)}) } } break } }
        return $true
    }
    [void][PiWinCapture]::EnumWindows($cb,[IntPtr]::Zero)
    return ($hits | Sort-Object Score -Descending | Select-Object -First 1)
}

function Invoke-Screenshot {
    param([switch]$Silent,[switch]$AnalyzeWithAI)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $env:TEMP ("PiNode_Screenshot_{0}_{1}.png" -f $PID,$stamp)
    $source='Desktop fallback'
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $win=Get-PiWindowCaptureBounds
        if($win){
            $bmp=New-Object System.Drawing.Bitmap $win.Width,$win.Height
            $g=[System.Drawing.Graphics]::FromImage($bmp)
            try{$g.CopyFromScreen($win.Left,$win.Top,0,0,$bmp.Size,[System.Drawing.CopyPixelOperation]::SourceCopy)}finally{$g.Dispose()}
            try{$bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)}finally{$bmp.Dispose()}
            $source="Cửa sổ Pi: $($win.Title)"
        } else {
            $vs=[System.Windows.Forms.SystemInformation]::VirtualScreen
            $bmp=New-Object System.Drawing.Bitmap $vs.Width,$vs.Height
            $g=[System.Drawing.Graphics]::FromImage($bmp)
            try{$g.CopyFromScreen($vs.Left,$vs.Top,0,0,$bmp.Size,[System.Drawing.CopyPixelOperation]::SourceCopy)}finally{$g.Dispose()}
            try{$bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)}finally{$bmp.Dispose()}
        }
        if(!(Test-Path -LiteralPath $path)){throw 'Không tạo được ảnh.'}
        $caption="📷 Pi Node Telegram Controller PRO`n🕐 $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
        $ok=Send-Photo -Path $path -Caption $caption
        if(-not $ok){throw 'Telegram không nhận được ảnh.'}
        if($AnalyzeWithAI){
            $analysis=Invoke-GeminiVisionOnImage -ImagePath $path -Source $source
            if($analysis){Send-Text $analysis}
        }
        return $true
    }catch{
        Write-Log "Smart Capture lỗi: $($_.Exception.Message)"
        if(-not $Silent){Send-Text "⚠️ Không chụp được Pi Desktop.`nHệ thống đã thử cửa sổ Pi trước rồi mới dùng toàn màn hình.`nLý do: $($_.Exception.Message)"}
        return $false
    }finally{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
}

function Invoke-GeminiVisionOnImage {
    param([string]$ImagePath,[string]$Source='Pi Desktop')
    if([string]::IsNullOrWhiteSpace($GeminiApiKey) -or !(Test-Path $ImagePath)){return $null}
    try{
        $bytes=[IO.File]::ReadAllBytes($ImagePath); $b64=[Convert]::ToBase64String($bytes)
        $latest=Get-LiveLatestPath; $evidence='{}'
        if($latest){try{$evidence=Get-Content $latest -Raw -Encoding UTF8}catch{}}
        $prompt=@"
Bạn là bộ phận xác minh sự cố Pi Node. Ảnh là $Source.
Nguồn sự thật chính là Live Data JSON bên dưới. Không được tự đoán số liệu không nhìn thấy.
Hãy đọc các thông tin Pi Desktop nhìn thấy trong ảnh, đối chiếu với Live Data, và trả lời ngắn gọn theo cấu trúc:
1) Ảnh cho thấy gì?
2) Có khớp Live Data không?
3) Nếu lệch, điểm nào lệch và mức độ chắc chắn?
4) Người dùng nên làm gì tiếp theo?
Nếu ảnh không đủ rõ, nói rõ "chưa đủ bằng chứng". Không được tự ý yêu cầu reset nếu chưa có bằng chứng.
LIVE DATA:
$evidence
"@
        foreach($model in @($GeminiModels)){
            try{
                $uri="https://generativelanguage.googleapis.com/v1beta/models/$model`:generateContent?key=$GeminiApiKey"
                $body=@{contents=@(@{parts=@(@{text=$prompt},@{inline_data=@{mime_type='image/png';data=$b64}})});generationConfig=@{temperature=0.1;maxOutputTokens=900}}|ConvertTo-Json -Depth 12
                $r=Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 45
                $txt=[string]$r.candidates[0].content.parts[0].text
                if($txt){return "🔎 XÁC MINH ẢNH + LIVE DATA`n━━━━━━━━━━━━━━`n$txt"}
            }catch{Write-Log "Vision model $model lỗi: $($_.Exception.Message)"}
        }
    }catch{Write-Log "Vision lỗi: $($_.Exception.Message)"}
    return $null
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

# ===== User habits / keyword fast-path (bỏ qua AI khi đã quen lệnh) =====
$script:HabitsFile = if ($DataDir) { Join-Path $DataDir 'user_habits.json' } else { Join-Path $AppRoot 'Data\user_habits.json' }

function Get-DefaultHabits {
    return [ordered]@{
        version = 1
        keywords = @()
        corrections = @()
        last_updated = $null
    }
}

function Read-UserHabits {
    $defaults = Get-DefaultHabits
    if (!(Test-Path -LiteralPath $script:HabitsFile)) { return $defaults }
    try {
        $raw = Get-Content -LiteralPath $script:HabitsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = [ordered]@{
            version = 1
            keywords = @()
            corrections = @()
            last_updated = $null
        }
        if ($raw.keywords) { $o.keywords = @($raw.keywords) }
        if ($raw.corrections) { $o.corrections = @($raw.corrections) }
        if ($raw.last_updated) { $o.last_updated = $raw.last_updated }
        return $o
    } catch {
        Write-Log "Read habits loi: $($_.Exception.Message)"
        return $defaults
    }
}

function Save-UserHabits {
    param($Habits)
    try {
        $dir = Split-Path -Parent $script:HabitsFile
        if ($dir -and !(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Habits.last_updated = (Get-Date).ToString('o')
        # Giữ tối đa 200 keyword + 100 correction
        if ($Habits.keywords.Count -gt 200) { $Habits.keywords = @($Habits.keywords | Sort-Object { [int]$_.hits } -Descending | Select-Object -First 200) }
        if ($Habits.corrections.Count -gt 100) { $Habits.corrections = @($Habits.corrections | Select-Object -Last 100) }
        ($Habits | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:HabitsFile -Encoding UTF8
    } catch {
        Write-Log "Save habits loi: $($_.Exception.Message)"
    }
}

function Normalize-HabitKey {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.ToLowerInvariant().Trim()
    $t = $t -replace '\s+', ' '
    if ($t.Length -gt 120) { $t = $t.Substring(0, 120) }
    return $t
}

function Resolve-HabitIntent {
    param([string]$Question)
    $key = Normalize-HabitKey $Question
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }
    $h = Read-UserHabits
    # 1) Exact keyword match với hits >= 2
    $exact = @($h.keywords | Where-Object { $_.key -eq $key -and [int]$_.hits -ge 2 } | Sort-Object { [int]$_.hits } -Descending | Select-Object -First 1)
    if ($exact) { return [string]$exact[0].intent }
    # 2) Contains match (key ngắn nằm trong câu hỏi) hits >= 3
    $contains = @($h.keywords | Where-Object {
        $k = [string]$_.key
        $k.Length -ge 6 -and $key.Contains($k) -and [int]$_.hits -ge 3
    } | Sort-Object { [int]$_.hits } -Descending | Select-Object -First 1)
    if ($contains) { return [string]$contains[0].intent }
    return $null
}

function Record-HabitSuccess {
    param(
        [string]$Question,
        [string]$Intent
    )
    if ([string]::IsNullOrWhiteSpace($Question) -or [string]::IsNullOrWhiteSpace($Intent)) { return }
    if ($Intent -in @('UNKNOWN','NATURAL','')) { return }
    $key = Normalize-HabitKey $Question
    if ($key.Length -lt 3) { return }
    try {
        $h = Read-UserHabits
        $found = $false
        $newList = @()
        foreach ($item in @($h.keywords)) {
            if ([string]$item.key -eq $key) {
                $hits = 1
                try { $hits = [int]$item.hits + 1 } catch { $hits = 1 }
                $newList += [pscustomobject]@{ key = $key; intent = $Intent; hits = $hits; last = (Get-Date).ToString('o') }
                $found = $true
            } else {
                $newList += $item
            }
        }
        if (-not $found) {
            $newList += [pscustomobject]@{ key = $key; intent = $Intent; hits = 1; last = (Get-Date).ToString('o') }
        }
        $h.keywords = $newList
        Save-UserHabits $h
    } catch {
        Write-Log "Record-HabitSuccess loi: $($_.Exception.Message)"
    }
}

function Record-HabitCorrection {
    param(
        [string]$PreviousText,
        [string]$CurrentText,
        [string]$ResolvedIntent
    )
    # Khi user phải nói lại / làm rõ → lưu cặp (câu trước → intent đúng) để lần sau nhanh hơn
    if ([string]::IsNullOrWhiteSpace($CurrentText) -or [string]::IsNullOrWhiteSpace($ResolvedIntent)) { return }
    try {
        $h = Read-UserHabits
        $h.corrections = @($h.corrections) + @([pscustomobject]@{
            prev = Normalize-HabitKey $PreviousText
            text = Normalize-HabitKey $CurrentText
            intent = $ResolvedIntent
            time = (Get-Date).ToString('o')
        })
        # Học luôn keyword từ câu làm rõ
        Record-HabitSuccess -Question $CurrentText -Intent $ResolvedIntent
        Save-UserHabits $h
    } catch {}
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


# ===== USER PREFERENCES (phong cách trả lời theo từng khách) =====
$USER_PREFS_FILE = Join-Path $StateDir 'user_preferences.json'


function Get-ContainerNameSetting {
    $prefs = Read-UserPreferences
    if ($prefs.containerName -and [string]$prefs.containerName -ne '') { return [string]$prefs.containerName }
    $cf = Join-Path $DataDir 'PiNodeMonitorLive\container_name.txt'
    if (Test-Path -LiteralPath $cf) {
        $n = (Get-Content -LiteralPath $cf -Raw -EA SilentlyContinue).Trim()
        if ($n) { return $n }
    }
    if ($PiContainerName) { return [string]$PiContainerName }
    return 'testnet2'
}

function Set-ContainerNameSetting {
    param([string]$Name)
    $Name = $Name.Trim()
    $prefs = Read-UserPreferences
    $prefs.containerName = $Name
    Save-UserPreferences $prefs | Out-Null
    $dir = Join-Path $DataDir 'PiNodeMonitorLive'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'container_name.txt') -Value $Name -Encoding ASCII
}

function Test-AlertAllowed {
    $prefs = Read-UserPreferences
    $mode = [string]$prefs.alertMode
    if ($mode -eq 'off') { return $false }
    if ($mode -eq 'night') {
        $h = [int](Get-Date).Hour
        # Quiet 22:00 - 07:00 local
        if ($h -ge 22 -or $h -lt 7) { return $false }
    }
    return $true
}


function Get-DefaultUserPreferences {
    return [ordered]@{
        style = 'balanced'
        language = 'vi'
        showTips = $true
        verboseNumbers = $false
        alertMode = 'on'
        containerName = ''
        updatedAt = (Get-Date).ToString('o')
    }
}

function Read-UserPreferences {
    $d = Get-DefaultUserPreferences
    if (!(Test-Path -LiteralPath $USER_PREFS_FILE)) { return $d }
    try {
        $raw = Get-Content -LiteralPath $USER_PREFS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @('style','language','showTips','verboseNumbers','alertMode','containerName')) {
            if ($null -ne $raw.PSObject.Properties[$k]) { $d[$k] = $raw.$k }
        }
        $d.style = ([string]$d.style).ToLowerInvariant()
        if ($d.style -notin @('simple','balanced','numeric')) { $d.style = 'balanced' }
        $d.showTips = [bool]$d.showTips
        $d.verboseNumbers = [bool]$d.verboseNumbers
        if (-not $d.alertMode) { $d.alertMode = 'on' }
        $d.alertMode = ([string]$d.alertMode).ToLowerInvariant()
        if ($d.alertMode -notin @('on','off','night')) { $d.alertMode = 'on' }
        if ($null -eq $d.containerName) { $d.containerName = '' }
        return $d
    } catch { return (Get-DefaultUserPreferences) }
}

function Save-UserPreferences($prefs) {
    try {
        $prefs.updatedAt = (Get-Date).ToString('o')
        ($prefs | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $USER_PREFS_FILE -Encoding UTF8
        return $true
    } catch { Write-Log "Save user prefs loi: $($_.Exception.Message)"; return $false }
}

function Get-StyleInstruction {
    $p = Read-UserPreferences
    switch ($p.style) {
        'simple' {
            return @"
PHONG CÁCH TRẢ LỜI (SIMPLE — khách thích dễ hiểu):
- Nói như kỹ thuật viên tận tâm giải thích cho người không chuyên.
- Tránh dồn số liệu thô. Mỗi con số phải kèm 1 câu ý nghĩa (ổn / cần theo dõi / nên xử lý).
- Ưu tiên: tình trạng máy → vì sao → nên làm gì (nếu cần).
- Câu ngắn, không jargon. Không liệt kê bảng số dài.
"@
        }
        'numeric' {
            return @"
PHONG CÁCH TRẢ LỜI (NUMERIC — khách thích số liệu):
- Ưu tiên số liệu: min / max / trung bình / trung vị / số mẫu / khoảng thời gian.
- Kết luận ngắn sau mỗi nhóm chỉ số.
- Vẫn phải có 1 dòng đánh giá thực trạng và 1–2 đề xuất cụ thể nếu cần.
- Không bỏ qua kết luận chỉ vì đã có số.
"@
        }
        default {
            return @"
PHONG CÁCH TRẢ LỜI (BALANCED — mặc định chuyên nghiệp):
- Kết hợp số liệu quan trọng + giải thích ngắn + đánh giá thực trạng.
- Cấu trúc: Kết luận → Chỉ số then chốt → Xu hướng (nếu có) → Việc nên làm / lưu ý.
- Không dump toàn bộ số thô; chọn số có ý nghĩa vận hành Node.
"@
        }
    }
}

function Get-InsightLine {
    param($x)
    # Sinh 1–2 dòng nhận định vận hành từ bản ghi history mới nhất
    $tips = @()
    $sync = [string]$x.sync
    $docker = [string]$x.docker
    $port = [string]$x.port
    $ram = $null; $cpu = $null; $temp = $null
    try { $ram = [double]$x.ram_sys } catch {}
    try { $cpu = [double]$x.cpu_sys } catch {}
    try {
        if ("$($x.temp)" -notin @('','N/A','0') ) { $temp = [double]$x.temp }
    } catch {}

    if ($sync -eq 'Dong bo tot' -and $docker -eq 'RUNNING' -and $port -eq 'OPEN') {
        $tips += 'Node đang vận hành ổn: đồng bộ tốt, Docker chạy, cổng mở.'
    } elseif ($port -eq 'CLOSED') {
        $tips += 'Cổng Node đang đóng — kiểm tra firewall/router hoặc container Node.'
    } elseif ($docker -ne 'RUNNING') {
        $tips += 'Docker không chạy — Node và các dịch vụ container sẽ dừng theo.'
    } elseif ($sync -in @('Lech khoi','Chua dong bo')) {
        $tips += 'Khối chưa khớp — theo dõi thêm vài chu kỳ; nếu kéo dài hãy /diagnostic.'
    }

    if ($null -ne $ram -and $ram -ge 88) { $tips += "RAM cao ($ram%) — có thể /cleanram nếu máy chậm." }
    elseif ($null -ne $ram -and $ram -ge 75) { $tips += "RAM $ram% — mức khá cao, theo dõi nếu mở nhiều app." }

    if ($null -ne $cpu -and $cpu -ge 90) { $tips += "CPU cao ($cpu%) — kiểm tra process hoặc container nặng." }
    if ($null -ne $temp -and $temp -ge 78) { $tips += "Nhiệt $temp°C — kiểm tra tản nhiệt/quạt, tránh đặt máy kín." }
    elseif ($null -ne $temp -and $temp -ge 70) { $tips += "Nhiệt $temp°C — chấp nhận được khi tải, vẫn nên thông thoáng." }

    $crit = 0
    try { $crit = [int]$x.critical } catch {}
    if ($crit -gt 0) { $tips += "Có $crit sự cố nghiêm trọng được ghi nhận ở lần quét gần nhất." }

    if ($tips.Count -eq 0) { $tips += 'Chưa đủ tín hiệu bất thường để đưa nhận định thêm.' }
    return ($tips | Select-Object -First 3) -join ' '
}

function Get-NodeHistory {

    # Single history source: Data\PiNodeMonitorLive\history\YYYY-MM-DD.ndjson (raw 7 days).

    $dir = Join-Path $DataDir 'PiNodeMonitorLive\history'

    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    

    try {

        # Chỉ lọc lấy file có đuôi .ndjson và bỏ qua các file ẩn/system như .gitkeep

        $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | 

                 Where-Object { $_.Extension -eq '.ndjson' -and -not $_.Name.StartsWith('.') } | 

                 Sort-Object Name



        if (-not $files) { return @() }



        $out = [System.Collections.Generic.List[PSObject]]::new()



        foreach ($f in $files) {

            $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue

            if (-not $lines) { continue }



            foreach ($line in $lines) {

                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                try {

                    $o = $line | ConvertFrom-Json -ErrorAction SilentlyContinue

                    if ($null -ne $o) {

                        $out.Add($o)

                    }

                } catch {}

            }

        }



        if ($out.Count -gt 5000) {

            return @($out | Select-Object -Last 5000)

        }

        return $out.ToArray()

    } catch {

        Write-Log "Không đọc được NDJSON history: $($_.Exception.Message)"

        return @()

    }

}



function To-Num($v) {
    try { return [double]$v } catch { return $null }
}

function Get-NodeStatus {
    $x = $null
    $latestPath = Join-Path $DataDir 'PiNodeMonitorLive\latest.json'
    if (Test-Path -LiteralPath $latestPath) {
        try { $x = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if (-not $x) {
        $h = @(Get-NodeHistory)
        if ($h.Count -eq 0) {
            return "⚠️ Chưa có dữ liệu live.`n👉 Hãy chạy Start_Controller.bat (Live data sẽ tự bật).`nSau vài phút gửi lại /status.`nNếu Docker lỗi tên container: /settings container testnet2"
        }
        $x = $h[-1]
    }
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

    $prefs = Read-UserPreferences
    $style = [string]$prefs.style
    $syncShow = if ($sync -eq 'Dong bo tot') { 'Đồng bộ tốt' } elseif ($sync -eq 'Dang dong bo') { 'Đang đồng bộ' } elseif ($sync -eq 'Chua dong bo' -or $sync -eq 'Lech khoi') { 'Chưa đồng bộ' } else { $sync }
    $insight = Get-InsightLine $x

    if ($style -eq 'simple') {
        $t = "$head`n"
        $t += "──────────────`n"
        $t += "🕐 Cập nhật: $time`n`n"
        $t += "📌 Tình trạng:`n$insight`n`n"
        $t += "Chi tiết nhanh:`n"
        $t += "• Đồng bộ: $syncShow $sI`n"
        $t += "• Docker: $($x.docker) $dI  ·  Cổng: $($x.port) $pI`n"
        if ($temp -ne '—') { $t += "• Máy: RAM $($x.ram_sys)% · CPU $($x.cpu_sys)% · Nhiệt $temp°C`n" }
        else { $t += "• Máy: RAM $($x.ram_sys)% · CPU $($x.cpu_sys)%`n" }
        if ($critical -gt 0) { $t += "`n🚨 Cần xử lý: $critical sự cố nghiêm trọng. Gửi /diagnostic để xem chi tiết." }
        elseif ($prefs.showTips -and $good) { $t += "`n💡 Máy đang ổn — không cần thao tác thêm." }
        return $t.TrimEnd()
    }

    if ($style -eq 'numeric') {
        $t = "$head`n"
        $t += "──────────────`n"
        $t += "time=$time | severity=$severity | critical=$critical | problems=$problem`n"
        $t += "sync=$sync | local=$($x.local) | latest=$($x.latest)`n"
        $t += "docker=$($x.docker) | port=$($x.port)`n"
        $t += "ram=$($x.ram_sys)% | cpu=$($x.cpu_sys)% | temp=$temp`n"
        if ($null -ne $x.incoming -or $null -ne $x.outgoing) {
            $t += "incoming=$($x.incoming) | outgoing=$($x.outgoing)`n"
        }
        $t += "──────────────`n"
        $t += "insight: $insight"
        return $t
    }

    # balanced (default) — form dong bo, de doc
    $inVal = if ($null -ne $x.incoming) { $x.incoming } elseif ($null -ne $x.peer_in) { $x.peer_in } else { '—' }
    $outVal = if ($null -ne $x.outgoing) { $x.outgoing } elseif ($null -ne $x.peer_out) { $x.peer_out } else { '—' }
    $ledger = if ($null -ne $x.local -and "$($x.local)" -ne '') { $x.local } else { '—' }
    $age = if ($null -ne $x.ledger_age -and "$($x.ledger_age)" -ne '') { "$($x.ledger_age)s" } else { '—' }
    $ram = if ($null -ne $x.ram_sys) { "$($x.ram_sys)%" } else { '—' }
    $cpu = if ($null -ne $x.cpu_sys) { "$($x.cpu_sys)%" } else { '—' }
    $ctn = if ($x.pi_container) { $x.pi_container } else { '—' }

    $t = "$head`n"
    $t += "━━━━━━━━━━━━━━━━`n"
    $t += "🕐  $time`n"
    $t += "━━━━━━━━━━━━━━━━`n"
    $t += "$sI  Đồng bộ     $syncShow`n"
    $t += "📦  Ledger      $ledger   · age $age`n"
    $t += "🔗  Peer        In $inVal  /  Out $outVal`n"
    $t += "🐳  Docker      $($x.docker) $dI`n"
    $t += "🔌  Cổng        $($x.port) $pI`n"
    $t += "📦  Container   $ctn`n"
    $t += "━━━━━━━━━━━━━━━━`n"
    $t += "🧠  RAM $ram   ⚙️ CPU $cpu   🌡️ $temp°C`n"
    if ($null -ne $x.quorum_phase -and "$($x.quorum_phase)" -ne '') {
        $t += "🗳️  Quorum      $($x.quorum_phase)`n"
    }
    if ($critical -gt 0) {
        $t += "━━━━━━━━━━━━━━━━`n"
        $t += "🚨  Sự cố ($critical)`n"
        try {
            if ($x.critical_list) {
                foreach ($c in (@($x.critical_list) | Select-Object -First 5)) { $t += "   • $c`n" }
            }
        } catch {}
    }
    elseif ($severity -eq 'WARNING' -and $problem -gt 0) {
        $t += "━━━━━━━━━━━━━━━━`n"
        $t += "⚠️  Cảnh báo ($problem)`n"
        try {
            if ($x.warning_list) {
                foreach ($w in (@($x.warning_list) | Select-Object -First 4)) { $t += "   • $w`n" }
            }
        } catch {}
    }
    $t += "━━━━━━━━━━━━━━━━`n"
    $t += "💬  $insight`n"
    if ($prefs.showTips -and -not $good -and $critical -eq 0) {
        $t += "👉  /diagnostic nếu cần phân tích sâu`n"
    }
    $ageTxt = ''
    try {
        if ($x.time) {
            $ageS = [math]::Round(((Get-Date) - [datetime]$x.time).TotalSeconds, 0)
            if ($ageS -ge 0) { $ageTxt = "`n⏱ Dữ liệu: $ageS giây trước" }
        }
    } catch {}
    $t += "📡 Pi Node Telegram Controller PRO$ageTxt"
    return $t.TrimEnd()
}

function Get-NodeReport {
    param([int]$Days = 1)
    if ($Days -lt 1) { $Days = 1 }
    # Dùng Get-HistoryRows: NDJSON 7 ngày + archive History\Node (nếu có) — cùng nguồn với STATISTICS/AI
    $day = @(Get-HistoryRows -Days $Days)
    if ($day.Count -eq 0) {
        $h = @(Get-NodeHistory)
        if ($h.Count -eq 0) {
            return "⚠️ Chưa có dữ liệu history.`n👉 Hãy dùng /status để đọc dữ liệu hiện tại; /monitor chỉ dùng khi cần xác minh bằng ảnh + AI."
        }
        return "⚠️ Không có dữ liệu trong $Days ngày vừa qua.`n👉 Hãy để Live Data chạy ổn định; /monitor chỉ dùng khi cần xác minh bằng ảnh + AI."
    }

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

    $prefs = Read-UserPreferences
    $style = [string]$prefs.style
    $syncRate = if ($day.Count) { [math]::Round(100.0 * $syncOk / $day.Count, 0) } else { 0 }
    $avgRam = if ($rams.Count) { [math]::Round(($rams|Measure-Object -Average).Average,1) } else { $null }
    $avgTemp = if ($temps.Count) { [math]::Round(($temps|Measure-Object -Average).Average,1) } else { $null }

    if ($style -eq 'simple') {
        $t = "$head`n──────────────`n"
        $t += "Trong $Days ngày qua bot đã quét $($day.Count) lần.`n`n"
        if ($ok) {
            $t += "📌 Thực trạng: Node vận hành ổn định — đồng bộ, Docker và cổng đều tốt gần như toàn bộ thời gian.`n"
        } else {
            $t += "📌 Thực trạng: Có lúc cần theo dõi (đồng bộ tốt $syncRate% các lần quét"
            if ($problems -gt 0) { $t += ", $problems lần ghi nhận vấn đề" }
            $t += ").`n"
        }
        if ($null -ne $avgTemp) { $t += "Nhiệt độ dao động $tempText (TB ~$avgTemp°C).`n" }
        if ($null -ne $avgRam) { $t += "RAM phổ biến quanh $avgRam% (khoảng $ramText).`n" }
        if ($ok) { $t += "`n💡 Không cần thao tác thêm. Giữ lịch /scheduler để bot tiếp tục canh." }
        else { $t += "`n💡 Nên /diagnostic nếu vấn đề lặp lại, hoặc /monitor để xem trạng thái hiện tại." }
        return $t.TrimEnd()
    }

    if ($style -eq 'numeric') {
        $t = "$head`n"
        $t += "period_days=$Days samples=$($day.Count) problem_runs=$problems`n"
        $t += "sync_ok=$syncOk/$($day.Count) ($syncRate%) docker_ok=$dockerOk/$($day.Count) port_ok=$portOk/$($day.Count)`n"
        $t += "ram=$ramText"
        if ($null -ne $avgRam) { $t += " avg=$avgRam" }
        $t += "`ncpu=$cpuText`n"
        $t += "temp=$tempText"
        if ($null -ne $avgTemp) { $t += " avg=$avgTemp" }
        $t += "`n"
        $t += "verdict=" + $(if ($ok) { 'STABLE' } else { 'WATCH' })
        return $t
    }

    $t = "$head`n"
    $t += "━━━━━━━━━━━━━━━━━━`n"
    $t += "📅  Khoảng thời gian · $Days ngày`n"
    $t += "📋  Lần quét · $($day.Count)`n"
    $t += "✅  Đồng bộ · $syncOk/$($day.Count) ($syncRate%)`n"
    $t += "🐳  Docker · $dockerOk/$($day.Count)`n"
    $t += "🔌  Cổng · $portOk/$($day.Count)`n"
    $t += "🧠  RAM · $ramText"
    if ($null -ne $avgRam) { $t += " · TB $avgRam%" }
    $t += "`n⚙️  CPU · $cpuText`n"
    $t += "🌡️  Nhiệt độ · $tempText"
    if ($null -ne $avgTemp) { $t += " · TB $avgTemp°C" }
    $t += "`n⚠️  Lần có vấn đề · $problems`n"
    if ($ok) { $t += "`n💡 Kết luận: Pi Node hoạt động ổn định trong khoảng thời gian đã chọn. Tiếp tục để bot canh 24/7." }
    else { $t += "`n💡 Kết luận: Có chỉ số bất thường. Chạy /monitor hoặc /diagnostic để khoanh vùng; không vội reset nếu chỉ cảnh báo tài nguyên." }
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
    $cut=(Get-Date).AddDays(-[math]::Max(1,$Days)); $rows=@()
    try{$rows += @(Get-NodeHistory)}catch{}
    if(Test-Path -LiteralPath $HISTORY_ARCHIVE_DIR){
        try{
            $files=Get-ChildItem $HISTORY_ARCHIVE_DIR -Filter 'NodeHistory_*.ndjson' -File -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -ge $cut.AddDays(-1)}
            foreach($f in $files){foreach($line in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)){if($line.Trim()){try{$rows += ($line|ConvertFrom-Json)}catch{}}}}
        }catch{Write-Log "Long history read loi: $($_.Exception.Message)"}
    }
    $uniq=@{}; foreach($r in $rows){try{$t=[datetime]$r.time;if($t -ge $cut){$uniq[[string]$r.time]=$r}}catch{}}
    return @($uniq.Values|Sort-Object {try{[datetime]$_.time}catch{Get-Date}})
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
        $containers = (& docker ps --format '{{.Names}} | {{.Image}} | {{.Status}}' 2>$null)
        $text = "🐳 DOCKER`n`n"
        $configured = Get-ContainerNameSetting
        $text += "Container đang cấu hình: $configured`n"
        $text += "Service: " + $(if ($svc) { $svc.Status } else { 'N/A' }) + "`n"
        $text += "Engine: " + $(if ($docker) { "OK ($docker)" } else { 'Khong truy cap duoc' }) + "`n"
        # Pi container đã nhận diện gần nhất (từ latest/history)
        try {
            $lr = Get-LatestLiveRecord
            if ($lr -and $lr.pi_container) {
                $text += "Pi container (monitor): $($lr.pi_container)`n"
            }
        } catch {}
        if ($containers) {
            $text += "Container đang chạy:`n" + ($containers -join "`n")
            $names = @($containers | ForEach-Object { ($_ -split '\s+\|',2)[0].Trim() })
            if ($configured -and $configured -notin $names) {
                $text += "`n⚠️ Không tìm thấy container đang cấu hình: $configured`n👉 Nếu Pi Node đang chạy với tên khác, dùng /settings container <ten-container> (ví dụ: testnet2)."
            }
        } else {
            $text += "Container đang chạy: Chưa thấy`n"
            $text += "👉 Nếu Pi Node đang chạy, mở docker ps để xem tên container rồi dùng /settings container <ten-container> (ví dụ: testnet2)."
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


function Get-LatestLiveRecord {
    # Ưu tiên latest.json (đồng bộ với /status), fallback mẫu cuối NDJSON history
    $latestPath = Get-LiveLatestPath
    if ($latestPath) {
        try {
            $x = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($x) { return $x }
        } catch { Write-Log "Get-LatestLiveRecord latest.json: $($_.Exception.Message)" }
    }
    $h = @(Get-NodeHistory)
    if ($h.Count -gt 0) { return $h[-1] }
    return $null
}

function Get-LiveNodeDetail {
    # Ưu tiên latest.json (cùng nguồn /status), fallback history — không suy đoán
    $x = Get-LatestLiveRecord
    if (-not $x) {
        return "⚠️ Chưa có dữ liệu live.`n👉 Hãy dùng /status để đọc dữ liệu Live; /monitor chỉ dùng để xác minh bằng ảnh + AI khi cần."
    }
    $time = try { ([datetime]$x.time).ToString('dd/MM HH:mm:ss') } catch { "$($x.time)" }
    $t = "📡 NODE LIVE (stellar-core)`n━━━━━━━━━━━━━━`n"
    $t += "🕐 $time`n"
    $t += "📦 Container: $(if($x.pi_container){$x.pi_container}else{'—'})`n"
    $t += "🔄 Sync: $($x.sync)`n"
    $t += "📒 Ledger: $($x.local)"
    if ($null -ne $x.ledger_age -and "$($x.ledger_age)" -ne '') { $t += " | Age: $($x.ledger_age)s" }
    $t += "`n"
    $t += "🔗 Peer: In $($x.incoming) / Out $($x.outgoing)"
    if ($null -ne $x.peers_auth) { $t += " | Auth: $($x.peers_auth)" }
    $t += "`n"
    if ($x.quorum_phase) { $t += "🗳️ Quorum: $($x.quorum_phase)" }
    if ($null -ne $x.quorum_lag_ms -and "$($x.quorum_lag_ms)" -ne '') { $t += " | Lag: $($x.quorum_lag_ms) ms" }
    $t += "`n"
    if ($x.protocol) { $t += "📐 Protocol: $($x.protocol)`n" }
    if ($x.build) { $t += "🏗️ Build: $($x.build)`n" }
    $t += "🐳 Docker: $($x.docker) | Port: $($x.port)`n"
    $t += "🌡️ Temp: $($x.temp) | RAM: $($x.ram_sys)% | CPU: $($x.cpu_sys)%`n"
    $ageTxt2 = ''
    try {
        if ($x.time) {
            $ageS2 = [math]::Round(((Get-Date) - [datetime]$x.time).TotalSeconds, 0)
            if ($ageS2 -ge 0) { $ageTxt2 = "`n⏱ Dữ liệu: $ageS2 giây trước" }
        }
    } catch {}
    $t += "📡 Pi Node Telegram Controller PRO$ageTxt2`n"
    if ($x.evidence) {
        $t += "━━━━━━━━━━━━━━`n🔎 Bằng chứng:`n"
        try {
            if ($x.evidence -is [System.Collections.IDictionary] -or $x.evidence.PSObject.Properties['Keys']) {
                $n = 0
                foreach ($prop in @($x.evidence.PSObject.Properties)) {
                    if ($n -ge 8) { break }
                    $t += "• $($prop.Name)=$($prop.Value)`n"
                    $n++
                }
            } else {
                foreach ($e in @($x.evidence | Select-Object -First 8)) { $t += "• $e`n" }
            }
        } catch {
            foreach ($e in @($x.evidence | Select-Object -First 8)) { $t += "• $e`n" }
        }
    }
    if ($x.critical_list) {
        $t += "━━━━━━━━━━━━━━`n🚨 Critical:`n"
        foreach ($c in @($x.critical_list | Select-Object -First 6)) { $t += "• $c`n" }
    }
    if ($x.warning_list) {
        $t += "⚠️ Warning:`n"
        foreach ($w in @($x.warning_list | Select-Object -First 6)) { $t += "• $w`n" }
    }
    return $t.TrimEnd()
}

function Get-PeersDetail {
    $h = @(Get-NodeHistory)
    $x = Get-LatestLiveRecord
    if (-not $x) {
        return "⚠️ Chưa có dữ liệu peer.`n👉 Chạy Live Service (Start_Controller) rồi thử lại."
    }
    if ($h.Count -eq 0) { $h = @($x) }
    $t = "🔗 PEERS (đo từ stellar-core)`n━━━━━━━━━━━━━━`n"
    $t += "Incoming:  $($x.incoming)`n"
    $t += "Outgoing:  $($x.outgoing)`n"
    if ($null -ne $x.peers_auth) { $t += "Authenticated: $($x.peers_auth)`n" }
    $t += "`n"
    # Xu hướng so với mẫu trước
    if ($h.Count -ge 2) {
        $p = $h[-2]
        try {
            $pIn = [double]$p.incoming; $pOut = [double]$p.outgoing
            $cIn = [double]$x.incoming; $cOut = [double]$x.outgoing
            $sumP = $pIn + $pOut; $sumC = $cIn + $cOut
            $t += "Xu hướng vs mẫu trước:`n"
            $t += "• In+Out: $sumP → $sumC"
            if ($sumP -gt 0 -and $sumC -lt ($sumP * 0.5)) { $t += " ⚠️ sụt mạnh" }
            elseif ($sumP -eq 0 -and $sumC -ge 2) { $t += " ✅ đang phục hồi" }
            elseif ($sumC -gt $sumP) { $t += " ✅ tăng" }
            $t += "`n"
            $t += "• In: $pIn → $cIn | Out: $pOut → $cOut`n"
        } catch {
            $t += "(Chưa đủ số liệu để so xu hướng)`n"
        }
    }
    $t += "`n💡 Peer In+Out = 0 hoặc sụt >50% thường là tín hiệu sớm Node có vấn đề."
    $ageTxt3 = ''
    try {
        if ($x.time) {
            $ageS3 = [math]::Round(((Get-Date) - [datetime]$x.time).TotalSeconds, 0)
            if ($ageS3 -ge 0) { $ageTxt3 = "`n⏱ Dữ liệu: $ageS3 giây trước" }
        }
    } catch {}
    $t += "`n📡 Pi Node Telegram Controller PRO$ageTxt3"
    return $t
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
- Theo doi Pi Node (stellar-core), Docker, CPU, RAM, o dia, port, nhiet do, peer, ledger, scheduler va lich su node.
- Cho phep dieu khien tu xa cac tac vu an toan va cac tac vu nguy hiem co xac nhan.
- Gemini la lop AI hieu ngon ngu tu nhien; khong tu y chay PowerShell. Controller moi la thanh phan thuc thi.
- Hermes la kenh AI truc tiep cho /ask. Gemini Natural Language duoc dung de hieu tin nhan tu nhien va tra loi cac cau hoi ve app.
- MOI canh bao/phan tich PHAI dua tren so lieu do duoc (node_history). Cam suy doan, cam bia so.
- Thong bao loi phai: van de + rui ro + so do + goi y lenh.
- Thoi quen lenh (user_habits.json): hoc cum tu -> intent, lan sau tra loi nhanh khong can Gemini.
- Peer In+Out = 0 hoac sut >50% so voi mau truoc = tin hieu som Node co van de.

NGUON DU LIEU:
- Smart Monitor v10 doc TRUC TIEP stellar-core (docker exec info/peers), Docker, Win32, port 31401-31403, OpenHardwareMonitorLib.
- KHONG dung OCR/chup man hinh de lay thong so Node.
- Quet mac dinh 5 phut; khi loi quet day 1 phut (toi da 10 lan). Auto-reset toi da 1 lan/ngay.

CAU TRUC:
- Config/PiNode_Config.ps1: cau hinh Telegram BotToken, ChatId, GeminiApiKey, danh sach model Gemini, Hermes container, timeout, nguong canh bao, lich scheduler va duong dan module.
- Controller/PiNode_Telegram_Controller_PRO_v2.0.ps1: bo nao trung tam; nhan Telegram, dieu phoi lenh, scheduler, log, goi module, gui text/photo.
- Data/PiNode_SmartMonitor_v9_CentralConfig.ps1: monitor live (stellar-core + Docker + OHM); ghi history/*.ndjson.
- Data/OpenHardwareMonitorLib.dll: cam bien nhiet (tuy chon).
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
- Data/history/*.ndjson: du lieu lich su monitor (toi da ~2500 mau).

CAI DAT:
1. Giai nen bo app vao thu muc co quyen ghi.
2. Mo Setup_Config.bat hoac chay Setup_Config.ps1.
3. Nhap Telegram Bot Token, Chat ID va Gemini API Key.
4. Kiem tra Check_Installation.bat.
5. Chay Start_Controller.bat.
6. Gui /help, /status va /monitor de kiem tra.
7. Neu muon tu dong khi Windows khoi dong, dung Install_Controller_Task.bat.
8. Can Docker + container Pi Node de monitor doc stellar-core. Nhiet do can OpenHardwareMonitorLib.dll trong Data/.

LENH CHUAN:
/help = menu huong dan
/status = doc trang thai gan nhat tu history/*.ndjson
/monitor = chay Smart Monitor ngay
/monitors = alias /monitor
/report = bao cao 24 gio tu history
/diagnostic = chan doan
/cleanram = don RAM
/evidence = xem bằng chứng dữ liệu live, không dùng ảnh/OCR
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
- "bằng chứng dữ liệu live" -> EVIDENCE
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
    # Cùng nguồn với /report, STATISTICS, AI lịch sử: NDJSON + archive
    $h = @(Get-HistoryRows -Days $Days)
    if($h.Count -eq 0){ return 'KHONG CO NODE_HISTORY.' }
    $sel = @($h | Select-Object -Last $MaxRecords)
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

function Get-EvidenceFooter {
    param([int]$Days=7)
    $rows=@(Get-HistoryRows -Days $Days)
    if($rows.Count -eq 0){return '📎 Bằng chứng: không có dữ liệu trong khoảng yêu cầu.'}
    $last=$rows[-1];$problems=@($rows|Where-Object{try{[int]$_.problems -gt 0}catch{$false}}).Count
    $temps=@($rows|ForEach-Object{To-Num $_.temp}|Where-Object{$null -ne $_})
    $tmax=if($temps.Count){[math]::Round(($temps|Measure-Object -Maximum).Maximum,1)}else{'—'}
    $tavg=if($temps.Count){[math]::Round(($temps|Measure-Object -Average).Average,1)}else{'—'}
    return "📎 Bằng chứng dữ liệu: $($rows.Count) mẫu trong $Days ngày · $problems mẫu có vấn đề · Nhiệt TB/Max $tavg/$tmax°C · Mẫu cuối $($last.time) · Sync=$($last.sync) · Ledger=$($last.local) Age=$($last.ledger_age)s · In/Out=$($last.incoming)/$($last.outgoing) · RAM/CPU=$($last.ram_sys)%/$($last.cpu_sys)% · Docker=$($last.docker) · Port=$($last.port)"
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

DU LIEU THUC TE TU history/*.ndjson:
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

$(Get-StyleInstruction)

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
    return ($answer.Trim() + "`n`n" + (Get-EvidenceFooter -Days $Days))
}

function Invoke-GeminiNaturalLanguage {
    param([Parameter(Mandatory)][string]$Question)
    $periodDays=Get-RequestedPeriodDays -Question $Question
    $historyContext=Get-HistoryContextForAI -Days $periodDays
    $chatCtx=Get-ChatHistoryContext -Turns $CHAT_HISTORY_CONTEXT_TURNS
    $prompt = @"
BAN LA AI ROUTER CUA PI NODE TELEGRAM CONTROLLER PRO.
NHIEM VU: Hieu y dinh tin nhan tieng Viet tu nhien va chon intent.
INTENT: STATUS, MONITOR, SCREENSHOT, SETTINGS, REPORT, STATISTICS, ADVICE, DOCKER, DISK, EVIDENCE, LOGS, SCHEDULER, DIAGNOSTIC, CLEANRAM, MAINTENANCE_CONFIRM, RESET_CONFIRM, HELP, DONATE, ASK_HERMES, KNOWLEDGE, UNKNOWN.

QUY TAC:
- may toi the nao/tinh trang hien tai (KHONG hoi nong/nhiet/RAM/CPU theo thoi gian) => STATUS.
- kiem tra/xac minh su co bang anh, doc Pi Desktop/PiCheck bang anh + AI => MONITOR.
- chup man hinh, chup anh, screenshot, capture => SCREENSHOT.
- cai dat/doi ten container/cau hinh bao dong/phong cach tra loi => SETTINGS.
- cau hoi lich su/bao cao tong quat => REPORT. Cac cau nhu '30 ngay qua may toi co su co gi khong?' phai la REPORT, khong duoc chon STATUS.
- cau hoi nham vao mot chi so cu the (nhiet do, nong, RAM, CPU...) ke ca khi khong noi ro thoi gian => STATISTICS.
  Vi du BAT BUOC la STATISTICS:
  - "Thang nay may toi chay co nong khong?"
  - "30 ngay vua qua may toi chay co nong khong?"
  - "May toi chay co nong khong?"
  - "Tuan nay nhiet do the nao?"
  - "7 ngay qua RAM co cao khong?"
- Cau hoi ve 'su co/loi/bat thuong' trong mot khoang thoi gian ma khong chi ro chi so => REPORT de AI phan tich tong the.
- Docker/container => DOCKER; o C/o dia/dung luong => DISK; bằng chứng live => EVIDENCE.
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
    if ($q -match 'don.*ram|dọn.*ram|giai phong ram|giải phóng ram|ram.*day|ram.*cao|ram.*nang') { return 'CLEANRAM' }
    if ($q -match 'bao tri|bảo trì|maintenance|toi uu may|tối ưu máy') { return 'MAINTENANCE_CONFIRM' }
    if ($q -match 'reset.*(node|mang|mạng)|khoi phuc mang|khôi phục mạng|dat lai node|đặt lại node') { return 'RESET_CONFIRM' }
    if ($q -match 'chup man hinh|chụp màn hình|screenshot|capture|chup anh|chụp ảnh') { return 'SCREENSHOT' }
    if ($q -match 'cai dat|cài đặt|doi ten container|đổi tên container|ten container|tên container|bao dong|báo động|phong cach tra loi|phong cách trả lời') { return 'SETTINGS' }
    if ($q -match 'docker|container') { return 'DOCKER' }
    if ($q -match 'o c|ổ c|o dia|ổ đĩa|dung luong|dung lượng|disk|free space') { return 'DISK' }
    if ($q -match 'bằng chứng|bang chung|evidence|số liệu đo|so lieu do') { return 'EVIDENCE' }
    if ($q -match 'sức khỏe|suc khoe|health|toàn diện|toan dien|tình trạng máy|tinh trang may') { return 'HEALTH' }
    if ($q -match 'lịch sử|lich su|30 ngày|30 ngay|xu hướng|xu huong|trend') { return 'HISTORY' }
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
    if ($q -match 'xác minh.*anh|xac minh.*anh|kiem tra.*bang anh|kiểm tra.*bằng ảnh|doc pi desktop|đọc pi desktop|monitor|kiểm tra ngay|kiem tra ngay|kiem tra node|kiểm tra node|tien hanh|tiến hành|kiem tra nhanh|kiểm tra nhanh') { return 'MONITOR' }
    if ($q -match 'peer|incoming|outgoing|ket noi peer|kết nối peer') { return 'PEERS' }
    if ($q -match 'chi tiet node|chi tiết node|ledger age|quorum|stellar') { return 'NODE' }

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

$(Get-StyleInstruction)

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
    return ($answer.Trim() + "`n`n" + (Get-EvidenceFooter -Days $Days))
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

    $allowed = @('STATUS','MONITOR','SCREENSHOT','SETTINGS','NODE','PEERS','REPORT','STATISTICS','ADVICE','DOCKER','DISK','EVIDENCE','LOGS','SCHEDULER','DIAGNOSTIC','CLEANRAM','MAINTENANCE_CONFIRM','RESET_CONFIRM','HELP','DONATE','ASK_HERMES','KNOWLEDGE','EVIDENCE','HEALTH','HISTORY','TRENDS')
    $first = ''
    $answer = $null
    $fromHabit = $false

    # 1) Habit / keyword fast-path — không gọi AI nếu đã học đủ
    try {
        $habitIntent = Resolve-HabitIntent -Question $Question
        if ($habitIntent -and $habitIntent -in $allowed) {
            $first = $habitIntent
            $fromHabit = $true
            Write-Log "Habit hit intent=$first q=$Question"
        }
    } catch {}

    if ($fromHabit) {
        Send-Text "📩 Đã nhận yêu cầu`n`n📝 $Question`n`n⚡ Nhận diện nhanh (thói quen) → $first"
    } else {
        Send-Text "📩 Đã nhận yêu cầu`n`n📝 $Question`n`n🤖 Tôi đang xác định cách kiểm tra phù hợp...`n⏳ Vui lòng chờ kết quả."
        # 2) Gemini rồi fallback deterministic
        $ai = Invoke-GeminiNaturalLanguage -Question $Question
        if (-not [string]::IsNullOrWhiteSpace($ai)) {
            $lines = $ai -split "`r?`n",2
            $first = $lines[0].Trim().ToUpperInvariant()
            if ($first -eq 'KNOWLEDGE') {
                $answer = if ($lines.Count -gt 1) { $lines[1].Trim() } else { '' }
            }
        }
        if ($first -notin $allowed) {
            $first = Get-NaturalLanguageFallbackIntent -Question $Question
        }
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

    Write-Log "NaturalLanguage intent=$first question=$Question habit=$fromHabit"
    # User turn đã được ghi ở Handle-Message; cập nhật intent chi tiết sau khi phân loại
    $script:LastChatIntent = $first
    $script:LastChatSource = $(if ($fromHabit) { 'habit' } else { 'natural' })
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
            # Nếu user phải nói lại trong <90s (cùng chủ đề) → ghi correction
            if ($recs.Count -ge 2 -and $first -ne 'UNKNOWN') {
                $prevUsers = @($recs | Where-Object { $_.role -eq 'user' } | Select-Object -Last 2)
                if ($prevUsers.Count -eq 2) {
                    try {
                        $t0 = [datetime]$prevUsers[0].time
                        $t1 = [datetime]$prevUsers[1].time
                        if (($t1 - $t0).TotalSeconds -le 90 -and [string]$prevUsers[0].intent -ne $first) {
                            Record-HabitCorrection -PreviousText ([string]$prevUsers[0].text) -CurrentText $Question -ResolvedIntent $first
                        }
                    } catch {}
                }
            }
        }
        if ($first -ne 'UNKNOWN') { Record-HabitSuccess -Question $Question -Intent $first }
    } catch {}
    if ($first -eq 'KNOWLEDGE') {
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = "Tôi có thể hướng dẫn cài đặt, giải thích từng script, chức năng Controller, Monitor, CleanRAM, Maintenance, Diagnostic, Reset, Docker/WSL, Telegram, Gemini và Hermes. Bạn muốn biết phần nào?"
        }
        Send-Text "🤖 AI APP GUIDE`n`n$answer"
        return
    }

    switch ($first) {
        'STATUS' { Send-Text -Text (Get-NodeStatus) -WithKeyboard; break }
        'MONITOR' { Invoke-BackupMonitor; break }
        'SCREENSHOT' { Invoke-Screenshot; break }
        'SETTINGS' { Send-Text (Get-SettingsMenu); break }
        'NODE' { Send-Text (Get-LiveNodeDetail); break }
        'PEERS' { Send-Text (Get-PeersDetail); break }
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
        'EVIDENCE' {
            $x=Get-LatestLiveRecord; if($x){Send-Text (Get-NodeEvidenceMessage -Record $x -Title '📎 PI NODE — BẰNG CHỨNG ĐO ĐƯỢC')} else {Send-Text '⚠️ Chưa có snapshot dữ liệu.'}; break
        }
        'HEALTH' { Send-Text -Text (Get-NodeStatus) -WithKeyboard; break }
        'HISTORY' {
            $days=Get-RequestedPeriodDays -Question $Question
            if($days -lt 7){$days=30}
            $a=Invoke-HistoricalAIAnalysis -Question $Question -Days $days
            if($a){Send-Text $a}else{Send-Text (Get-NodeReport -Days $days)}; break
        }
        'TRENDS' {
            $a=Invoke-HistoricalAIAnalysis -Question $Question -Days 7
            if($a){Send-Text $a}else{Send-Text (Get-NodeReport -Days 7)}; break
        }
        'DOCKER' { Send-Text (Get-DockerStatus); break }
        'DISK' { Send-Text (Get-DiskStatus); break }
        'EVIDENCE' { Invoke-LiveEvidence; break }
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
        'CLEANRAM' {
            $script:PendingCleanRam = $true; $script:PendingCleanRamAt = Get-Date
            Send-Text "🧹 DỌN RAM — XÁC NHẬN`n`nAI hiểu yêu cầu là chạy tác vụ dọn RAM/cache/DNS đã đăng ký.`nGửi /confirmcleanram trong $ConfirmTimeout giây để thực hiện.`nGửi /cancel để hủy."
            break
        }
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
        if (-not (Test-PiNodeSafePath -Path $path -Root $BASE_DIR)) {
            Write-Log "Chan path ngoai AppRoot: $Key"
            Send-Text "🔴 Từ chối đường dẫn không an toàn cho $Key."
            return
        }
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

function Invoke-LiveEvidence {
    $x = Get-LatestLiveRecord
    if (-not $x) { Send-Text '⚠️ Chưa có dữ liệu live. Chạy Live Service (Start_Controller) rồi thử lại.'; return }
    Send-Text (Get-NodeEvidenceMessage -Record $x -Title '📊 PI NODE — BẰNG CHỨNG LIVE')
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


function Get-SettingsMenu {
    $p = Read-UserPreferences
    $styleName = switch ($p.style) {
        'simple'  { 'Đơn giản — dễ hiểu' }
        'numeric' { 'Số liệu — chi tiết số' }
        default   { 'Cân bằng — chuyên nghiệp' }
    }
    $tips = if ($p.showTips) { 'Bật' } else { 'Tắt' }
    $t = @"
⚙️ CÀI ĐẶT TRẢ LỜI & TRẢI NGHIỆM
──────────────
Hiện tại:
• Phong cách: $styleName
• Gợi ý hữu ích: $tips

Chọn phong cách trả lời (gõ lệnh):

1️⃣  /settings style simple
   Phù hợp khi bạn muốn giải thích dễ hiểu, ít số thô.
   Bot nói tình trạng máy → ý nghĩa → việc nên làm.

2️⃣  /settings style balanced
   Mặc định. Có số liệu then chốt + nhận định + gợi ý ngắn.
   Phù hợp vận hành Node hàng ngày.

3️⃣  /settings style numeric
   Ưu tiên min/max/trung bình, mẫu đo, severity.
   Phù hợp khi bạn thích theo dõi số liệu sát.

Khác:
• /settings tips on|off  — bat/tat goi y
• /settings container <ten> — ten container Pi Node (vd: testnet2)
• /settings alert on|off|night — bao dong: bat / tat / tat dem (22h-7h)
• /settings show         — xem cau hinh
• /settings reset        — ve mac dinh

📌 Lịch quét / ngưỡng cảnh báo / tự reset:
   Dùng /scheduler (menu riêng, có giải thích từng tham số).

Các thay đổi có hiệu lực ngay, không cần restart.
"@
    return $t.Trim()
}

function Handle-SettingsCommand {
    param([string]$ArgsText)
    $a = if ($null -eq $ArgsText) { '' } else { $ArgsText.Trim() }
    if ([string]::IsNullOrWhiteSpace($a) -or $a -match '^(show|xem|menu)?$') {
        Send-Text (Get-SettingsMenu)
        return
    }
    $parts = @($a -split '\s+', 3)
    $cmd = $parts[0].ToLowerInvariant()
    $val = if ($parts.Count -gt 1) { $parts[1].Trim().ToLowerInvariant() } else { '' }

    $prefs = Read-UserPreferences
    $msg = ''

    switch -Regex ($cmd) {
        '^(style|phongcach|phong)$' {
            if ($val -notin @('simple','balanced','numeric','de','dễ','so','số')) {
                Send-Text "⚠️ Chọn: simple | balanced | numeric`nVí dụ: /settings style simple"
                return
            }
            if ($val -in @('de','dễ')) { $val = 'simple' }
            if ($val -in @('so','số')) { $val = 'numeric' }
            $prefs.style = $val
            Save-UserPreferences $prefs | Out-Null
            $label = switch ($val) {
                'simple'  { 'Đơn giản — dễ hiểu' }
                'numeric' { 'Số liệu — chi tiết số' }
                default   { 'Cân bằng — chuyên nghiệp' }
            }
            $msg = "✅ Đã chọn phong cách: *$label*`nGửi /status hoặc hỏi tự nhiên để xem khác biệt."
        }
        
        '^(container|ctn|tencontainer)$' {
            $rawName = if ($parts.Count -gt 1) { ($parts[1..($parts.Count-1)] -join ' ').Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($rawName)) {
                $cur = Get-ContainerNameSetting
                Send-Text "Container hien tai: $cur`n`nDat ten: /settings container testnet2`n`nTip: mo CMD go docker ps de xem ten container dang chay."
                return
            }
            Set-ContainerNameSetting $rawName
            Send-Text "✅ Da luu ten container: $rawName`nLive Monitor se dung ten nay o lan quet tiep theo.`nNeu van loi: kiem tra bang lenh docker ps."
            return
        }
        '^(alert|baodong|bao)$' {
            if ($val -notin @('on','off','night','bat','tat','dem')) {
                Send-Text "Chon: /settings alert on|off|night`n• on = luon bao`n• off = tat het`n• night = tat tu 22h den 7h"
                return
            }
            if ($val -in @('bat')) { $val = 'on' }
            if ($val -in @('tat')) { $val = 'off' }
            if ($val -in @('dem')) { $val = 'night' }
            $prefs.alertMode = $val
            Save-UserPreferences $prefs | Out-Null
            $label = switch ($val) { 'off' { 'Tat hoan toan' } 'night' { 'Tat ban dem (22h-7h)' } default { 'Bat' } }
            Send-Text "✅ Bao dong: $label"
            return
        }

        '^(tips|tip|goy|gợi)$' {
            if ($val -match '^(on|bat|bật|1|true)$') {
                $prefs.showTips = $true
                $msg = '✅ Đã BẬT gợi ý hữu ích trong trả lời.'
            } elseif ($val -match '^(off|tat|tắt|0|false)$') {
                $prefs.showTips = $false
                $msg = '⏸️ Đã TẮT gợi ý hữu ích.'
            } else {
                Send-Text '⚠️ Dùng: /settings tips on|off'
                return
            }
            Save-UserPreferences $prefs | Out-Null
        }
        '^(reset|macdinh|mặcđịnh)$' {
            $prefs = Get-DefaultUserPreferences
            Save-UserPreferences $prefs | Out-Null
            $msg = '✅ Đã về mặc định: phong cách cân bằng, gợi ý bật.'
        }
        default {
            Send-Text (Get-SettingsMenu)
            return
        }
    }
    if ($msg) { Send-Text $msg }
}

function Show-Help {
    return @"
🤖  PI NODE CONTROLLER
━━━━━━━━━━━━━━━━
Giám sát • bảo trì • xử lý sự cố Pi Node qua Telegram.

📊  GIÁM SÁT
  /status      Trạng thái nhanh
  /monitor     Xác minh sự cố: ảnh + AI, chỉ dùng dự phòng
  /screenshot  Chụp ảnh Pi Desktop/cửa sổ Node
  /node        Chi tiết + bằng chứng
  /peers       Peer In/Out + xu hướng
  /report      Báo cáo 24h
  /health      Đánh giá sức khỏe
  /evidence    Bằng chứng đo mới nhất
  /history     Lịch sử dài hạn
  /trends      Xu hướng + AI
  /scheduler   Lịch tự động
  /settings    Cài đặt container, báo động, phong cách

🛠️  BẢO TRÌ
  /cleanram → /confirmcleanram · /maintenance → /confirm · /diagnostic
  /reset → /confirmreset · /cancel

🖥️  HỆ THỐNG
  /docker · /disk · /logs · /screenshot · /insights
  /stopcontroller  Tắt Controller (cần /confirmstop)

💬  TIỆN ÍCH
  /ask <câu hỏi> · /help · /donate

━━━━━━━━━━━━━━━━
Cảnh báo chỉ gửi khi lỗi kéo dài ≥75s (chống báo giả).
Auto-Reset chỉ khi lỗi >15 phút + xác nhận (Net/user), tối đa 1 lần/ngày.
Dùng nút bên dưới để xem nhanh.
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
    $script:SchedRescanMinutes = [math]::Max(1, [math]::Min(180, [int]$Settings.problemRescanMinutes))
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

function Read-SchedulerState { if(Test-Path -LiteralPath $SCHED_STATE){try{return Get-Content -LiteralPath $SCHED_STATE -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}; return [pscustomobject]@{nextMonitor=(Get-Date).AddMinutes($MonitorIntervalMinutes).ToString('o');lastReportKey='';lastMaintenanceKey='';problemStreak=0;lastProblemAt='';lastAutoResetKey='';lastAlertAt='';problemStartedAt='';pendingResetConfirm=$false} }

function Save-SchedulerState($s){try{$s|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $SCHED_STATE -Encoding UTF8}catch{Write-Log "Scheduler state save loi: $($_.Exception.Message)"}}
$script:SchedulerState=Read-SchedulerState
function Build-RiskExplanation {
    # Giải thích rủi ro dựa trên sample mới nhất — chỉ dùng số liệu có trong history
    $risks = @()
    try {
        $h = @(Get-NodeHistory)
        if ($h.Count -eq 0) { return @('Chưa có mẫu đo — hãy /monitor') }
        $x = $h[-1]
        if ([string]$x.sync -in @('Chua dong bo','Lech khoi')) {
            $risks += "Mất/chưa đồng bộ ($($x.sync)): Node có thể không nhận thưởng / không đóng góp consensus. Ledger=$($x.local) age=$($x.ledger_age)"
        }
        if ([string]$x.port -eq 'CLOSED') {
            $risks += 'Cổng 31401–31403 không LISTEN: peer ngoài không kết nối được → dễ tụt incoming/outgoing.'
        }
        if ([string]$x.docker -eq 'STOPPED') {
            $risks += 'Docker tắt: container Pi Node không chạy → Node offline hoàn toàn.'
        }
        if ([string]$x.internet -eq 'OFFLINE' -or [string]$x.internet -eq 'ERROR') {
            $risks += "Mạng máy lỗi ($($x.internet)): không đồng bộ được ledger/peer."
        }
        try {
            $inN = [double]$x.incoming; $outN = [double]$x.outgoing
            if ($inN -eq 0 -and $outN -eq 0) {
                $risks += 'Incoming+Outgoing = 0: tín hiệu sớm Node bị cô lập (thường xuất hiện trước khi sync hỏng).'
            }
        } catch {}
        try {
            if ($null -ne $x.ledger_age -and [double]$x.ledger_age -gt 30) {
                $risks += "Ledger age cao ($($x.ledger_age)s): trễ khối — Node theo sau mạng."
            }
        } catch {}
        try {
            if ($x.temp -ne 'N/A' -and [double]$x.temp -ge 78) {
                $risks += "Nhiệt độ $($x.temp)°C: nguy cơ throttle CPU / mất ổn định lâu dài."
            }
        } catch {}
        try {
            if ($x.critical_list) {
                foreach ($c in @($x.critical_list | Select-Object -First 5)) {
                    if ($c -and ($risks -notcontains [string]$c)) { $risks += [string]$c }
                }
            }
        } catch {}
    } catch {}
    if ($risks.Count -eq 0) { $risks += 'Có tín hiệu bất thường — xem chi tiết trạng thái bên dưới (chỉ số đo được).' }
    return $risks
}

function Send-AlertNotice {
    param([string]$Reason)
    if (-not (Test-AlertAllowed)) { Write-Log "Alert suppressed (alertMode)"; return }
    $msg = Get-NodeStatus
    $riskLines = @(Build-RiskExplanation)
    $riskBlock = ($riskLines | ForEach-Object { "• $_" }) -join "`n"
    $full = @"
🚨 CẢNH BÁO NODE
━━━━━━━━━━━━━━
📋 VẤN ĐỀ:
$Reason

⚠️ RỦI RO / TÁC ĐỘNG:
$riskBlock

📊 TRẠNG THÁI ĐO ĐƯỢC:
$msg

🕐 $(Get-Date -Format 'dd/MM HH:mm')
👉 /diagnostic để phân tích sâu · /status xem lại
"@
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

function Get-NodeEvidenceMessage {
    param([Parameter(Mandatory)]$Record,[string]$Title='⚠️ PI NODE — CẢNH BÁO')
    $lines=@($Title,'','🔎 Vấn đề có bằng chứng:')
    foreach($x in @($Record.critical_list)){if($x){$lines += "🔴 $x"}}
    foreach($x in @($Record.warning_list)){if($x){$lines += "🟡 $x"}}
    $lines += ''; $lines += '📊 Dữ liệu đo được:'
    $lines += "• Thời điểm: $($Record.time)"
    $lines += "• Đồng bộ: $($Record.sync) | Ledger: $($Record.local) | Age: $($Record.ledger_age)s"
    $lines += "• Peer: In $($Record.incoming) / Out $($Record.outgoing)"
    if($null -ne $Record.peer_drop_pct){$lines += "• Peer trend: $($Record.peer_drop_pct)% so với mẫu trước"}
    $lines += "• Docker: $($Record.docker) | Container: $($Record.pi_container)"
    $lines += "• Port: $($Record.port) | Internet: $($Record.internet)"
    $lines += "• CPU: $($Record.cpu_sys)% | RAM: $($Record.ram_sys)% | Nhiệt: $($Record.temp)°C"
    if($null -ne $Record.vmmem_gb){$lines += "• VMMEM: $($Record.vmmem_gb) GB"}
    if($Record.vhdx -and $Record.vhdx.largest_gb){$lines += "• Docker VHDX lớn nhất: $($Record.vhdx.largest_gb) GB"}
    $lines += "• Pi Desktop: $($Record.pi_desktop)"; $lines += ''
    $lines += '📎 Nguồn: stellar-core + Docker + Windows/CIM + OpenHardwareMonitorLib (nếu sensor khả dụng).'
    return ($lines -join "`n")
}

function Test-ControllerAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}


function Invoke-BackupMonitor {
    param([switch]$Silent)
    # Backup path: screenshot desktop (Pi Desktop) for human/AI confirmation - does NOT replace live metrics
    if (-not $Silent) {
        Send-Text @"
📷 Che do du phong (anh man hinh)

Dung de doi chieu voi Pi Desktop khi can xac nhan su co.
So lieu Node chinh van lay tu Live data (/status).

Dang chup man hinh...
"@
    }
    try {
        if (Get-Command Invoke-Screenshot -EA SilentlyContinue) {
            Invoke-Screenshot -AnalyzeWithAI
        } elseif (Get-Command Send-Screenshot -EA SilentlyContinue) {
            Send-Screenshot
        } else {
            # fallback: try /screenshot handler path
            $fn = Get-Command -Name 'Capture-Screenshot' -EA SilentlyContinue
            if ($fn) { & $fn }
            else {
                Send-Text "Chup man hinh: dung /screenshot. Live data: /status."
            }
        }
    } catch {
        Send-Text "Khong chup duoc man hinh: $($_.Exception.Message)`nDung /screenshot hoac /status."
    }
}

function Get-LiveLatestPath {
    $p = Join-Path $DataDir 'PiNodeMonitorLive\latest.json'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Invoke-SmartMonitor {
    param([switch]$Silent)
    # Controller CHI DOC du lieu Live Service — khong chay collector, khong load DLL
    $latestPath = Get-LiveLatestPath
    $hist = @(Get-NodeHistory)

    if (-not $latestPath -and $hist.Count -eq 0) {
        $msg = @"
🔴 Chưa có dữ liệu Live Reader.

👉 Chạy cảm biến nền:
   Data\PiNodeMonitorLive_CMD_v2\Run-PiNodeMonitorLive_Service.bat
hoặc: Install_LiveReader_Task.bat

Controller không tự đo — chỉ đọc dữ liệu Live mới nhất và lịch sử NDJSON.
"@
        if ($Silent) { Write-Log 'Live data missing'; Send-AlertNotice $msg.Trim() } else { Send-Text $msg.Trim() }
        return $false
    }

    $last = $null
    $ageSec = $null
    if ($latestPath) {
        try {
            $last = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($last.time) {
                try { $ageSec = [math]::Round(((Get-Date) - [datetime]$last.time).TotalSeconds, 0) } catch {}
            }
        } catch { Write-Log "Doc latest.json loi: $($_.Exception.Message)" }
    }
    if (-not $last -and $hist.Count) { $last = $hist[-1] }
    if (-not $last) {
        $msg = '🔴 Có file dữ liệu nhưng không đọc được.'
        if ($Silent) { Send-AlertNotice $msg } else { Send-Text $msg }
        return $false
    }

    if ($null -ne $ageSec -and $ageSec -gt 180) {
        if (-not $Silent) {
            Send-Text "⚠️ Dữ liệu Live đã cũ ${ageSec}s.`nKiểm tra Live Service (Run-PiNodeMonitorLive_Service.bat)."
        }
        Write-Log "Live data stale age=${ageSec}s"
    }

    $problems = 0
    try { $problems = [int]$last.problems } catch {}
    $severity = 'OK'
    try { if ($last.severity) { $severity = [string]$last.severity } } catch {}

    if ($problems -gt 0 -or $severity -eq 'CRITICAL') {
        if (Get-Command Get-NodeEvidenceMessage -ErrorAction SilentlyContinue) {
            $e = Get-NodeEvidenceMessage -Record $last -Title '🚨 PI NODE — PHÁT HIỆN VẤN ĐỀ'
            if (-not $Silent) { Send-AlertNotice $e }
        } else {
            if (-not $Silent) { Send-Text -Text (Get-NodeStatus) -WithKeyboard }
        }
        Write-Log "Live READ alert problems=$problems severity=$severity"
        return $true
    }

    if (-not $Silent) {
        $extra = if ($null -ne $ageSec) { "`n⏱️ Dữ liệu: ${ageSec}s trước (Live Service)" } else { '' }
        Send-Text -Text ((Get-NodeStatus) + $extra) -WithKeyboard
    } else {
        Write-Log 'Live READ OK (silent)'
    }
    return $true
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
    $t += "🚨 Tự reset: $auto (chỉ khi lỗi liên tục >15 phút + xác nhận)`n"
    $t += "📉 Chuỗi lỗi hiện tại: $($s.problemStreak)`n`n"
    $t += "──────────────`n"
    $t += "📖 Giải thích nhanh:`n"
    $t += "• interval = chu kỳ quét khi máy ổn`n"
    $t += "• rescan = chu kỳ quét lại khi vừa phát hiện lỗi`n"
    $t += "• report = các giờ gửi báo cáo tóm tắt trong ngày`n"
    $t += "• autoreset = chỉ khi lỗi >15 phút liên tục + (mất Net hoặc /confirmreset), tối đa 1 lần/ngày`n"
    $t += "• Cảnh báo: chỉ gửi sau ≥75s lỗi liên tiếp, cooldown 12 phút`n`n"
    $t += "Điều khiển (gõ đúng cú pháp):`n"
    $t += "/scheduler on|off`n"
    $t += "/scheduler interval 59     (5–1440 phút)`n"
    $t += "/scheduler rescan 10`n"
    $t += "/scheduler report 7,18`n"
    $t += "/scheduler maintenance 23:00`n"
    $t += "/scheduler day 0           (0=CN … 6=T7)`n"
    $t += "/scheduler autoreset on|off`n"
    $t += "/scheduler streak 3`n"
    $t += "/scheduler defaults`n`n"
    $t += "👉 Phong cách trả lời (đơn giản/số liệu): /settings"
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
                Send-Text "⚠️ Dùng: /scheduler rescan 10`n(1–180 phút)"
                return
            }
            $n = [int]$val
            if ($n -lt 1 -or $n -gt 180) {
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
        $peerBad = $false
        $ageBad = $false
        $evidenceBits = @()
        if ($hist.Count) {
            $last = $hist[-1]
            try { $problems = [int]$last.problems } catch {}
            try { $critical = [int]$last.critical } catch { $critical = 0 }
            try { $severity = [string]$last.severity } catch { $severity = 'OK' }
            $sync = [string]$last.sync
            $port = [string]$last.port
            $docker = [string]$last.docker
            # Chỉ coi sync xấu khi lệch/chưa đồng bộ rõ ràng
            if ($sync -in @('Lech khoi','Chua dong bo')) { $syncBad = $true; $evidenceBits += "sync=$sync" }
            if ($port -eq 'CLOSED') { $portBad = $true; $evidenceBits += 'port=CLOSED' }
            if ($docker -eq 'STOPPED') { $dockerBad = $true; $evidenceBits += 'docker=STOPPED' }
            try {
                if ($last.internet -eq 'ERROR' -or $last.internet -eq 'OFFLINE') { $netBad = $true; $evidenceBits += "internet=$($last.internet)" }
            } catch {}
            try {
                $inN = [double]$last.incoming; $outN = [double]$last.outgoing
                if ($inN -eq 0 -and $outN -eq 0) { $peerBad = $true; $evidenceBits += 'peers in+out=0' }
                if($null -ne $last.peer_drop_pct -and [double]$last.peer_drop_pct -ge 50){$peerBad=$true;$evidenceBits += "peer_drop=$($last.peer_drop_pct)%"}
            } catch {}
            try {
                if ($null -ne $last.ledger_age -and [double]$last.ledger_age -gt 60) { $ageBad = $true; $evidenceBits += "ledger_age=$($last.ledger_age)" }
            } catch {}
        }

        # Su co THUC: critical severity hoặc port/docker/sync xấu
        $tempBad=$false;$ramBad=$false;$cpuBad=$false
        try{if($null -ne $last.temp -and [double]$last.temp -ge ([double]$TempAlert+10)){$tempBad=$true;$evidenceBits += "temp=$($last.temp)C"}}catch{}
        try{if($null -ne $last.ram_sys -and [double]$last.ram_sys -ge 97){$ramBad=$true;$evidenceBits += "ram=$($last.ram_sys)%"}}catch{}
        try{if($null -ne $last.cpu_sys -and [double]$last.cpu_sys -ge 98){$cpuBad=$true;$evidenceBits += "cpu=$($last.cpu_sys)%"}}catch{}
        $realProblem = ($severity -eq 'CRITICAL' -or $critical -gt 0 -or $syncBad -or $portBad -or $dockerBad -or $netBad -or $peerBad -or $ageBad -or $tempBad -or $ramBad -or $cpuBad)
        # Reset chỉ khi nhiều tín hiệu liên quan, lặp lại đủ streak; tài nguyên đơn lẻ không reset.
        $severeCount = 0
        if ($syncBad) { $severeCount++ }
        if ($portBad) { $severeCount++ }
        if ($dockerBad) { $severeCount++ }
        if ($netBad) { $severeCount++ }
        if ($peerBad) { $severeCount++ }
        if ($ageBad) { $severeCount++ }
        if ($tempBad) { $severeCount++ }
        if ($ramBad) { $severeCount++ }
        if ($cpuBad) { $severeCount++ }
        $resetEligible = (($syncBad -and ($ageBad -or $peerBad -or $portBad -or $dockerBad)) -or ($dockerBad -and ($portBad -or $syncBad)) -or ($portBad -and ($syncBad -or $dockerBad)) -or ($severeCount -ge 3))

        # Quét dày khi lỗi: rescanMin (mặc định 1 phút)
        $maxDense = if($DenseRescanMaxRuns){[int]$DenseRescanMaxRuns}else{10}
        $alertMinDurationSec = 75   # ≥60–90s trước khi báo
        $alertCooldownMin = 12      # cooldown 10–15 phút sau khi đã báo
        $resetMinDurationMin = 15   # lỗi liên tục >15 phút mới xét auto-reset

        if ($realProblem) {
            $streak = $streak + 1
            $script:SchedulerState.problemStreak = $streak
            $script:SchedulerState.lastProblemAt = $now.ToString('o')
            if (-not $script:SchedulerState.problemStartedAt -or [string]$script:SchedulerState.problemStartedAt -eq '') {
                $script:SchedulerState.problemStartedAt = $now.ToString('o')
            }
            $nextRescan = if ($streak -le $maxDense) { $rescanMin } else { [math]::Max($rescanMin, [math]::Min(5, $intervalDefault)) }
            $script:SchedulerState.nextMonitor = $now.AddMinutes($nextRescan).ToString('o')
            Save-SchedulerState $script:SchedulerState

            # Thời gian lỗi liên tục
            $problemDurationSec = 0
            try {
                $started = [datetime]$script:SchedulerState.problemStartedAt
                $problemDurationSec = [math]::Round(($now - $started).TotalSeconds, 0)
            } catch { $problemDurationSec = 0 }

            # Chống báo giả: lần đầu chỉ ghi nhận; chỉ báo khi lỗi lặp liên tiếp và kéo dài đủ lâu
            $lastAlertAgoMin = 9999
            try {
                if ($script:SchedulerState.lastAlertAt) {
                    $lastAlertAgoMin = [math]::Round(($now - [datetime]$script:SchedulerState.lastAlertAt).TotalMinutes, 1)
                }
            } catch {}
            $inCooldown = ($lastAlertAgoMin -lt $alertCooldownMin)
            $shouldNotify = ($streak -ge 2) -and ($problemDurationSec -ge $alertMinDurationSec) -and (-not $inCooldown)
            if ($shouldNotify) {
                $reason = "🚨 Sự cố THỰC (kéo dài ${problemDurationSec}s, streak=$streak, severity=$severity). Quét lại sau $nextRescan phút.`n"
                $reason += "Tín hiệu: Sync=$syncBad | Age=$ageBad | Port=$portBad | Docker=$dockerBad | Net=$netBad | Peer=$peerBad | Temp=$tempBad | RAM=$ramBad | CPU=$cpuBad`n"
                if ($evidenceBits.Count) { $reason += "📎 Bằng chứng: " + ($evidenceBits -join '; ') }
                $reason += "`n📊 Snapshot: Ledger=$($last.local) Age=$($last.ledger_age)s In=$($last.incoming) Out=$($last.outgoing) CPU=$($last.cpu_sys)% RAM=$($last.ram_sys)% Temp=$($last.temp)°C Docker=$($last.docker) Port=$($last.port)"
                Send-AlertNotice $reason
                $script:SchedulerState.lastAlertAt = $now.ToString('o')
                Save-SchedulerState $script:SchedulerState
            } else {
                Write-Log "Problem streak=$streak duration=${problemDurationSec}s (im lang: can >=${alertMinDurationSec}s + streak>=2, cooldown=${alertCooldownMin}p)"
            }

            # Auto-Reset: chỉ khi lỗi liên tục >15 phút + (mất Internet HOẶC user xác nhận /confirmreset) + tối đa 1 lần/ngày
            # Bỏ hoàn toàn cơ chế "đủ 3 lần quét là reset"
            $problemDurationMin = [math]::Round($problemDurationSec / 60.0, 1)
            $hasUserConfirm = $false
            try { $hasUserConfirm = [bool]$script:SchedulerState.pendingResetConfirm } catch {}
            $resetConfirmOk = $netBad -or $hasUserConfirm
            if ($autoReset -and $resetEligible -and $problemDurationMin -ge $resetMinDurationMin -and $resetConfirmOk) {
                $resetKey = $now.ToString('yyyy-MM-dd')
                if ([string]$script:SchedulerState.lastAutoResetKey -ne $resetKey) {
                    $script:SchedulerState.lastAutoResetKey = $resetKey
                    $script:SchedulerState.problemStreak = 0
                    $script:SchedulerState.problemStartedAt = ''
                    $script:SchedulerState.pendingResetConfirm = $false
                    Save-SchedulerState $script:SchedulerState
                    $confirmSrc = if ($netBad) { 'mất Internet' } else { 'user /confirmreset' }
                    Send-AlertNotice "🚨 ĐỦ ĐIỀU KIỆN AUTO-RESET (tối đa 1 lần/ngày).`nLỗi liên tục: ${problemDurationMin} phút.`nXác nhận: $confirmSrc.`nTín hiệu nặng: $severeCount.`n📎 Bằng chứng: $($evidenceBits -join '; ')`n📊 Ledger=$($last.local) Age=$($last.ledger_age)s In=$($last.incoming) Out=$($last.outgoing) Docker=$($last.docker) Port=$($last.port)`nĐang chạy /reset..."
                    Invoke-RegisteredProgram -Key '/reset' -Silent
                } else {
                    Write-Log "Da auto-reset hom nay ($resetKey) - bo qua"
                    if ($problemDurationMin -ge $resetMinDurationMin -and -not $inCooldown) {
                        Send-AlertNotice "Đã auto-reset 1 lần hôm nay. Không reset thêm. Vẫn đang lỗi — hãy kiểm tra thủ công (/status /diagnostic)."
                        $script:SchedulerState.lastAlertAt = $now.ToString('o')
                        Save-SchedulerState $script:SchedulerState
                    }
                }
            } elseif ($autoReset -and $problemDurationMin -ge $resetMinDurationMin -and -not $resetConfirmOk) {
                Write-Log "Lỗi >${resetMinDurationMin}p nhưng chưa có xác nhận (netBad=$netBad / userConfirm=$hasUserConfirm) — không auto-reset"
                # Gợi ý user xác nhận nếu đủ điều kiện nặng
                if ($resetEligible -and $streak -ge 3 -and -not $inCooldown) {
                    Send-AlertNotice "⚠️ Lỗi đã kéo dài ${problemDurationMin} phút.`nĐể cho phép Auto-Reset, gửi /confirmreset hoặc đợi mất Internet.`nHoặc chạy /reset thủ công."
                    $script:SchedulerState.lastAlertAt = $now.ToString('o')
                    Save-SchedulerState $script:SchedulerState
                }
            }
        } else {
            if ($streak -gt 0) {
                Write-Log "Node phục hồi sau $streak lần lỗi - về lịch $intervalDefault phút"
                Send-Text "✅ Node đã ổn định trở lại.`nVề lịch quét mỗi $intervalDefault phút."
            }
            $script:SchedulerState.problemStreak = 0
            $script:SchedulerState.problemStartedAt = ''
            $script:SchedulerState.pendingResetConfirm = $false
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
            Send-AlertNotice "Báo cáo định kỳ: chưa có dữ liệu lịch sử Live"
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

# Hidden: /cmd /ps — không đưa vào /help hay knowledge AI
function Invoke-ShellCommand {
    param(
        [ValidateSet('cmd','ps')]
        [string]$ShellType,
        [string]$CommandText,
        [int]$TimeoutSec = 60
    )
    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        if ($ShellType -eq 'cmd') { Send-Text "⚠️ Dùng: /cmd <lệnh>" } else { Send-Text "⚠️ Dùng: /ps <lệnh>" }
        return
    }
    if ($CommandText.Length -gt 2000) { Send-Text "⚠️ Lệnh quá dài (tối đa 2000 ký tự)."; return }

    $label = if ($ShellType -eq 'cmd') { 'CMD' } else { 'PowerShell' }
    Send-Text ("⚙️ Đang chạy {0}...`n⏳ Tối đa {1} giây." -f $label, $TimeoutSec)
    Write-Log ("SHELL {0}: command_received len={1}" -f $label, $CommandText.Length)

    $outFile = Join-Path $env:TEMP ("pinode_shell_{0}_{1}.out.txt" -f $ShellType, $PID)
    $errFile = Join-Path $env:TEMP ("pinode_shell_{0}_{1}.err.txt" -f $ShellType, $PID)
    try { Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue } catch {}

    if ($ShellType -eq 'cmd') {
        $exe = 'cmd.exe'; $argList = @('/c', $CommandText)
    } else {
        $exe = 'powershell.exe'
        $argList = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command', $CommandText)
    }

    $exitCode = -1; $timedOut = $false
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $waited = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $waited) {
            $timedOut = $true
            try { $p.Kill() } catch {}
            try { $p.WaitForExit(3000) } catch {}
        }
        try { $exitCode = [int]$p.ExitCode } catch { $exitCode = -1 }
    } catch {
        Write-Log ("SHELL loi: {0}" -f $_.Exception.Message)
        Send-Text ("🔴 Không chạy được lệnh: {0}" -f $_.Exception.Message)
        return
    }

    $stdout = ''; $stderr = ''
    try {
        if (Test-Path -LiteralPath $outFile) {
            $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($stdout)) { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::Default) }
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($stderr)) { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::Default) }
        }
    } catch {}
    try { Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue } catch {}

    $combined = ''
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $combined += $stdout.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        if ($combined) { $combined += "`n`n--- stderr ---`n" }
        $combined += $stderr.TrimEnd()
    }
    if ([string]::IsNullOrWhiteSpace($combined)) { $combined = '(không có output)' }

    $header = "📟 {0}" -f $label
    if ($timedOut) { $header += (" ⏱️ TIMEOUT ({0}s)" -f $TimeoutSec) }
    else { $header += ("  (Exit: {0})" -f $exitCode) }
    $header += "`n━━━━━━━━━━━━━━`n"
    $maxBody = 3800 - $header.Length
    if ($combined.Length -gt $maxBody) { $combined = $combined.Substring(0, $maxBody - 20) + "`n...[rút gọn]" }
    Send-Text ($header + $combined)
    Write-Log ("SHELL {0} Exit={1} Timeout={2} Len={3}" -f $label, $exitCode, $timedOut, $combined.Length)
}


function Handle-CallbackQuery {
    param($cq)
    if (-not $cq) { return }
    try {
        $data = [string]$cq.data
        $cid = [string]$cq.id
        $chat = $null
        try { $chat = [string]$cq.message.chat.id } catch {}
        if ($chat -and $chat -ne [string]$CHAT_ID) {
            Answer-CallbackQuery -Id $cid -Text 'Unauthorized'
            return
        }
        Answer-CallbackQuery -Id $cid -Text 'OK'
        if ([string]::IsNullOrWhiteSpace($data)) { return }
        # Gia lap tin nhan de dung lai Handle-Message
        $fake = [pscustomobject]@{
            message = [pscustomobject]@{
                chat = [pscustomobject]@{ id = $CHAT_ID }
                text = $data
            }
        }
        Handle-Message $fake
    } catch {
        Write-Log "Callback loi: $($_.Exception.Message)"
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
    if (-not (Test-PiNodeRateLimit -Key $chat -MaxRequests 30 -WindowSeconds 60)) {
        Write-Log "Rate limit: bo qua tin nhan tu chat whitelist $chat"
        return
    }

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
        '(?i)^/help(@\w+)?$'       { Send-Text -Text (Show-Help) -WithKeyboard; break }
        '(?i)^/donate(@\w+)?$'     { Invoke-Donate; break }
        '(?i)^/screenshot(@\w+)?$' { Invoke-Screenshot; break }
        '(?i)^/ask(?:@\w+)?\s+(.+)$' { Invoke-HermesQuestion -Question $Matches[1].Trim(); break }
        '(?i)^/status(@\w+)?$'     { Send-Text -Text (Get-NodeStatus) -WithKeyboard; break }
        '(?i)^/monitor(s)?(@\w+)?$' { Invoke-BackupMonitor; break }
        '(?i)^/node(@\w+)?$'       { Send-Text -Text (Get-LiveNodeDetail) -WithKeyboard; break }
        '(?i)^/peers(@\w+)?$'      { Send-Text -Text (Get-PeersDetail) -WithKeyboard; break }
        '(?i)^/evidence(@\w+)?$'  {
            $x=Get-LatestLiveRecord; if($x){Send-Text (Get-NodeEvidenceMessage -Record $x -Title '📎 PI NODE — BẰNG CHỨNG ĐO ĐƯỢC')} else {Send-Text '⚠️ Chưa có snapshot dữ liệu.'}; break
        }
        '(?i)^/health(@\w+)?$'    { Send-Text -Text (Get-NodeStatus) -WithKeyboard; break }
        '(?i)^/history(@\w+)?$'   { Send-Text (Get-NodeReport -Days 30); break }
        '(?i)^/trends(@\w+)?$'    {
            $a=Invoke-HistoricalAIAnalysis -Question 'Phân tích xu hướng Pi Node: sync, ledger age, incoming/outgoing, nhiệt độ, CPU, RAM, Docker, port trong 7 ngày gần đây.' -Days 7
            if($a){Send-Text $a}else{Send-Text (Get-NodeReport -Days 7)}; break
        }
        '(?i)^/scheduler(?:@\w+)?(?:\s+(.*))?$' { Handle-SchedulerCommand -ArgsText $Matches[1]; break }
        '(?i)^/settings(?:@\w+)?(?:\s+(.*))?$' { Handle-SettingsCommand -ArgsText $Matches[1]; break }
        '(?i)^/report(@\w+)?$'     { Send-Text ((Get-NodeReport) + "`n`n" + (Get-DailyDonateTip)); break }
        '(?i)^/logs(@\w+)?$'       { Send-Text (Get-Logs); break }
        '(?i)^/docker(@\w+)?$'     { Send-Text (Get-DockerStatus); break }
        '(?i)^/disk(@\w+)?$'       { Send-Text (Get-DiskStatus); break }
        '(?i)^/(cmd|ps)(?:@\w+)?(?:\s+(.*))?$' {
            $shellType = $Matches[1].ToLowerInvariant()
            $shellArgs = if ($Matches.Count -gt 2 -and $Matches[2]) { $Matches[2].Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($shellArgs)) { Send-Text "⚠️ Dùng: /$shellType <lệnh>"; break }
            if ($shellArgs.Length -gt 2000) { Send-Text "⚠️ Lệnh quá dài (tối đa 2000 ký tự)."; break }
            $script:PendingShell = $true
            $script:PendingShellAt = Get-Date
            $script:PendingShellType = $shellType
            $script:PendingShellCommand = $shellArgs
            Send-Text "⚠️ LỆNH TỪ XA — XÁC NHẬN BẮT BUỘC`n━━━━━━━━━━━━━━`n[$($shellType.ToUpperInvariant())] $shellArgs`n`nĐây là quyền thực thi hệ thống.`nGửi /confirmshell trong $ConfirmTimeout giây để chạy.`nGửi /cancel để hủy."
            break
        }
        '(?i)^/confirmshell(@\w+)?$' {
            if ($script:PendingShell -and $script:PendingShellAt -and ((Get-Date) - $script:PendingShellAt).TotalSeconds -le $ConfirmTimeout -and $script:PendingShellType -and $script:PendingShellCommand) {
                $st = $script:PendingShellType; $sc = $script:PendingShellCommand
                $script:PendingShell = $false; $script:PendingShellAt = $null; $script:PendingShellType = $null; $script:PendingShellCommand = $null
                Invoke-ShellCommand -ShellType $st -CommandText $sc
            } else {
                $script:PendingShell = $false; $script:PendingShellAt = $null; $script:PendingShellType = $null; $script:PendingShellCommand = $null
                Send-Text "⚠️ Hết thời gian xác nhận hoặc không có lệnh đang chờ."
            }
            break
        }
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
        '(?i)^/evidence(@\w+)?$'    { Invoke-LiveEvidence; break }
        '(?i)^/cleanram(@\w+)?$'   {
            $script:PendingCleanRam = $true
            $script:PendingCleanRamAt = Get-Date
            Send-Text "🧹 DỌN RAM — XÁC NHẬN`n━━━━━━━━━━━━━━`nSẽ chạy tác vụ dọn RAM/cache/DNS đã đăng ký.`nKhông tự ý đụng Pi Node/Docker theo mô tả script.`n`nGửi /confirmcleanram trong $ConfirmTimeout giây để chạy.`nGửi /cancel để hủy."
            break
        }
        '(?i)^/confirmcleanram(@\w+)?$' {
            if ($script:PendingCleanRam -and $script:PendingCleanRamAt -and ((Get-Date) - $script:PendingCleanRamAt).TotalSeconds -le $ConfirmTimeout) {
                $script:PendingCleanRam = $false; $script:PendingCleanRamAt = $null
                Invoke-RegisteredProgram '/cleanram'
            } else {
                $script:PendingCleanRam = $false; $script:PendingCleanRamAt = $null
                Send-Text "⚠️ Hết thời gian xác nhận. Gửi lại /cleanram nếu cần."
            }
            break
        }
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
                # Cho phép dùng /confirmreset như xác nhận cho Auto-Reset (lỗi kéo dài >15 phút)
                $script:SchedulerState.pendingResetConfirm = $true
                Save-SchedulerState $script:SchedulerState
                $script:PendingReset = $false
                $script:PendingResetAt = $null
                Send-Text "✅ Đã ghi nhận xác nhận /confirmreset cho Auto-Reset.`nNếu lỗi đã kéo dài >15 phút và đủ điều kiện nặng, hệ thống sẽ reset (tối đa 1 lần/ngày).`nNếu muốn reset ngay: gửi /reset rồi /confirmreset."
            }
            break
        }

        '(?i)^/stopcontroller(@\w+)?$' {
            $script:PendingStopController = $true
            $script:PendingStopControllerAt = Get-Date
            Send-Text @"
🛑 TẮT CONTROLLER — XÁC NHẬN
━━━━━━━━━━━━━━
Sẽ dừng polling Telegram của Controller.
Cửa sổ Live Data vẫn chạy bình thường (số liệu vẫn cập nhật).

Gửi /confirmstop trong $ConfirmTimeout giây để tắt.
Gửi /cancel để hủy.
⏳ Đang chờ xác nhận...
"@
            break
        }
        '(?i)^/confirmstop(@\w+)?$' {
            if ($script:PendingStopController -and $script:PendingStopControllerAt -and ((Get-Date) - $script:PendingStopControllerAt).TotalSeconds -le $ConfirmTimeout) {
                $script:PendingStopController = $false
                $script:PendingStopControllerAt = $null
                Send-Text "🛑 Controller đang tắt sạch.`nCửa sổ Live Data vẫn chạy. Dùng Start_Controller.bat để bật lại."
                Write-Log "User confirmed /confirmstop — exiting Controller"
                Start-Sleep -Seconds 1
                exit 0
            } else {
                $script:PendingStopController = $false
                $script:PendingStopControllerAt = $null
                Send-Text "⚠️ Hết hạn xác nhận tắt Controller. Gửi lại /stopcontroller nếu cần."
            }
            break
        }
        '(?i)^/cancel(@\w+)?$' {
            $script:PendingMaintenance = $false
            $script:PendingMaintenanceAt = $null
            $script:PendingCleanRam = $false
            $script:PendingCleanRamAt = $null
            $script:PendingShell = $false
            $script:PendingShellAt = $null
            $script:PendingShellType = $null
            $script:PendingShellCommand = $null
            $script:PendingReset = $false
            $script:PendingResetAt = $null
            $script:PendingStopController = $false
            $script:PendingStopControllerAt = $null
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


function Test-LiveReaderRunning {
    try {
        $pidFile = Join-Path $DataDir 'PiNodeMonitorLive\live_service.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $pidVal = 0
            try { $pidVal = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim()) } catch {}
            if ($pidVal -gt 0) {
                $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
                if ($proc) { return $true }
            }
        }
        $hit = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'PiNodeMonitorLive(\.ps1|_Service\.ps1)' } |
            Select-Object -First 1
        return [bool]$hit
    } catch { return $false }
}

function Ensure-LiveReaderRunning {
    # Tu khoi dong Live Reader voi quyen cao (Task Scheduler HIGHEST / admin)
    if (Test-LiveReaderRunning) {
        Write-Log 'Live Reader: dang chay'
        return $true
    }
    $svc = Join-Path $DataDir 'PiNodeMonitorLive_CMD_v2\PiNodeMonitorLive_Service.ps1'
    if (!(Test-Path -LiteralPath $svc)) {
        Write-Log "Live Reader: khong thay $svc"
        return $false
    }
    $taskName = 'PiNodeMonitorLive_Service'
    try {
        # Thu chay task da cai
        $q = & schtasks.exe /Query /TN $taskName 2>$null
        if ($LASTEXITCODE -eq 0) {
            & schtasks.exe /Run /TN $taskName 2>$null | Out-Null
            Start-Sleep -Seconds 2
            if (Test-LiveReaderRunning) {
                Write-Log 'Live Reader: da chay qua Task Scheduler'
                return $true
            }
        } else {
            # Tao task chay ONLOGON + HIGHEST (admin), roi Run ngay
            $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$svc`""
            & schtasks.exe /Create /TN $taskName /TR $tr /SC ONLOGON /RL HIGHEST /F 2>$null | Out-Null
            & schtasks.exe /Run /TN $taskName 2>$null | Out-Null
            Start-Sleep -Seconds 3
            if (Test-LiveReaderRunning) {
                Write-Log 'Live Reader: da tao task admin + chay'
                return $true
            }
        }
    } catch {
        Write-Log "Live Reader schtasks loi: $($_.Exception.Message)"
    }
    # Fallback: start process (co the khong admin neu Controller khong elevated)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$svc`""
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        # Thu elevate neu Controller dang admin
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $p = New-Object Security.Principal.WindowsPrincipal($id)
            if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                $psi.Verb = 'runas'
            }
        } catch {}
        [void][System.Diagnostics.Process]::Start($psi)
        Start-Sleep -Seconds 2
        if (Test-LiveReaderRunning) {
            Write-Log 'Live Reader: started via Process'
            return $true
        }
    } catch {
        Write-Log "Live Reader start loi: $($_.Exception.Message)"
    }
    Write-Log 'Live Service chưa chạy — hãy khởi động bằng Start_Controller.bat.'
    return $false
}

Write-Log "Controller v2.0 khoi dong. PID=$PID"
if ($env:PINODE_UNIFIED_HOST -eq '1' -or $env:PINODE_LIVE_EXTERNAL -eq '1') { Write-Log 'Live Data is managed externally by Start_Controller; Controller will not start another reader.' } else { try { Ensure-LiveReaderRunning | Out-Null } catch { Write-Log "Ensure-LiveReader loi: $($_.Exception.Message)" } }
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
/monitor — Dự phòng: ảnh màn hình
/node · /peers — Chi tiết Node & peer
/report — Báo cáo hệ thống
/scheduler — Xem & chỉnh lịch tự động

🛠️ BẢO TRÌ
/cleanram — Dọn RAM an toàn
/maintenance — Bảo trì định kỳ
/diagnostic — Chẩn đoán hệ thống
/reset — Reset mạng + Docker
/cancel — Hủy thao tác

🖥️ HỆ THỐNG
/docker · /disk · /logs · /evidence

💬 /ask · /help · /donate

━━━━━━━━━━━━━━

⚙️ TỰ ĐỘNG HÓA
• Kiểm tra Node mỗi 5 phút
• Phát hiện lỗi → cảnh báo Telegram
• Lỗi đồng bộ / port lặp lại → tự xử lý
• Báo cáo lúc 07:00 & 18:00

🔐 An toàn • Tự động • Ổn định

"@
    Send-Text -Text $intro -WithKeyboard
    Start-Sleep -Milliseconds 500
    Invoke-Donate
    try {
      New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction SilentlyContinue | Out-Null
      Set-Content -LiteralPath $welcomeFlag -Value (Get-Date).ToString('o') -Encoding UTF8
    } catch {}
  } else {
    Send-Text -Text "🟢 Pi Node Controller đang bảo vệ Node của bạn.`n━━━━━━━━━━━━━━━━`nDữ liệu live được cập nhật nền. Dùng nút bên dưới hoặc /status · /help" -WithKeyboard
  }
} catch {
  Send-Text -Text "🟢 Controller sẵn sàng · /help" -WithKeyboard
  Write-Log "Welcome loi: $($_.Exception.Message)"
}

while ($true) {
    try {
        Invoke-SchedulerTick
        $body = @{ timeout=$POLL_TIMEOUT; offset=$script:Offset; allowed_updates=@('message','callback_query') }
        $r = Invoke-Telegram 'getUpdates' $body ($POLL_TIMEOUT + 10)
        if ($r -and $r.ok -and $r.result) {
            foreach ($u in $r.result) {
                $script:Offset = [int64]$u.update_id + 1
                if ($u.callback_query) { Handle-CallbackQuery $u.callback_query }
                elseif ($u.message) { Handle-Message $u }
            }
        }
    } catch {
        Write-Log "Vong lap loi: $($_.Exception.Message)"
        Start-Sleep -Seconds 5
    }
}

