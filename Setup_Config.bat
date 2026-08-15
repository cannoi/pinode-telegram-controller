@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Nhap Key - Pi Node Controller
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup_Config.ps1"
if errorlevel 1 pause
