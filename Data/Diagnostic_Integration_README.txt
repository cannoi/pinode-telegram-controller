DIAGNOSTIC INTEGRATION

The Diagnostic module intentionally stays in Data.

Controller routing:
  DIAGNOSTIC -> Data\Pi_Node_Diagnostic_PRO.ps1

After it finishes:
  read Data\diagnostic_latest.json

Gemini receives the diagnostic JSON as evidence and explains it.
The Diagnostic script itself is read-only.

Do not move the script into Controller.
Do not make Gemini execute arbitrary PowerShell from user text.
Only allow the Controller's fixed DIAGNOSTIC route to execute this file.
