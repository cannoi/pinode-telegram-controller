# PI NODE CENTRAL CONFIG
# Windows PowerShell 5.1 / Portable
# KHONG LUU TOKEN/API KEY VAO GIT. Dung Setup_Config.ps1 de nhap cau hinh.
# Dien day du cac gia tri ben duoi truoc khi chay Controller / Monitor / Maintenance.

$BotToken = ""
$ChatId = ""

# Gemini Vision API (bat buoc de /monitor doc duoc thong so tu cua so PiCheck)
# Lay key tai: https://aistudio.google.com/apikey
$GeminiApiKey = ""
$GeminiNaturalLanguageEnabled = $true
$GeminiKnowledgeEnabled = $true
$GeminiModels = @(
    # --- Gemini 3.x ---
    "gemini-3.5-flash",
    "gemini-3.1-flash-lite",
    "gemini-3-flash-preview",
    # --- Gemini 2.x ---
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemini-2.5-pro",
    "gemini-2.0-flash",
    "gemini-2.0-flash-lite",
    # --- Gemini 1.5 ---
    "gemini-1.5-flash",
    "gemini-1.5-pro"
)

$HermesContainer = "hermes-agent"
$HermesTimeoutSec = 360
$HermesIncludeNodeContext = $true

$PollingTimeout = 25
$RequestTimeout = 40
$CommandTimeout = 360
$ConfirmTimeout = 120
$MaxTelegramChars = 3900
$MaxLogBytes = 2MB

$RamAlert = 88
$TempAlert = 78
$IncomingLow = 3
$CpuAlert = 90
$WindowKeywords = @("PiCheck", "Pi Network", "Pi Node", "Pi Desktop")
$MonitorSelfNotify = $false  # Controller xu ly alert; monitor khong tu spam

$AppRoot = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $AppRoot 'Data'
$LogDir = Join-Path $AppRoot 'Logs'
$StateDir = Join-Path $AppRoot 'State'
$HistoryFile = Join-Path $DataDir 'node_history.json'
$ChatHistoryFile = Join-Path $DataDir 'chat_history.json'
$ChatHistoryMaxRecords = 500
$ChatHistoryContextTurns = 8
$ControllerLog = Join-Path $LogDir 'controller.log'
$MonitorScript = Join-Path $DataDir 'PiNode_SmartMonitor_v9_CentralConfig.ps1'
$CleanRamScript = Join-Path $DataDir 'CleanRAM_PiNode.ps1'
$MaintenanceScript = Join-Path $DataDir 'Weekly_Maintenance.ps1'
$DiagnosticScript = Join-Path $DataDir 'Pi_Node_Diagnostic_PRO.ps1'
$ResetNodeScript = Join-Path $DataDir 'Reset_Node_Network.ps1'
$ProblemRescanMinutes = 1
$ProblemStreakBeforeReset = 3
$AutoResetOnSyncPortFail = $true
$LedgerAgeMaxSec = 30
$DiskFreeMinGB = 20
$DiskSampleMinutes = 30
$NodeHistoryMaxRecords = 2500
$SendTeleScript = Join-Path $DataDir 'send_tele.ps1'

# Lich trinh: im lang khi an toan; chi Telegram khi Node co van de / loi
# MonitorIntervalMinutes=5: quet dinh ky; khi loi rescan 1 phut (toi da 10 lan day)
$SchedulerEnabled = $true
$MonitorIntervalMinutes = 5
$MonitorRunOnControllerStart = $false
$DailyReportHours = @(7, 18)
$MaintenanceDayOfWeek = 0
$WeeklyMaintenanceTime = '23:00'
$SchedulerNotifyStart = $false
$SchedulerNotifyFinish = $false
$AlertRepeat = 3
$AlertRepeatDelaySec = 2
$AlertPlaySound = $true

$Registered = [ordered]@{
    '/cleanram'     = $CleanRamScript
    '/maintenance'  = $MaintenanceScript
    '/diagnostic'   = $DiagnosticScript
    '/reset'        = $ResetNodeScript
}

foreach ($d in @($DataDir, $LogDir, $StateDir)) {
    New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null
}
