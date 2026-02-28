---
inclusion: auto
---

# Architecture Reference — Talkye Scriber

## Ce este

Aplicație de dictation desktop. Vorbești, textul apare la cursor.
Push-to-talk sau wake word. Funcționează cu orice aplicație.

## Arhitectura

```
Flutter UI (desktop)
    │ HTTP (localhost:8179)
    ▼
Python Sidecar (FastAPI/Uvicorn)
    ├── STT (Groq Whisper / local whisper.cpp)
    ├── Grammar fix (Groq LLM)
    ├── Translate to English (Groq LLM)
    ├── Wake word detection (custom ONNX models)
    ├── Voice commands (enter, delete, undo, etc.)
    └── Audio capture (pw-record / arecord)
```

Flutter UI e doar interfața. Toată logica e în Python sidecar.

## Sidecar API (port 8179)

- `GET /health` — status check
- `GET /dictate/status` — running, recording, busy, language, mode
- `POST /dictate/config` — update settings (trigger_key, sound_theme, etc.)
- `POST /dictate/preview-sound` — preview sound theme
- `POST /wakeword/record-sample` — record wake word training sample
- `DELETE /wakeword/samples` — clear training samples
- `POST /wakeword/build` — build wake word model from samples

## API Keys

- GROQ_API_KEY — STT (Whisper) + grammar fix + translate
- Nu are nevoie de Deepgram, HF_TOKEN, sau alte chei

## NU folosește

- Rust core engine (core/) — NU
- flutter_rust_bridge — NU (de eliminat)
- Parakeet STT — NU (sidecar-ul are propriul STT)
- Pocket TTS — NU
- ONNX models din models/ — NU (wake word models sunt în sidecar)
