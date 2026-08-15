# PI NODE SMART MONITOR v9.0 PORTABLE
# Windows PowerShell 5.1
# File nay co the dat o BAT KY thu muc nao.
# Moi duong dan du lieu deu tu dong tinh theo thu muc chua file.

$ErrorActionPreference='Continue'

# ================= CENTRAL CONFIG =================
# Smart Monitor nam trong:
#   <AppRoot>\Data\PiNode_SmartMonitor_v9_CentralConfig.ps1
#
# Config chung cua app:
#   <AppRoot>\Config\PiNode_Config.ps1

$BASE_DIR = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BASE_DIR)) {
    $BASE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$APP_ROOT = Split-Path -Parent $BASE_DIR
$CONFIG_FILE = Join-Path $APP_ROOT 'Config\PiNode_Config.ps1'

if (!(Test-Path -LiteralPath $CONFIG_FILE)) {
    Write-Host "LOI: Khong tim thay Config trung tam:" -ForegroundColor Red
    Write-Host $CONFIG_FILE -ForegroundColor Red
    exit 20
}

try {
    . $CONFIG_FILE
} catch {
    Write-Host "LOI: Khong nap duoc Config trung tam:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 21
}

$BOT_TOKEN       = $BotToken
$CHAT_ID         = $ChatId
$GEMINI_API_KEY  = $GeminiApiKey
$GEMINI_MODELS   = $GeminiModels
$RAM_ALERT       = $RamAlert
$TEMP_ALERT      = $TempAlert
$INCOMING_LOW    = $IncomingLow
$CPU_ALERT       = $CpuAlert
$WINDOW_KEYWORDS = $WindowKeywords

if (!$GEMINI_MODELS)   { $GEMINI_MODELS=@('gemini-3.6-flash','gemini-3.5-flash','gemini-2.5-flash','gemini-2.0-flash') }
if (!$RAM_ALERT)       { $RAM_ALERT=88 }
if (!$TEMP_ALERT)      { $TEMP_ALERT=78 }
if (!$INCOMING_LOW)    { $INCOMING_LOW=3 }
if (!$CPU_ALERT)       { $CPU_ALERT=90 }
if (!$WINDOW_KEYWORDS) { $WINDOW_KEYWORDS=@('PiCheck','Pi Network','Pi Node') }

$HISTORY_DIR=Join-Path $BASE_DIR 'History\ScreenMonitor'
$LOGFILE=Join-Path $BASE_DIR 'Monitor_Node.log'
$DATA_FILE=Join-Path $BASE_DIR 'node_history.json'
$CLEAN_SCRIPT=Join-Path $BASE_DIR 'CleanRAM_PiNode.ps1'
New-Item -ItemType Directory -Path $HISTORY_DIR -Force -ErrorAction SilentlyContinue|Out-Null

function Write-Log {
 param([string]$Text)
 try {
  $line="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Text"
  Write-Host $line -ForegroundColor Cyan
  $line|Out-File -LiteralPath $LOGFILE -Append -Encoding utf8
 } catch {}
}

function Send-Telegram {
 param([string]$Text,[int]$Times=1)
 if ([string]::IsNullOrWhiteSpace($BOT_TOKEN) -or $BOT_TOKEN -eq 'PUT_TELEGRAM_BOT_TOKEN_HERE') {
  Write-Log 'Telegram chua cau hinh'; return
 }
 for($i=1;$i -le $Times;$i++){
  try {
   $u="https://api.telegram.org/bot$BOT_TOKEN/sendMessage?chat_id=$CHAT_ID&text=$([uri]::EscapeDataString($Text))"
   Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 15|Out-Null
   Write-Log "Telegram OK ($i/$Times)"
  } catch { Write-Log "Telegram LOI: $($_.Exception.Message)" }
  if($i -lt $Times){Start-Sleep 2}
 }
}

function Load-History {
 if(Test-Path -LiteralPath $DATA_FILE){
  try {
   $x=Get-Content -LiteralPath $DATA_FILE -Raw -Encoding UTF8|ConvertFrom-Json
   if($x -isnot [array]){$x=@($x)}
   return @($x)
  } catch {Write-Log "History loi: $($_.Exception.Message)"}
 }
 return @()
}

function Save-History {
 param([array]$List)
 $cut=(Get-Date).AddHours(-48)
 try {
  @($List|Where-Object{try{[datetime]$_.time -gt $cut}catch{$true}})|
   ConvertTo-Json -Depth 8|Out-File -LiteralPath $DATA_FILE -Encoding utf8
 } catch {Write-Log "Save history loi: $($_.Exception.Message)"}
}

# ================= SCREEN CAPTURE =================
$dll="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\System.Drawing.dll"
if(!(Test-Path $dll)){$dll="$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\System.Drawing.dll"}
if(!(Test-Path $dll)){Write-Log 'Thieu System.Drawing';exit 10}
try{Add-Type -Path $dll -ErrorAction Stop}catch{}
try{Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue}catch{}

if(-not([System.Management.Automation.PSTypeName]'PiWin').Type){
try{
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
public class PiWin {
  public delegate bool E(IntPtr h,IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(E cb,IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool f);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk,byte bScan,uint dwFlags,UIntPtr dwExtra);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr hAfter,int x,int y,int cx,int cy,uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int Left,Top,Right,Bottom; }
  static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  const uint SWP_NOMOVE=0x0002, SWP_NOSIZE=0x0001, SWP_SHOWWINDOW=0x0040;
  const int SW_RESTORE=9, SW_SHOW=5, SW_SHOWNA=8;
  const byte VK_MENU=0x12; const uint KEYEVENTF_KEYUP=0x0002;

  public static string Title(IntPtr h){ var s=new StringBuilder(1024); GetWindowText(h,s,1024); return s.ToString(); }

  // Tim TAT CA cua so khop keyword (khong chi cai dau)
  public static IntPtr[] FindAll(string[] keys){
    var list=new List<IntPtr>();
    EnumWindows((h,l)=>{
      if(!IsWindow(h)) return true;
      string t=Title(h);
      if(String.IsNullOrWhiteSpace(t)) return true;
      foreach(var k in keys){
        if(!String.IsNullOrWhiteSpace(k) && t.IndexOf(k,StringComparison.OrdinalIgnoreCase)>=0){
          if(!list.Contains(h)) list.Add(h);
          break;
        }
      }
      return true;
    },IntPtr.Zero);
    return list.ToArray();
  }

  public static IntPtr Find(string[] keys){
    var all=FindAll(keys);
    return all.Length>0 ? all[0] : IntPtr.Zero;
  }

  // Uu tien cua so co title chua prefer (vd PiCheck)
  public static IntPtr FindPreferred(string[] keys, string prefer){
    var all=FindAll(keys);
    if(all.Length==0) return IntPtr.Zero;
    if(!String.IsNullOrWhiteSpace(prefer)){
      foreach(var h in all){
        if(Title(h).IndexOf(prefer,StringComparison.OrdinalIgnoreCase)>=0) return h;
      }
    }
    return all[0];
  }

  // Force dua cua so len tren cung - vuot Windows focus steal protection
  public static void ForceFocus(IntPtr h){
    if(h==IntPtr.Zero || !IsWindow(h)) return;
    try{
      AllowSetForegroundWindow(-1); // ASFW_ANY
      if(IsIconic(h)) ShowWindow(h, SW_RESTORE);
      ShowWindow(h, SW_SHOW);
      BringWindowToTop(h);
      // Topmost flash roi bo topmost = dua len mat
      SetWindowPos(h, HWND_TOPMOST, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW);
      SetWindowPos(h, HWND_NOTOPMOST, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW);
      // Alt key trick de Windows cho phep SetForegroundWindow
      keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
      keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
      SetForegroundWindow(h);
      uint pid=0; uint t=GetWindowThreadProcessId(h, out pid); uint c=GetCurrentThreadId();
      if(t!=c && t!=0){
        AttachThreadInput(c,t,true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        AttachThreadInput(c,t,false);
      }
      SetForegroundWindow(h);
    }catch{}
  }

  // Backward compatible
  public static void Focus(IntPtr h){ ForceFocus(h); }

  public static bool Capture(IntPtr h,string path){
    R r; if(!GetWindowRect(h,out r)) return false;
    int w=r.Right-r.Left, hh=r.Bottom-r.Top;
    if(w<80||hh<80) return false;
    using(var b=new Bitmap(w,hh))
    using(var g=Graphics.FromImage(b)){
      g.CopyFromScreen(r.Left,r.Top,0,0,new Size(w,hh),CopyPixelOperation.SourceCopy);
      b.Save(path,System.Drawing.Imaging.ImageFormat.Png);
    }
    return true;
  }
}
"@ -ReferencedAssemblies $dll -ErrorAction Stop
}catch{Write-Log "Helper loi: $($_.Exception.Message)";exit 12}
}

function Capture-FullScreen {
 param([string]$Path)
 try {
  $b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height)
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size)
  $bmp.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose();$bmp.Dispose();return $true
 } catch {return $false}
}

