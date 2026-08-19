PiNodeMonitorLive_CMD_v2

PRIORITY:
1. Stellar/Docker (primary)
2. Windows hardware
3. Ports
4. Pi Desktop clipboard (optional, only if Docker fails)

CYCLE (all 60 seconds):
- Node (Stellar info/peers): 60s
- Hardware CPU/RAM/Temp/Disk/VMMEM: 60s
- Ports 31401-31403: 60s
- Write latest.json / history: 60s

Missing data never becomes 0.
Temp: assets\OpenHardwareMonitorLib.dll OR Data\OpenHardwareMonitorLib.dll

Writes:
  Data\PiNodeMonitorLive\latest.json
  Data\PiNodeMonitorLive\history\
  Data\node_history.json
  Data\History\Node\

Run: Run-PiNodeMonitor.bat | Service: Run-PiNodeMonitorLive_Service.bat

PORT (must match Controller):
  port = "OPEN"   when 31401+31402+31403 all LISTEN
  port = "CLOSED" otherwise
  Check: Get-NetTCPConnection -State Listen, fallback netstat
