@echo off
chcp 65001 >nul 2>&1
setlocal
cd /d "%~dp0"
title Pi Node Controller - Admin

:: Tự động yêu cầu quyền Administrator
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Dang mo hop thoai UAC - hay chon Yes...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b
)

echo [OK] Dang chay voi quyen Administrator
echo.

:: Ưu tiên Start_Controller.exe
if exist "%~dp0Start_Controller.exe" (
    echo Khoi dong Start_Controller.exe ...
    start "PiNode" /wait "%~dp0Start_Controller.exe"
    exit /b %ERRORLEVEL%
)

:: Fallback: chạy Controller PowerShell trực tiếp
if exist "%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1" (
    echo Khoi dong Controller PowerShell ...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1"
    exit /b %ERRORLEVEL%
)

echo [LOI] Khong tim thay Start_Controller.exe hoac file Controller.
pause
exit /b 1