# ================= GEMINI =================
function Invoke-GeminiVision {
 param([string]$ImagePath,[string]$SourceHint='PiCheck')
 if(!(Test-Path $ImagePath)-or [string]::IsNullOrWhiteSpace($GEMINI_API_KEY)-or $GEMINI_API_KEY -eq 'PUT_GEMINI_API_KEY_HERE'){return $null}
 try{$b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($ImagePath))}catch{return $null}

# Prompt toi uu cho PiCheck 21.x (Monitor tab) + Pi Desktop Troubleshooting
$src = if ($SourceHint) { $SourceHint } else { 'PiCheck' }
$prompt=@"
You are reading a Windows screenshot of Pi Node software.

DATA SOURCE PRIORITY (follow strictly):
1) If the image shows a window titled like "PiCheck ..." (e.g. PiCheck 21.2.0 - Running Admin Mode): READ DATA FROM PICHECK ONLY.
2) If PiCheck is NOT visible but "Pi Desktop" (Troubleshooting / Diagnostics) is visible: READ FROM PI DESKTOP.
3) Current capture source hint from the system: $src

=== IF SOURCE IS PiCheck (Monitor tab) ===
- State : Synced/Syncing -> sync_state
- Large Outgoing / Incoming numbers at top -> outgoing, incoming
- Block Number(Local/Latest) e.g. 10381480 / 10381480 (0) -> local_block, latest_block (two integers only)
- Internet connection OK/ERROR -> internet
- Blockchain control OK/ERROR -> blockchain_control
- Availability large percent e.g. 97.38% -> availability (number only)
- Bottom CPU line e.g. 8% and 54 C -> cpu_percent, cpu_temp
- Bottom RAM line e.g. 44% -> ram_percent
- Health 31401/31402/31403 100% -> ports OK

