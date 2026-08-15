@echo off
cd /d "%~dp0"
set TASKNAME=PiNode Telegram Controller PRO
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
%PS% -NoProfile -ExecutionPolicy Bypass -Command "$action=New-ScheduledTaskAction -Execute '%PS%' -Argument '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"%~dp0Controller\PiNode_Telegram_Controller_PRO_v2.0.ps1\"'; $trigger=New-ScheduledTaskTrigger -AtLogOn; $principal=New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest; $settings=New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1); Register-ScheduledTask -TaskName '%TASKNAME%' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null"
schtasks /run /tn "%TASKNAME%" >nul 2>&1
echo Controller start requested.
pause
