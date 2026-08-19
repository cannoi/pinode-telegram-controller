@echo off
chcp 65001 >nul 2>&1
title Pi Node Monitor Live v2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PiNodeMonitorLive.ps1"
pause