=== IF SOURCE IS PiDesktop (Troubleshooting) ===
- Consensus "State: Synced!" -> sync_state = Synced
- Outgoing connections: N -> outgoing
- Incoming connections: N -> incoming
- Latest block: ... (if only text like "a few seconds ago", set latest_block N/A unless a number is shown)
- Consensus container running / Node switch on -> helps confirm node healthy
- Supporting other nodes Yes/No

Return PURE JSON only (no markdown):
{
  "picheck_found": true,
  "data_source": "PiCheck or PiDesktop",
  "sync_state": "Synced|Syncing|Not Synced|N/A",
  "outgoing": 0,
  "incoming": 0,
  "local_block": 0,
  "latest_block": 0,
  "internet": "OK|ERROR|N/A",
  "blockchain_control": "OK|ERROR|N/A",
  "cpu_percent": 0,
  "cpu_temp": 0,
  "ram_percent": 0,
  "availability": 0,
  "port_31401": "OK|N/A",
  "port_31402": "OK|N/A",
  "port_31403": "OK|N/A"
}

Rules:
- Prefer PiCheck numbers when both windows appear.
- Numbers only for numeric fields (no % units commas).
- Do not invent values. If unreadable use "N/A".
- If neither PiCheck nor Pi Desktop data visible: picheck_found=false.
"@


$bodyObj = @{
  contents = @(@{
    parts = @(
      @{ text = $prompt },
      @{ inline_data = @{ mime_type = 'image/png'; data = $b64 } }
    )
  })
  generationConfig = @{
    temperature = 0.1
    maxOutputTokens = 1024
  }
}
$body = $bodyObj | ConvertTo-Json -Depth 12 -Compress

