# Smart Question Pipeline 2026-08-22

## Module
`Modules/Smart_Pipeline.ps1`

## Layers
1. Question Normalizer
2. Intent Router (local): RAM, CPU, DOCKER, BLOCK_SYNC, NODE_HEALTH, DIAGNOSIS, ...
3. Telemetry Context: CURRENT + trend window (gap, RAM/CPU delta, events)
4. Local Rule Engine (works without Gemini)
5. Gemini Structured JSON analysis
6. Quality Gate (schema/status/evidence/confidence)
7. Learning Memory under `Data/SmartMemory/`
8. Response Composer (intent-aware, not fixed 4-section)

## Wired into Controller
- Natural language intents: STATUS, HEALTH, NODE, DIAGNOSTIC
- Fallback local intent for "tai sao / lech block / on dinh"

## Memory files (runtime, gitignore recommended)
- question_memory.json
- diagnosis_memory.json
- feedback_log.jsonl
