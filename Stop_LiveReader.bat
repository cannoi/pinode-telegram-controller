@echo off
setlocal
set TASK=PiNodeMonitorLive_Service
schtasks /End /TN "%TASK%" >nul 2>&1
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'PiNodeMonitorLive_Service' } | ForEach-Object { $_.ProcessId }"`) do (
  taskkill /PID %%i /F >nul 2>&1
)
echo Live Reader stopped.
pause