function ConvertFrom-AiJson([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $t = $raw.Trim()
  $t = $t -replace '(?s)```json\s*','' -replace '(?s)```\s*',''
  $t = $t.Trim()
  # Lay object JSON dau tien neu AI them text
  $m = [regex]::Match($t, '\{[\s\S]*\}')
  if ($m.Success) { $t = $m.Value }
  try { return ($t | ConvertFrom-Json) } catch {
    Write-Log "AI JSON parse loi: $($_.Exception.Message) raw=$($t.Substring(0,[Math]::Min(200,$t.Length)))"
    return $null
  }
}

function Normalize-AiResult($ai) {
  if ($null -eq $ai) { return $null }
  # Chuan hoa so: bo dau phay, %, C, chu
  foreach ($n in @('outgoing','incoming','local_block','latest_block','cpu_percent','cpu_temp','ram_percent','availability')) {
    if ($null -eq $ai.$n) { continue }
    $s = [string]$ai.$n
    if ($s -match '(?i)n/?a') { $ai | Add-Member -NotePropertyName $n -NotePropertyValue 'N/A' -Force; continue }
    $s2 = ($s -replace ',','' -replace '%','' -replace '[^\d\.\-]','').Trim()
    if ($s2 -match '^-?\d+(\.\d+)?$') {
      if ($n -in @('outgoing','incoming','local_block','latest_block','cpu_percent','ram_percent')) {
        $ai | Add-Member -NotePropertyName $n -NotePropertyValue ([int][double]$s2) -Force
      } else {
        $ai | Add-Member -NotePropertyName $n -NotePropertyValue ([math]::Round([double]$s2,2)) -Force
      }
    }
  }
  # sync_state
  if ($ai.sync_state) {
    $ss = [string]$ai.sync_state
    if ($ss -match '(?i)synced' -and $ss -notmatch '(?i)not') { $ai | Add-Member -NotePropertyName sync_state -NotePropertyValue 'Synced' -Force }
    elseif ($ss -match '(?i)syncing') { $ai | Add-Member -NotePropertyName sync_state -NotePropertyValue 'Syncing' -Force }
    elseif ($ss -match '(?i)not') { $ai | Add-Member -NotePropertyName sync_state -NotePropertyValue 'Not Synced' -Force }
  }
  return $ai
}

foreach($model in $GEMINI_MODELS){
 try{
  Write-Log "AI dang doc model=$model"
  $uri="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY"
  $r=Invoke-RestMethod -Uri $uri -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
  $txt = $null
  try { $txt = $r.candidates[0].content.parts[0].text } catch {}
  if ($txt) {
    $parsed = ConvertFrom-AiJson $txt
    $parsed = Normalize-AiResult $parsed
    if ($parsed) {
      Write-Log "AI OK model=$model sync=$($parsed.sync_state) in=$($parsed.incoming) out=$($parsed.outgoing) local=$($parsed.local_block) temp=$($parsed.cpu_temp)"
      return $parsed
    }
  } else {
    Write-Log "AI $model khong co text tra ve"
  }
 }catch{Write-Log "AI $model loi: $($_.Exception.Message)"}
}
return $null
}

# ================= MAIN =================
Write-Log '========== BAT DAU v9.0 PORTABLE =========='
Write-Log "BASE_DIR=$BASE_DIR"
$Now=Get-Date;$Hour=$Now.Hour
$History=@(Load-History)
$Last=if($History.Count){$History[-1]}else{$null}

$OS=Get-CimInstance Win32_OperatingSystem
$RAM=[int]((($OS.TotalVisibleMemorySize-$OS.FreePhysicalMemory)/$OS.TotalVisibleMemorySize)*100)
$CPU=[int]((Get-CimInstance Win32_Processor|Measure-Object LoadPercentage -Average).Average)
$FreeGB=[math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace/1GB,1)
$Uptime='{0} ngay {1} gio'-f ($Now-$OS.LastBootUpTime).Days,($Now-$OS.LastBootUpTime).Hours
$Net='OFFLINE';$Ping='N/A'
$p=Test-Connection 8.8.8.8 -Count 1 -ErrorAction SilentlyContinue
if($p){$Net='ONLINE';$Ping="$($p.ResponseTime)ms"}
$Docker=if(Get-Process -ErrorAction SilentlyContinue|Where-Object ProcessName -match 'docker'){'RUNNING'}else{'STOPPED'}
$PiApp=if(Get-Process -ErrorAction SilentlyContinue|Where-Object ProcessName -match 'Pi Network'){'RUNNING'}else{'STOPPED'}

$PortOpen=$false
foreach($pt in 31401,31402,31403){
 try{if((Test-NetConnection 127.0.0.1 -Port $pt -WarningAction SilentlyContinue).TcpTestSucceeded){$PortOpen=$true;break}}catch{}
}
$PortStatus=if($PortOpen){'OPEN'}else{'CLOSED'}

