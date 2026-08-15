@echo off
cd /d "%~dp0"
start "PiNode Controller" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1"
