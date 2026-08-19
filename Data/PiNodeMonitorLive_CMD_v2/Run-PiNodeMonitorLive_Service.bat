@echo off
cd /d "%~dp0"
title Pi Node Monitor Live Service
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PiNodeMonitorLive_Service.ps1" -ShowWindow
pause
