---
inclusion: auto
---

# Project Structure — Talkye (Multi-Branch)

## Branches

Acest repo conține două produse separate, fiecare pe branch-ul lui:

| Branch | Produs | Descriere |
|---|---|---|
| `main` | Snapshot complet | Codul original cu tot — safety net, nu se lucrează direct pe el |
| `scriber` | Talkye Scriber | Dictation app — push-to-talk / wake word, text la cursor |
| `meet-assist` | Talkye Meet | AI Meeting Assistant — diarizare, transcript, summary, export |

## Talkye Scriber (branch: `scriber`)

Aplicație de dictation. Vorbești, textul apare la cursor. Funcționează cu orice aplicație.

Arhitectura:
- Flutter desktop UI (dictate screen, chat screen, settings)
- Python sidecar (`sidecar/server.py`) pe `http://127.0.0.1:8179`
- Sidecar-ul face: STT (Groq/local whisper), grammar fix, translate, wake word, voice commands
- Flutter comunică cu sidecar-ul prin HTTP (GET/POST)
- NU folosește Rust core engine

Build:
```bash
cd app
flutter build linux
```

Componente:
- `app/lib/screens/dictate_screen.dart` — ecranul principal (PTT, VAD, language, sound)
- `app/lib/screens/chat_screen.dart` — chat cu LLM
- `app/lib/screens/settings_screen.dart` — diagnostics, about
- `app/lib/screens/key_picker_dialog.dart` — keyboard trigger picker
- `app/lib/sidebar.dart` — navigare (Scriber, Chat, Settings)
- `app/lib/main.dart` — app shell, sidecar management, system tray
- `sidecar/` — Python server (FastAPI/Uvicorn)

## Talkye Meet (branch: `meet-assist`)

AI Meeting Assistant. Înregistrează meeting-uri, identifică speakerii, transcrie, summary, export.

Arhitectura:
- Flutter desktop UI
- Rust core engine (`core/`) via flutter_rust_bridge FFI
- Audio capture → VAD → STT → Diarizare → Transcript → Summary → Export
- Totul local, fără bot în meeting

Build:
```bash
cd app
flutter build linux --release
```

Componente core (Rust):
- `core/src/audio/` — audio capture (cpal)
- `core/src/vad.rs` — Silero VAD V5
- `core/src/stt/` — Parakeet TDT / Deepgram
- `core/src/diarize.rs` — WeSpeaker embeddings (NOU)
- `core/src/session.rs` — meeting session store (NOU)
- `core/src/summary.rs` — LLM summary via Groq (NOU)
- `core/src/export.rs` — POST to endpoint (NOU)

Documentație: `docs/meeting-assistant-design.md`, `docs/architecture.md`

## Reguli

- Nu lucra niciodată direct pe `main` — e safety net
- Fiecare branch evoluează independent
- Dacă ceva se strică: `git checkout main` are totul funcțional
- User-ul comunică în română prin Scriber — Scriber trebuie să funcționeze mereu
