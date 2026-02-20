# Talkye Meet — Real-Time Voice Translation for Video Calls

Speak your language, others hear theirs — in your voice.

Join a Zoom/Meet/Teams call. Speak Romanian. The other person hears English — in your voice, in real-time. No interpreter needed. Only you install the app.

## Architecture

```
Flutter UI (tray icon, settings)
    │ flutter_rust_bridge (FFI)
    ▼
Rust Core Engine
    ├── Audio I/O (cpal + virtual devices)
    ├── Deepgram STT (WebSocket streaming)
    ├── Groq LLM Translation
    └── Pocket TTS (voice cloning, local CPU)
```

## Audio Routing

Two virtual audio devices (Krisp-style):
- **Interpreter Mic** — your translated voice → call app sends to others
- **Interpreter Speaker** — call app output → translated to your language → your speakers

Zero feedback loop. Streams are completely separate.

## Project Structure

```
talkye-meet/
├── core/          # Rust crate — translation engine
├── app/           # Flutter UI (coming soon)
├── prototype/     # Python prototype (read-only reference)
└── docs/          # Product documentation
```

## MVP

- Linux + macOS (no Windows — virtual audio requires signed kernel driver)
- RO ↔ EN
- ~2-2.5s latency target (sound-to-sound)
- ~$0.52/hour per direction (Deepgram STT + Groq translate, TTS is free local)

## Setup

```bash
cp .env.example .env
# Edit .env with your API keys

cd core
cargo build
cargo run
```

## License

Proprietary. All rights reserved.
