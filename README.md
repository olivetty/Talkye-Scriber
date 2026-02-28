# Talkye Scriber

Desktop dictation app — speak and it types. Push-to-talk, local STT, works everywhere.

## How it works

Hold a key → speak → release → text appears at your cursor. Works in any app.

```
Flutter Desktop App  ←→  Python Sidecar (localhost:8179)
     (UI, settings)         (audio capture, STT, LLM post-processing)
```

- STT: local whisper.cpp (GPU-accelerated, no cloud dependency)
- LLM post-processing (optional): Groq API for grammar fix and translation
- Voice commands: say "enter", "delete", "undo", "select all" in any language
- Sound feedback: configurable themes (subtle beeps, voice cues, or silent)

## Build & Run

```bash
cd app
flutter pub get
flutter build linux
```

The sidecar starts automatically with the app. It runs `sidecar/server.py` via uvicorn on port 8179.

## Requirements

- Flutter SDK 3.11+
- Python 3.11+ with venv
- Linux (X11 with xdotool + xclip for auto-paste)
- whisper.cpp built locally (for local STT)
- Groq API key (optional, only for grammar fix / translate features)

## Project Structure

```
app/          Flutter desktop app (UI, system tray, settings)
sidecar/      Python backend (FastAPI, audio, STT, keyboard listener)
docs/         Documentation
```
