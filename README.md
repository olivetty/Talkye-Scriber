# Talkye Scriber

Voice-to-text dictation for Linux. Hold a key, speak, release — text appears at your cursor. Works in any app.

![Talkye Scriber](https://github.com/olivetty/Talkye-Scriber/raw/scriber/app-icon.png)

## Download

### Snap Store (Ubuntu / any distro with snapd)

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/talkye-scriber)

**[View on Snap Store](https://snapcraft.io/talkye-scriber)**

```bash
sudo snap install talkye-scriber
```

### .deb (Ubuntu / Debian / Mint / Pop!_OS)

**[Download .deb package](https://github.com/olivetty/Talkye-Scriber/releases/latest)**

```bash
sudo dpkg -i talkye-scriber_*_amd64.deb
talkye-scriber
```

Installs to `/opt/talkye-scriber/`, adds a desktop entry, and puts `talkye-scriber` in your PATH. Updates install via the app with a single password prompt.

### AppImage (any Linux distro)

**[Download AppImage](https://cdn.talkye.com/TalkyeScriber-x86_64.AppImage)**

```bash
chmod +x TalkyeScriber-x86_64.AppImage
./TalkyeScriber-x86_64.AppImage
```

No installation needed. Self-contained, runs on any distro.

Both packages bundle everything — Python runtime, whisper.cpp, audio tools. On first launch the app downloads the speech model (~1.6 GB, one time only).

## What it does

- Push-to-talk dictation: hold Right Ctrl (configurable), speak, release — text is typed at your cursor position
- Works in any application — browser, terminal, IDE, chat apps, anything
- Speech-to-text runs 100% locally via whisper.cpp (large-v3-turbo model, GPU-accelerated)
- No cloud dependency for transcription — your voice never leaves your machine
- Voice commands: say "enter", "delete", "undo", "select all", "new line" in any language
- Optional LLM post-processing via Groq API (free tier): grammar fix and translation to English
- Configurable sound feedback: subtle beeps, voice cues (Alex/Emma), or silent
- Auto-updates: the app checks for new versions and updates itself in seconds
- System tray integration with show/hide toggle
- Runs as a single instance — clicking the icon again brings the existing window to front

## Requirements

- Linux x86_64 (tested on Ubuntu 24.04, should work on most distros)
- X11 with `xdotool` and `xclip` (for typing text at cursor)
- PipeWire or PulseAudio (for microphone access)
- ~2 GB disk space (app + speech model)
- A microphone

## How it works

```
┌─────────────────────┐     localhost:8179     ┌──────────────────────────┐
│   Flutter App (UI)  │ ◄──────────────────► │   Python Sidecar (API)   │
│                     │                        │                          │
│  • Settings         │                        │  • Keyboard listener     │
│  • System tray      │                        │  • Audio capture         │
│  • Auto-updater     │                        │  • whisper.cpp STT       │
│  • Desktop entry    │                        │  • Voice commands (LLM)  │
└─────────────────────┘                        │  • Text output (xdotool) │
                                               └──────────────────────────┘
```

The Flutter app manages the UI and lifecycle. A Python sidecar handles the heavy lifting — listening for the push-to-talk key, capturing audio, running speech-to-text through whisper.cpp, and typing the result at your cursor via xdotool.

## Building from source

### Prerequisites

- Flutter SDK 3.11+
- Python 3.11+
- whisper.cpp (build from `whisper.cpp/` directory)
- sox, xdotool, xclip

### Build

```bash
# Build the Flutter app
cd app
flutter pub get
flutter build linux --release

# Set up the Python sidecar
cd ../sidecar
./setup.sh
```

### Build AppImage

```bash
./build-appimage.sh
```

### Build .deb

```bash
./build-deb.sh
```

## Project structure

```
app/          Flutter desktop app (UI, system tray, auto-updater)
sidecar/      Python backend (FastAPI — audio, STT, keyboard, voice commands)
whisper.cpp/  Local whisper.cpp build (not tracked in git)
```

## License

MIT
