@echo off
cd /d "%~dp0"
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -Command "if(Test-Path '.\State\controller.pid'){(Get-Content '.\State\controller.pid' -Raw).Trim()}"`) do set PID=%%P
if defined PID powershell.exe -NoProfile -Command "Stop-Process -Id %PID% -Force -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -Command "$p=Get-CimInstance Win32_Process|Where-Object {$_.CommandLine -match 'PiNode_Telegram_Controller_PRO_v2.0.ps1'}; $p|ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}"
echo Controller stop requested.
