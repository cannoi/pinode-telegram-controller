@echo off
cd /d "%~dp0"
set ERR=0
for %%F in ("Config\PiNode_Config.ps1" "Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1" "Data\PiNode_SmartMonitor_v9_CentralConfig.ps1" "Data\CleanRAM_PiNode.ps1" "Data\Weekly_Maintenance.ps1" "Data\Diagnostic.ps1" "Commands\commands.json") do if exist "%%~F" (echo [OK] %%~F) else (echo [ERROR] Missing %%~F& set ERR=1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content '.\Config\PiNode_Config.ps1' -Raw; if($c -match '8930360506:'){Write-Host '[WARNING] Telegram token appears hard-coded.' -ForegroundColor Yellow}; if($c -match '\$HermesContainer\s*=\s*\"hermes-agent\"'){Write-Host '[OK] Hermes=hermes-agent'}"
if %ERR%==0 (echo CHECK PASSED) else (echo CHECK FAILED)
pause
exit /b %ERR%
