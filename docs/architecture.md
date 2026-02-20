# Talkye Meet — Architecture

Real-time voice translation for video calls. Speak your language, others hear theirs — in your voice.

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Flutter UI (Phase 4)                                           │
│  System tray · on/off · language selector · voice enrollment    │
└──────────────────────┬──────────────────────────────────────────┘
                       │ flutter_rust_bridge (FFI)
┌──────────────────────▼──────────────────────────────────────────┐
│  Rust Core Engine (core/)                                       │
│                                                                 │
│  config.rs ─── All settings from .env, single source of truth   │
│                                                                 │
│  audio/                                                         │
│  ├── capture.rs ──── Mic input via cpal (16kHz mono PCM)        │
│  ├── playback.rs ─── Speaker output via cpal                    │
│  └── virtual_device.rs ── PulseAudio null-sinks (Phase 2)       │
│                                                                 │
│  stt.rs ─────── Deepgram Nova-3 WebSocket streaming client      │
│  translate.rs ── Groq LLM translation with context window       │
│  tts.rs ─────── Pocket TTS voice cloning (local CPU, free)      │
│  pipeline.rs ── Orchestration: accumulator + parallel translate  │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow (Phase 1 — CLI)

```
Mic (cpal)
  │ AudioChunk (Vec<u8>, 16-bit PCM, 16kHz mono)
  ▼
Deepgram STT (WebSocket)
  │ SttEvent (Interim | Final { words, speech_final } | UtteranceEnd)
  ▼
Accumulator (in pipeline.rs)
  │ Collects words from Finals
  │ First flush: 4 words (fast response)
  │ Subsequent: 8 words (better quality)
  │ Immediate flush on speech_final / utterance_end
  ▼
Parallel Translator (3 concurrent, ordered output)
  │ String (translated text)
  ▼
Pocket TTS (streaming, voice clone)
  │ PCM f32 chunks
  ▼
Speaker (cpal)
```

Every arrow is a `tokio::mpsc` channel. Components don't know about each other — only the pipeline connects them.

## Data Flow (Phase 2+3 — Call Integration)

```
OUTGOING (you → them):
  Real Mic → STT → Translate(RO→EN) → TTS(your voice) → Virtual Mic → Zoom sends

INCOMING (them → you):
  Zoom → Virtual Speaker → STT → Translate(EN→RO) → TTS(default) → Real Speakers
```

Two independent pipeline instances. Zero feedback loop:
- Outgoing TTS → virtual mic only (Zoom hears, you don't)
- Incoming TTS → real speakers only (you hear, Zoom doesn't)

## Phase Roadmap

### Phase 1: CLI Pipeline ← CURRENT
Replicate `prototype/test_deepgram.py` in Rust.
- `cargo run` → speak Romanian → hear English on speakers
- Voice clone with Oliver's voice
- Same accumulator logic, same latency target (~2-2.5s)
- Parallel translation with ordered output

Deliverable: working CLI binary, same behavior as Python prototype.

### Phase 2: Virtual Audio Devices
- Create PulseAudio null-sinks on startup, remove on exit
- Route TTS output to virtual mic (call app reads it)
- User sets "Interpreter Mic" + "Interpreter Speaker" in Zoom once

Deliverable: works with any video call app on Linux.

### Phase 3: Bidirectional Translation
- Two pipeline instances running in parallel
- Incoming: virtual speaker monitor → STT → translate → TTS → speakers
- Language pair configurable per direction

Deliverable: full duplex — both sides hear translations.

### Phase 4: Flutter UI
- flutter_rust_bridge FFI
- System tray icon with on/off toggle
- Language selector, voice enrollment
- Status: connected, translating, error
- Settings persistence

Deliverable: installable desktop app.

## Key Decisions

| Decision | Choice | Why |
|---|---|---|
| Audio I/O | cpal | Cross-platform, compiles into binary, no external deps. User installs app and it works — no need for parecord/paplay. |
| Virtual devices | libpulse-binding | Programmatic PulseAudio control. No shelling out to pactl. |
| Config format | .env (dotenvy) | Simple, proven, user edits one file. Works for dev and production. |
| Translation concurrency | 3 parallel + ordered | Matches prototype. Reduces latency when multiple fragments queue up. |
| TTS engine | pocket-tts (Rust crate) | Voice cloning, streaming, CPU-only, MIT, no API costs. |
| STT | Deepgram Nova-3 | Best streaming accuracy, good endpointing, $0.0077/min. |
| LLM | Groq (Llama 3.3 70B) | ~150-300ms per request, cheap, good translation quality. |

## Module Responsibilities

| File | Responsibility | Depends on |
|---|---|---|
| `config.rs` | Load .env, validate, expose typed Config struct | nothing |
| `audio/capture.rs` | Open mic, stream PCM chunks via channel | config |
| `audio/playback.rs` | Receive PCM chunks, play on speaker/device | config |
| `audio/virtual_device.rs` | Create/destroy PulseAudio null-sinks | config (Phase 2) |
| `stt.rs` | Deepgram WebSocket: send audio, emit SttEvents | config |
| `translate.rs` | Groq API: translate text with context window | config |
| `tts.rs` | Pocket TTS: text → PCM stream with voice clone | config |
| `pipeline.rs` | Wire everything: accumulator + parallel translate | all above |

## Prototype Mapping

| Python (prototype/) | Rust (core/src/) | Notes |
|---|---|---|
| `test_deepgram.py` main() | `pipeline.rs` Pipeline::run() | Entry point, wiring |
| `test_deepgram.py` on_message() | `stt.rs` SttClient::run() | Deepgram event parsing |
| `test_deepgram.py` flush_accum() | `pipeline.rs` accumulator logic | Word accumulation + threshold |
| `test_deepgram.py` translate_worker() | `translate.rs` + `pipeline.rs` | Parallel with ordering |
| `test_deepgram.py` tts_worker() | `tts.rs` TtsEngine | Sequential playback |
| `test_deepgram.py` speak_pocket() | `tts.rs` + `audio/playback.rs` | Generate + play |
| `test_deepgram.py` find_source() | `audio/capture.rs` | Device selection |

## Cost

| Direction | Cost/hour | Components |
|---|---|---|
| Outgoing only | ~$0.52 | Deepgram STT $0.46 + Groq translate ~$0.06 + TTS $0 |
| Bidirectional | ~$1.04 | 2× above |

See docs/cost-analysis.md for detailed breakdown.
