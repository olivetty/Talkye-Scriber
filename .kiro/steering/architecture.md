---
inclusion: auto
---

# Architecture Reference — Talkye Meet

## What This Is

Real-time voice translation for video calls. Rust core engine, Flutter UI (future).
Prototype in `prototype/test_deepgram.py` is the working reference implementation.

## Project Layout

```
talkye-meet/
├── core/              # Rust crate — translation engine
│   └── src/
│       ├── config.rs          # All .env config, single source of truth
│       ├── audio/
│       │   ├── capture.rs     # Mic input (cpal)
│       │   ├── playback.rs    # Speaker output (cpal)
│       │   └── virtual_device.rs  # PulseAudio null-sinks (Phase 2)
│       ├── stt.rs             # Deepgram WebSocket streaming
│       ├── translate.rs       # Groq LLM translation + context
│       ├── tts.rs             # Pocket TTS voice cloning
│       └── pipeline.rs        # Orchestration + accumulator
├── app/               # Flutter UI (Phase 4)
├── voices/            # Voice clone samples (oliver.wav)
├── prototype/         # Python prototype (read-only reference)
├── docs/              # Product docs, architecture
└── .env               # Command center — all config here
```

## Data Flow (Phase 1 — CLI)

```
Mic (cpal) →[AudioChunk]→ Deepgram STT →[SttEvent]→ Accumulator
  →[text]→ Parallel Translator (3 concurrent, ordered) →[translated]→ TTS →[PCM]→ Speaker
```

All arrows are `tokio::mpsc` channels. Components are independent.

## Current Phase: Phase 1 (CLI Pipeline)

Goal: `cargo run` → speak Romanian → hear English on speakers.
Same behavior as `prototype/test_deepgram.py`.

## Phases Overview

1. **CLI Pipeline** — replicate prototype in Rust (CURRENT)
2. **Virtual Audio** — PulseAudio null-sinks, works with Zoom
3. **Bidirectional** — incoming + outgoing translation
4. **Flutter UI** — system tray, settings, voice enrollment

## Audio Decision: cpal (not parecord/paplay)

cpal compiles into the binary. User installs app → it works.
No dependency on PulseAudio CLI tools being installed.
Cross-platform: Linux (ALSA/PulseAudio/PipeWire) + macOS (CoreAudio).

## Critical Algorithms (from prototype)

1. **Accumulator**: first flush at 4 words, then 8 words, immediate on speech end
2. **Parallel translation**: 3 workers, sequence numbers, ordered output to TTS
3. **Translation context**: segment_fragments (intra-utterance) + sliding window (cross-utterance, size 4)
4. **TTS streaming**: chunks played sequentially, never dropped

## API Keys Required

- `DEEPGRAM_API_KEY` — streaming STT (~$0.46/hr)
- `GROQ_API_KEY` — translation (~$0.06/hr)
- Pocket TTS — free, local, no key needed
