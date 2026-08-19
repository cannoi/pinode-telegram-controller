@echo off
setlocal
set SCRIPT=%~dp0Data\PiNodeMonitorLive_CMD_v2\PiNodeMonitorLive_Service.ps1
set TASK=PiNodeMonitorLive_Service

schtasks /Query /TN "%TASK%" >nul 2>&1
if %ERRORLEVEL%==0 schtasks /Delete /TN "%TASK%" /F >nul 2>&1

schtasks /Create /TN "%TASK%" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%SCRIPT%\"" /SC ONLOGON /RL HIGHEST /F
if errorlevel 1 (
  echo Failed to create Task Scheduler entry. Run as Administrator.
  pause
  exit /b 1
)
echo OK: Task "%TASK%" created - runs at logon.
echo Starting once now...
schtasks /Run /TN "%TASK%"
echo Live Reader is independent from Controller.
pause