$stamp=$Now.ToString('yyyyMMdd_HHmmss')
$Img=Join-Path $HISTORY_DIR "Pi_$stamp.png"
$WindowFound=$false;$CaptureOK=$false;$CaptureMode='none';$CaptureSource='none';$AI=$null;$PrevWin=[IntPtr]::Zero

try{
 $PrevWin=[PiWin]::GetForegroundWindow()
 $allWin=[PiWin]::FindAll($WINDOW_KEYWORDS)
 $hwnd=[IntPtr]::Zero
 $CaptureSource='none'

 if($allWin -and $allWin.Count -gt 0){
  $WindowFound=$true
  Write-Log ("Tim thay $($allWin.Count) cua so: " + (($allWin | ForEach-Object { [PiWin]::Title($_) }) -join ' | '))

  # --- Uu tien 1: PiCheck ---
  $hwndPiCheck=[PiWin]::FindPreferred($WINDOW_KEYWORDS,'PiCheck')
  # --- Uu tien 2: Pi Desktop / Pi Network ---
  $hwndDesktop=[IntPtr]::Zero
  foreach($h in $allWin){
   $t=[PiWin]::Title($h)
   if($t -match '(?i)pi\s*desktop'){ $hwndDesktop=$h; break }
  }
  if($hwndDesktop -eq [IntPtr]::Zero){
   foreach($h in $allWin){
    $t=[PiWin]::Title($h)
    if($t -match '(?i)pi\s*network' -and $t -notmatch '(?i)picheck'){ $hwndDesktop=$h; break }
   }
  }

  # Dua cac cua so lien quan len (Desktop truoc, PiCheck sau = PiCheck o tren cung neu co)
  if($hwndDesktop -ne [IntPtr]::Zero){
   Write-Log "ForceFocus Desktop: $([PiWin]::Title($hwndDesktop))"
   [PiWin]::ForceFocus($hwndDesktop)
   Start-Sleep -Milliseconds 350
  }
  if($hwndPiCheck -ne [IntPtr]::Zero){
   Write-Log "ForceFocus PiCheck: $([PiWin]::Title($hwndPiCheck))"
   [PiWin]::ForceFocus($hwndPiCheck)
   Start-Sleep -Milliseconds 500
  }

  # Chup: uu tien PiCheck, khong co thi Pi Desktop
  if($hwndPiCheck -ne [IntPtr]::Zero){
   $hwnd=$hwndPiCheck
   $CaptureSource='PiCheck'
  } elseif($hwndDesktop -ne [IntPtr]::Zero){
   $hwnd=$hwndDesktop
   $CaptureSource='PiDesktop'
   Write-Log 'Khong co PiCheck - dung Pi Desktop'
  } else {
   $hwnd=$allWin[0]
   $CaptureSource='OtherPi'
   Write-Log "Khong co PiCheck/Desktop - dung: $([PiWin]::Title($hwnd))"
  }

  [PiWin]::ForceFocus($hwnd)
  Start-Sleep -Milliseconds 700
  Write-Log "Chup nguon=$CaptureSource title=$([PiWin]::Title($hwnd))"
  if([PiWin]::Capture($hwnd,$Img)){ $CaptureOK=$true; $CaptureMode="window:$CaptureSource" }
 } else {
  Write-Log 'Khong tim thay cua so PiCheck / Pi Desktop / Pi Network'
 }

 if(-not $CaptureOK -and (Capture-FullScreen $Img)){
  $CaptureOK=$true
  $CaptureMode='fullscreen'
  $CaptureSource='FullScreen'
  Write-Log 'Fallback: chup full man hinh'
 }

 if($CaptureOK){
  $AI=Invoke-GeminiVision -ImagePath $Img -SourceHint $CaptureSource
 }
}catch{Write-Log "Capture loi: $($_.Exception.Message)"}
finally{if($PrevWin -ne [IntPtr]::Zero){try{[PiWin]::SetForegroundWindow($PrevWin)|Out-Null}catch{}}}

