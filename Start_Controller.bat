@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Pi Node Controller

:: --- Tu dong xin quyen Administrator (UAC) ---
net session >nul 2>&1
if %errorLevel% neq 0 (
  echo Dang yeu cau quyen Administrator...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
  exit /b
)

color 0A
echo.
echo ========================================
echo   PI NODE TELEGRAM CONTROLLER
echo   ^(Dang chay voi quyen Administrator^)
echo ========================================
echo.
echo  Thu muc: %cd%
echo.

if not exist "Config\PiNode_Config.ps1" (
  echo [LOI] Thieu Config\PiNode_Config.ps1
  pause
  exit /b 1
)
if not exist "Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1" (
  echo [LOI] Thieu file Controller
  pause
  exit /b 1
)

echo  Key mien phi: BotFather + Google AI Studio
echo.
echo  Chon thao tac:
echo.
echo    [1] Nhap / sua Key
echo    [2] Chay Controller
echo    [3] Nhap Key roi chay Controller
echo.
echo  Nhan 1, 2 hoac 3 roi Enter
echo  ^(Enter trong = 3^)
echo.
set "CHON=3"
set /p "CHON=  Ban chon: "

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
echo --- Buoc 1: Nhap Key ---
call "%~dp0Setup_Config.bat"
echo.
echo --- Buoc 2: Chay Controller ---
echo.

:RUN
echo Dang khoi dong Controller ^(Admin^)...
echo Cua so nay se giu mo.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1"
echo.
echo Controller da dung. Ma loi: %ERRORLEVEL%
if not "%ERRORLEVEL%"=="0" echo Xem Logs\controller.log
echo.
pause
exit /b %ERRORLEVEL%
