# Talkye Scriber — Docs

Documentation for the Scriber dictation app.

## Architecture

```
Flutter App (UI) ←→ Python Sidecar (localhost:8179)
```

The Flutter app provides the UI and manages the sidecar process lifecycle.
The Python sidecar handles audio capture, speech-to-text, and text output.

## STT Pipeline

```
keyboard.py (evdev/pynput PTT listener)
  → audio.py (pw-record microphone capture)
  → transcribe.py (whisper.cpp local STT, Groq fallback)
  → commands.py (voice command detection via LLM)
  → core.py (optional LLM grammar fix / translation)
  → platform_utils.py (paste via xclip + xdotool)
```

## Settings

Settings are stored in `~/.config/talkye/settings.json` and synced between
the Flutter app and sidecar at runtime via `POST /dictate/config`.