$Local='N/A';$Latest='N/A';$Out='N/A';$In='N/A';$Temp='N/A';$Sync='N/A';$AINet='N/A';$AIChain='N/A';$Avail='N/A';$AiCpu='N/A';$PiCheckInImage=$null
if($AI){
 if($null-ne$AI.picheck_found){$PiCheckInImage=[bool]$AI.picheck_found}
 foreach($pair in @(
  @('sync_state','Sync'),@('outgoing','Out'),@('incoming','In'),@('local_block','Local'),
  @('latest_block','Latest'),@('internet','AINet'),@('blockchain_control','AIChain'),
  @('cpu_temp','Temp'),@('availability','Avail'),@('cpu_percent','AiCpu')
 )){
  $prop=$pair[0];$var=$pair[1]
  $val=$AI.$prop
  if($null -ne $val -and "$val" -ne '' -and "$val" -ne 'N/A'){
    Set-Variable -Name $var -Value "$val"
  }
 }
 # Neu AI doc duoc CPU% ma he thong WMI lech, uu tien AI cho nhiet do (Temp da map)
 Write-Log "AI map: Sync=$Sync Out=$Out In=$In Local=$Local Latest=$Latest Temp=$Temp Avail=$Avail Net=$AINet Chain=$AIChain"
}
$SyncStatus='Chua ro'
if($Local-ne'N/A'-and$Latest-ne'N/A'){try{$SyncStatus=if([double]$Local-eq[double]$Latest){'Dong bo tot'}else{'Lech khoi'}}catch{$SyncStatus=$Sync}}
elseif($Sync-match'Synced'){$SyncStatus='Dong bo tot'}
elseif($Sync-match'Syncing'){$SyncStatus='Dang dong bo'}
elseif($Sync-match'Not'){$SyncStatus='Chua dong bo'}


# --- Nhiệt độ hệ thống dự phòng (không phụ thuộc PiCheck) ---
function Get-SystemTemperatureC {
  $candidates = @()
  # 1) WMI ACPI thermal zone (nếu driver hỗ trợ)
  try {
    $zones = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
    foreach ($z in @($zones)) {
      try {
        $k = [double]$z.CurrentTemperature
        if ($k -gt 0) {
          $c = [math]::Round(($k / 10.0) - 273.15, 1)
          if ($c -ge 20 -and $c -le 120) { $candidates += $c }
        }
      } catch {}
    }
  } catch {}
  # 2) LibreHardwareMonitor / OpenHardwareMonitor WMI nếu có
  foreach ($ns in @('root/LibreHardwareMonitor','root/OpenHardwareMonitor')) {
    try {
      $sensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction SilentlyContinue |
        Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU|Package|Tctl|Core' }
      foreach ($s in @($sensors)) {
        try {
          $c = [math]::Round([double]$s.Value, 1)
          if ($c -ge 20 -and $c -le 120) { $candidates += $c }
        } catch {}
      }
    } catch {}
  }
  # 3) Core Temp - đọc log/file nếu có
  try {
    $ctPaths = @(
      (Join-Path $env:ProgramFiles 'Core Temp\coretemp.cmd'),
      (Join-Path ${env:ProgramFiles(x86)} 'Core Temp\coretemp.cmd')
    )
    # Shared memory không dễ từ PS; thử file log trong AppData
    $log = Join-Path $env:APPDATA 'Core Temp\CT_Status.txt'
    if (Test-Path -LiteralPath $log) {
      $line = Get-Content -LiteralPath $log -Tail 5 -ErrorAction SilentlyContinue | Where-Object { $_ -match '(\d+(?:\.\d+)?)\s*°?\s*C' } | Select-Object -Last 1
      if ($line -match '(\d+(?:\.\d+)?)') {
        $c = [math]::Round([double]$Matches[1], 1)
        if ($c -ge 20 -and $c -le 120) { $candidates += $c }
      }
    }
  } catch {}
  # 4) Performance counter "Thermal Zone Information" (một số máy)
  try {
    $pc = Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction SilentlyContinue
    foreach ($s in @($pc.CounterSamples)) {
      try {
        $k = [double]$s.CookedValue
        $c = [math]::Round($k - 273.15, 1)
        if ($c -ge 20 -and $c -le 120) { $candidates += $c }
      } catch {}
    }
  } catch {}

  if ($candidates.Count -eq 0) { return $null }
  # Lấy trung bình các mẫu hợp lệ (ổn định hơn max)
  return [math]::Round((($candidates | Measure-Object -Average).Average), 1)
}

