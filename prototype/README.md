# Talkye Meet

Real-time voice translation for video calls. Speak your language, others hear theirs — in your voice.

## What It Does

You join a Zoom/Meet/Teams call. You speak Romanian. The other person hears English — in your voice, in real-time. No interpreter needed. Only you need the app — zero friction for the other party.

## How It Works

```
Your mic → STT → Translate → TTS (your cloned voice) → Virtual Mic → Call app sends
Call app → Virtual Speaker → STT → Translate → TTS → Your speakers
```

The app creates virtual audio devices on your system. You set your call app to use them. Two independent pipelines handle outgoing and incoming translation.

## Tech Stack

- **Rust** — core engine (audio capture, STT streaming, translation, TTS)
- **Flutter** — cross-platform UI (tray icon, settings, voice enrollment)
- **Deepgram** — streaming speech-to-text (Nova-3)
- **Groq** — LLM translation (Llama 3.3 70B)
- **Pocket TTS** — voice cloning, local CPU, streaming (`pocket-tts` Rust crate)

## Project Structure

```
talkye-meet/
├── core/               # Rust crate — engine
│   ├── src/
│   │   ├── lib.rs      # Public API
│   │   ├── audio.rs    # Audio capture + virtual devices
│   │   ├── stt.rs      # Deepgram WebSocket client
│   │   ├── translate.rs # LLM translation
│   │   ├── tts.rs      # Pocket TTS wrapper
│   │   └── pipeline.rs # Orchestration
│   └── Cargo.toml
├── app/                # Flutter UI (Phase 2)
├── docs/               # Product & technical docs
└── README.md
```

## Status

Early development. Core engine in progress.

See [docs/](docs/) for product vision, architecture decisions, and cost analysis.

## Platforms

- **Linux** (PulseAudio/PipeWire) — primary
- **macOS** — Phase 2 (BlackHole for virtual audio)
- Windows — deferred (virtual audio requires signed kernel driver)

## Cost

~$0.52/hour per direction. TTS is free (runs locally). See [docs/cost-analysis.md](docs/cost-analysis.md).

## License

Proprietary. All rights reserved.
