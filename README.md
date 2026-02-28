# Talkye Scriber

Desktop dictation app — speak and it types. Linux-first, built with Flutter + Python sidecar.

## What it does

- Push-to-talk or VAD (voice activity detection) dictation
- Real-time speech-to-text via Deepgram (cloud) through Python sidecar
- Keyboard shortcut trigger (configurable)
- Auto-paste into any focused application
- Optional LLM post-processing (grammar fix, translation)

## Architecture

```
Flutter Desktop App  ←→  Python Sidecar (http://127.0.0.1:8179)
     (UI, PTT)              (STT, VAD, LLM post-processing)
```

The Flutter app handles UI and keyboard input. The Python sidecar (FastAPI/Uvicorn) handles all audio capture, speech recognition, and text processing.

## Build

```bash
cd app
flutter pub get
flutter build linux
```

The sidecar starts automatically when the app launches. It looks for `sidecar/` relative to the binary.

## Requirements

- Flutter SDK 3.11+
- Python 3.11+ with venv
- Linux (X11/Wayland with xdotool for auto-paste)
- Deepgram API key (configured in sidecar)