# Nếu AI/PiCheck không có nhiệt độ hợp lệ → fallback hệ thống
try {
  $tempOk = $false
  if ($Temp -ne 'N/A' -and "$Temp" -ne '' -and "$Temp" -ne '0') {
    try {
      $td = [double]$Temp
      if ($td -ge 20 -and $td -le 120) { $tempOk = $true } else { $Temp = 'N/A' }
    } catch { $Temp = 'N/A' }
  }
  if (-not $tempOk) {
    $sysT = Get-SystemTemperatureC
    if ($null -ne $sysT) {
      $Temp = "$sysT"
      Write-Log "Nhiet do fallback he thong: $Temp C (khong phu thuoc PiCheck)"
    } else {
      Write-Log "Khong lay duoc nhiet do tu AI/PiCheck/he thong"
    }
  }
} catch { Write-Log "Temp fallback loi: $($_.Exception.Message)" }

# SoftIssues: thieu UI/AI - khong tinh la su co Node, khong canh bao Telegram
# Warnings: tai nguyen cao - theo doi, khong tu reset
# Critical: port/docker/sync/internet - canh bao + co the reset
$SoftIssues=@()
$Warnings=@()
$Critical=@()

if($WindowFound -and $CaptureSource -eq 'PiDesktop'){ Write-Log 'Nguon: Pi Desktop (khong thay PiCheck - van chap nhan)' }
if($WindowFound -and $CaptureSource -eq 'PiCheck'){ Write-Log 'Nguon chinh: PiCheck' }
if(!$WindowFound){ $SoftIssues+='Khong tim thay cua so PiCheck/Pi Desktop (van kiem tra Docker/port/he thong)' }
if(!$CaptureOK){ $SoftIssues+='Khong chup duoc man hinh (bo qua OCR)' }
if($CaptureOK -and !$AI){
  if([string]::IsNullOrWhiteSpace($GEMINI_API_KEY) -or $GEMINI_API_KEY -eq 'PUT_GEMINI_API_KEY_HERE'){
    $SoftIssues+='Thieu GeminiApiKey - khong OCR duoc cua so'
  } else {
    $SoftIssues+='AI khong doc duoc du lieu tu anh'
  }
}
if($AI -and $PiCheckInImage -eq $false -and $CaptureSource -eq 'PiDesktop'){
  $SoftIssues+='Dang doc tu Pi Desktop thay vi PiCheck'
}
if($Local -eq 'N/A' -and $Latest -eq 'N/A' -and $Out -eq 'N/A' -and $In -eq 'N/A' -and $AI){
  $SoftIssues+='Khong doc duoc thong so block/peer tu anh'
}

# Warnings (tai nguyen)
if($RAM -ge $RAM_ALERT){ $Warnings+="RAM cao: $RAM%" }
if($CPU -ge $CPU_ALERT){ $Warnings+="CPU cao: $CPU%" }
if($Temp -ne 'N/A'){
  try { if([double]$Temp -ge $TEMP_ALERT){ $Warnings+="Nhiet do cao: $Temp C" } } catch {}
}
if($FreeGB -lt 20){ $Warnings+="O C thap: $FreeGB GB" }
if($In -ne 'N/A'){
  try { if([double]$In -le $INCOMING_LOW){ $Warnings+="Incoming thap: $In" } } catch {}
}

# Critical - su co Node thuc su
if($PortStatus -eq 'CLOSED'){ $Critical+='Port Node dang dong' }
if($Docker -eq 'STOPPED'){ $Critical+='Docker dang tat' }
if($SyncStatus -in @('Lech khoi','Chua dong bo')){ $Critical+="Dong bo khoi: $SyncStatus ($Local / $Latest)" }
if($AINet -eq 'ERROR'){ $Critical+='Internet (Node) bao ERROR' }
if($AIChain -eq 'ERROR'){ $Critical+='Blockchain control bao ERROR' }
if($Net -eq 'OFFLINE'){ $Critical+='May mat ket noi Internet' }

# problems = so su co THUC (critical + warning nang). Soft khong dem.
$Problems = @($Critical + $Warnings)
$ProblemCount = $Problems.Count
$CriticalCount = $Critical.Count
$Severity = if($CriticalCount -gt 0){ 'CRITICAL' } elseif($Warnings.Count -gt 0){ 'WARNING' } else { 'OK' }

