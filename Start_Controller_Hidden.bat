@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
  exit /b
)

set "LIVE_PS1=%~dp0Data\PiNodeMonitorLive_CMD_v2\PiNodeMonitorLive.ps1"
if exist "%LIVE_PS1%" (
  powershell.exe -NoProfile -Command "if (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'PiNodeMonitorLive\.ps1' }) { exit 0 } else { exit 1 }"
  if %errorLevel% neq 0 (
    start "Pi Node Monitor Live" cmd /k powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LIVE_PS1%"
    timeout /t 5 /nobreak >nul
  )
)

powershell.exe -NoProfile -Command "if (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'PiNode_Telegram_Controller_PRO' }) { exit 0 } else { exit 1 }"
if %errorLevel%==0 exit /b 0

start "Pi Node Controller" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "Set-Location -LiteralPath '%~dp0'; $env:PINODE_LIVE_EXTERNAL='1'; $env:PINODE_LIVE_DASHBOARD='1'; & '%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1'"
exit /b 0
