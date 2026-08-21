# Scan Optimization 2026-08-21

Only the Live Monitor data-collection layer was optimized. Controller commands, Telegram polling, configuration, reset, maintenance, and Pi Node/Docker control logic were not changed.

## Scan policy
- Stellar/Pi Node info + peers: every 60 seconds
- CPU/RAM/VMMEM: every 60 seconds
- Docker health + configured container: every 60 seconds
- Ports 31401/31402/31403: one socket query every 60 seconds
- Temperature: every 5 minutes
- Disk C: usage: every 5 minutes
- Main NDJSON live history: still written every scan
- Legacy `node_history.json` compatibility cache: rewritten every 10 minutes instead of every minute

## Safety
- Read-only monitoring remains read-only.
- No Docker restart/stop/start/remove/configuration operations were added.
- Existing container-name validation remains in use.
- If the lightweight socket API is unavailable, the port check falls back to one `netstat` scan.