# Chi canh bao Telegram khi CRITICAL (hoac WARNING neu muon - mac dinh chi CRITICAL de tranh bao gia)
# Controller/scheduler se doc problems + severity
if($Critical.Count -gt 0){
 $list=($Critical|ForEach-Object{"- $_"})-join "`n"
 $warnExtra = if($Warnings.Count){ "`nCanh bao phu:`n"+(($Warnings|ForEach-Object{"- $_"})-join "`n") } else { '' }
 $msg=@"
CANH BAO PI NODE (CRITICAL)
Luc $(Get-Date -Format 'HH:mm') ngay $(Get-Date -Format 'dd/MM')

Su co thuc su:
$list$warnExtra

Thong so:
- RAM: $RAM% | CPU: $CPU% | Nhiet do: $Temp C
- Dong bo: $SyncStatus
- Incoming / Outgoing: $In / $Out
- Port: $PortStatus | Docker: $Docker
- Nguon du lieu: $CaptureSource
"@
 if($MonitorSelfNotify){ Send-Telegram $msg.Trim() }
 Write-Log "CRITICAL: $($Critical -join '; ')"
} elseif($Warnings.Count -gt 0) {
 Write-Log "WARNING (khong spam Telegram): $($Warnings -join '; ')"
} else {
 Write-Log "OK: khong su co critical/warning"
}
if($SoftIssues.Count){ Write-Log "SoftIssues: $($SoftIssues -join '; ')" }

$History += [ordered]@{
 time=$Now.ToString('o');sync=$SyncStatus;local=$Local;latest=$Latest
 outgoing=$Out;incoming=$In;temp=$Temp;ram_sys=$RAM;cpu_sys=$CPU
 internet=$AINet;blockchain=$AIChain;avail=$Avail;docker=$Docker
 port=$PortStatus;capture=$CaptureMode;window=$WindowFound
 problems=$ProblemCount; critical=$CriticalCount; severity=$Severity
 source=$CaptureSource
}
Save-History $History

if($Hour-eq7-or$Hour-eq18){
 $since=$Now.AddHours(-24)
 $Day=@($History|Where-Object{try{[datetime]$_.time-ge$since}catch{$false}})
 $TotalRuns=$Day.Count;$ProblemRuns=@($Day|Where-Object{$_.problems-gt 0}).Count
 $temps=@($Day|Where-Object{$_.temp-ne'N/A'}|ForEach-Object{try{[double]$_.temp}catch{}})
 $maxT=if($temps.Count){($temps|Measure-Object -Maximum).Maximum}else{'N/A'}
 $avgT=if($temps.Count){[math]::Round(($temps|Measure-Object -Average).Average,1)}else{'N/A'}
 $ins=@($Day|Where-Object{$_.incoming-ne'N/A'}|ForEach-Object{try{[double]$_.incoming}catch{}})
 $avgIn=if($ins.Count){[math]::Round(($ins|Measure-Object -Average).Average,1)}else{'N/A'}
 $syncOK=@($Day|Where-Object{$_.sync-eq'Dong bo tot'}).Count
 $syncRate=if($TotalRuns){[math]::Round(100*$syncOK/$TotalRuns,0)}else{0}
 if($ProblemRuns-ge3-or$syncRate-lt70){$overall='Can chu y';$mood='Co vai diem can theo doi.'}
 elseif($ProblemRuns-eq0-and$syncRate-ge90){$overall='Tot';$mood='Node dang chay on dinh.'}
 else{$overall='On dinh';$mood='Tinh trang chung o muc chap nhan duoc.'}
 $report=@"
BAO CAO PI NODE
$(Get-Date -Format 'dd/MM/yyyy HH:mm')

Tong quan: $overall
$mood

Hien tai:
Dong bo: $SyncStatus
Local/Latest: $Local / $Latest
Incoming/Outgoing: $In / $Out
Nhiet do: $Temp C
RAM/CPU: $RAM% / $CPU%
Availability: $Avail
Internet: $AINet
Blockchain: $AIChain

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

$(if($Problems.Count){"Van de luc nay:`n"+(($Problems|ForEach-Object{"- $_"})-join "`n")}else{'Hien tai khong phat hien su co.'})

Smart Monitor v9.0 Portable
"@
 if ($MonitorSelfNotify -and $IsReportHour) { Send-Telegram $report.Trim() }
}

Get-ChildItem $HISTORY_DIR -File -ErrorAction SilentlyContinue|
 Where-Object{$_.LastWriteTime-lt$Now.AddDays(-20)}|
 Remove-Item -Force -ErrorAction SilentlyContinue

Write-Log "Ket qua: Window=$WindowFound Capture=$CaptureMode Sync=$SyncStatus Severity=$Severity Critical=$CriticalCount Warn=$($Warnings.Count) Soft=$($SoftIssues.Count) Temp=$Temp"
Write-Log '========== KET THUC =========='
