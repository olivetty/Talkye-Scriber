# Dictate — Documentation

This project has three main components:

| Component | File | Description |
|---|---|---|
| [Desktop Dictation](desktop-dictation.md) | `desktop.py` | Push-to-talk / wake word dictation — hold a key, speak, text appears at cursor |
| [Live Translation](live-translation.md) | `test_deepgram.py` | Real-time speech translation pipeline — speak Romanian, hear English |
| [Wake Word Training](wake-word-training.md) | `train_wakeword.py` | Train custom wake word models (.onnx) for hands-free activation |
| [Cost Analysis](cost-analysis.md) | — | Per-component pricing, scenarios, monthly estimates |
| [Product: Live Interpreter](product-live-interpreter.md) | — | Product vision, competition, MVP scope, roadmap |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                        core.py                          │
│              audio bytes → text pipeline                │
│  Transcribe (Groq/OpenAI/Local) → LLM Cleanup → Translate │
└────────────────────────┬────────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
    ┌─────┴─────┐  ┌─────┴─────┐  ┌────┴────────────┐
    │desktop.py │  │ server.py │  │test_deepgram.py  │
    │Dictation  │  │ REST API  │  │Live Translation  │
    │PTT/Wake   │  │ WebSocket │  │RO→EN pipeline    │
    └───────────┘  └───────────┘  └──────────────────┘
```

## Quick Setup

```bash
git clone https://github.com/olivetty/dictate.git
cd dictate
sudo ./setup.sh          # installs deps, creates venv, sets up systemd
cp .env.example .env     # edit with your API keys
```

## Requirements

- Ubuntu Linux (tested on 24.04)
- Python 3.10+
- PulseAudio/PipeWire
- API keys: Groq (free), Deepgram (for live translation)
