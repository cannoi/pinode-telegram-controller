@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Pi Node Controller

:: --- Admin UAC ---
net session >nul 2>&1
if %errorLevel% neq 0 (
  echo Requesting Administrator...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
  exit /b
)

color 0A
echo.
echo ========================================
echo   PI NODE TELEGRAM CONTROLLER
echo   (Administrator)
echo ========================================
echo.
echo  Folder: %cd%
echo.

if not exist "Config\PiNode_Config.ps1" (
  echo [ERROR] Missing Config\PiNode_Config.ps1
  pause
  exit /b 1
)
if not exist "Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1" (
  echo [ERROR] Missing Controller script
  pause
  exit /b 1
)

echo  Free keys: BotFather + Google AI Studio
echo.
echo  Choose:
echo    [1] Edit keys
echo    [2] Run Controller only
echo    [3] Edit keys then run
echo.
set "CHON=3"
set /p "CHON=  Select: "

if "%CHON%"=="1" goto SETUP_ONLY
if "%CHON%"=="2" goto RUN
goto SETUP_THEN_RUN

:SETUP_ONLY
echo.
call "%~dp0Setup_Config.bat"
echo.
pause
exit /b 0

:SETUP_THEN_RUN
echo.
echo --- Step 1: Keys ---
call "%~dp0Setup_Config.bat"
echo.
echo --- Step 2: Start ---
echo.

:RUN
echo.
echo [1/2] Starting Live Monitor (CMD window + App data)...
set "LIVE_PS1=%~dp0Data\PiNodeMonitorLive_CMD_v2\PiNodeMonitorLive.ps1"
if not exist "%LIVE_PS1%" (
  echo [WARN] Live Monitor not found: %LIVE_PS1%
  echo        Controller will still start.
  goto START_CTRL
)

:: If already running, skip
powershell.exe -NoProfile -Command "if (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'PiNodeMonitorLive\.ps1' }) { exit 0 } else { exit 1 }"
if %errorLevel%==0 (
  echo        Live Monitor already running.
  goto START_CTRL
)

start "Pi Node Monitor Live" cmd /k powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LIVE_PS1%"
echo        Waiting 5 seconds to confirm Live Monitor...
timeout /t 5 /nobreak >nul

powershell.exe -NoProfile -Command "if (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'PiNodeMonitorLive\.ps1' }) { exit 0 } else { exit 1 }"
if %errorLevel%==0 (
  echo        [OK] Live Monitor is running.
) else (
  echo        [WARN] Live Monitor may not have started. Check the CMD window.
)

:START_CTRL
echo.
set "PINODE_LIVE_EXTERNAL=1"
set "PINODE_LIVE_DASHBOARD=1"

echo [2/2] Starting Controller...
echo This window stays open.
echo.
start "" powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1"

exit /b 0

echo.
echo Controller stopped. Exit code: %ERRORLEVEL%
if not "%ERRORLEVEL%"=="0" echo See Logs\controller.log
echo.
pause
exit /b %ERRORLEVEL%
