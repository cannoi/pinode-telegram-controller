# Session upgrades 2026-08-21 (vs SECURE 2026-08-19 base)

## Added modules
| File | Role |
|------|------|
| Modules/Admin_Elevate.ps1 | Elevate to Administrator once (UAC) |
| Modules/Command_Confirm.ps1 | Live-window Y/N for /reset, /maintenance, /ps, /cmd (non-blocking) |
| Modules/Telegram_Menu.ps1 | After ~45s, if menu missing -> ask /confirmmenu |
| Modules/Set_Bot_Menu.ps1 | setMyCommands (token+ChatId params, Admin); multi-scope |
| Modules/Stop_All_PiNode.ps1 | Stop Controller + Live + related scripts |

## Changed
| File | Change |
|------|--------|
| Controller/PiNode_Telegram_Controller_PRO_v2.0.ps1 | Load modules at **script scope**; resilient loop (Telegram first); Live confirm handlers; stop-all; menu bootstrap |
| Data/PiNodeMonitorLive_CMD_v2/PiNodeMonitorLive.ps1 | pending_action Y/N UI; on close Live -> stop related processes |
| Modules/Security_Guard.ps1 | UTF-8 BOM (encoding-safe) |

## Behaviour summary
- /reset, /maintenance, /ps, /cmd: confirm on **Live CMD window** (Y/N), Controller keeps polling
- /confirmmenu: runs Set_Bot_Menu.ps1 as Admin with Config token/ChatId
- /confirmstop or close Live window: stop all related app processes
- Module load fixed (dot-source must NOT be inside a function in PS 5.1)

## Notes
- Keep Config/PiNode_Config.ps1 private (not required in this delta if unchanged)
- After setMyCommands: force-stop Telegram app to refresh command menu cache
