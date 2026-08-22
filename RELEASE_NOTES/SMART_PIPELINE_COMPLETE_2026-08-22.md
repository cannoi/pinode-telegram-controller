# Smart Pipeline COMPLETE checklist (vs proposal)

| # | Proposal item | Status |
|---|---------------|--------|
| 1 | Question Normalizer | Done |
| 2 | Intent Router (RAM/CPU/DOCKER/BLOCK/DIAGNOSIS/...) | Done |
| 3 | Telemetry CURRENT + TREND (gap signed, RAM/CPU trend, events) | Done |
| 4 | Local Rule Engine (works offline) | Done |
| 5 | Trend signals (gap/ram/cpu rising) | Done |
| 6 | Gemini Structured JSON only | Done |
| 7 | Quality Gate (summary/status/evidence/confidence/refuse phrases) | Done |
| 8 | 1x AI retry then fallback | Done |
| 9 | Intent-aware composer (not forced 4 sections) | Done |
| 10 | Action priority HIGH / WATCH | Done |
| 11 | Learning: question_memory, diagnosis_memory, response_memory, anomaly_memory, feedback_log | Done |
| 12 | Memory template fallback when AI fails | Done |
| 13 | Stale telemetry note (>120s) | Done |
| 14 | Wired: STATUS, HEALTH, NODE, DIAGNOSTIC, DOCKER(analysis), STATISTICS(short window) | Done |
| 15 | Scan interval stays 60s (no heavier poll) | Unchanged |

Runtime memory path: Data/SmartMemory/ (do not commit secrets; optional gitignore)
