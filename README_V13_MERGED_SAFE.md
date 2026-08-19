# Pi Node Telegram Controller PRO — V12 Base + V13 Improvements (Safe Merge)

## Architecture
- V12 startup flow is preserved: `Start_Controller.bat` opens the Live Data CMD and then the Telegram Controller CMD.
- V12 Live Data acquisition remains the primary collector. Its Docker `stellar-core`, Windows/CIM, OpenHardwareMonitor and port checks are preserved.
- Controller does not start a second Live Reader when launched by `Start_Controller.bat` (`PINODE_LIVE_EXTERNAL=1`).

## Resource optimization
- Normal collection: 60 seconds (fixed).
- Problem retry: also 60 seconds (no denser rescan for data collector).
- Disk: 10 minutes.
- Docker VHDX: 30 minutes.
- Hardware information: once at startup.
- The Live CMD no longer redraws every second; it redraws only when a scheduled sample is collected.
- Controller reads `latest.json`/NDJSON instead of recollecting Node metrics.

## V13 improvements retained
- Telegram `/settings container <name>` with `testnet2` example and saved `container_name.txt`.
- Docker/container error guidance.
- Alert modes: `on`, `off`, `night` (22:00–07:00).
- Main Telegram button uses `📷 Capture` for `/screenshot`.
- `/monitor` remains the backup image + Gemini Vision verification path.
- Smart Pi Desktop/window capture with full-desktop fallback.
- Natural-language intent routing and evidence-based answers.
- Raw NDJSON history plus hourly/daily retention support.
- Diagnostic/history readers use Live NDJSON.

## Important
Run `Start_Controller.exe` or `Start_Controller.bat` only. Do not manually start the legacy Live Service task at the same time.
