# Talkye Meet — Architecture

Real-time voice translation for video calls. Speak your language, others hear theirs — in your voice.
Downloadable app for Mac + Linux. $20/month subscription.

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
│  stt/                                                           │
│  ├── mod.rs ──────── SttBackend trait + factory                 │
│  ├── deepgram.rs ─── Deepgram Nova-3 WebSocket (dev/testing)    │
│  └── parakeet.rs ─── Local STT via parakeet-rs (production)     │
│                                                                 │
│  vad.rs ─────── Silero VAD V5 neural voice activity detection   │
│                                                                 │
│  translate.rs ── Groq LLM translation with context window       │
│  tts/         ── Pocket TTS voice synthesis                     │
│    mod.rs ──── TtsBackend trait + factory                       │
│    pocket.rs ─ Pocket TTS (CPU, English, voice clone)           │
│  pipeline.rs ── Orchestration: accumulator + parallel translate  │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow (Phase 1 — CLI)

```
Mic (cpal)
  │ AudioChunk (Vec<u8>, 16-bit PCM, 16kHz mono)
  ▼
STT Backend (configurable: deepgram | parakeet)
  │ SttEvent (Interim | Final { words, speech_final } | UtteranceEnd)
  ▼
Accumulator (in pipeline.rs)
  │ Collects words from Finals
  │ First flush: 4 words (fast response)
  │ Subsequent: 5 words
  │ Timeout flush: 1.5s safety net
  │ Immediate flush on speech_final / utterance_end
  ▼
Parallel Translator (3 concurrent, ordered output)
  │ String (translated text)
  ▼
Pocket TTS (streaming, clause splitting, voice clone)
  │ PCM f32 chunks (streamed per clause)
  ▼
Speaker (cpal, streaming ring buffer)
```

Every arrow is a `tokio::mpsc` channel. Components don't know about each other — only the pipeline connects them.

## Data Flow (Phase 2+3 — Call Integration)

```
OUTGOING (you → them):
  Real Mic → STT → Translate(RO→EN) → TTS(your voice) → Virtual Mic → Meet sends

INCOMING (them → you):
  Meet → Virtual Speaker → STT → Translate(EN→RO) → TTS(default) → Real Speakers
```

Two independent pipeline instances. Zero feedback loop:
- Outgoing TTS → virtual mic only (Meet hears, you don't)
- Incoming TTS → real speakers only (you hear, Meet doesn't)

## Virtual Audio Routing (Google Meet)

Current working setup using PulseAudio/PipeWire modules:

```
TTS (cpal) ──→ talkye_combined (combine-sink)
                  ├──→ Real Speakers (you hear directly)
                  └──→ talkye_out (null-sink)
                          └──→ talkye_out.monitor
                                  └──→ talkye_mic (virtual-source)
                                          └──→ Google Meet microphone
```

Setup commands (ephemeral — lost on reboot):
```bash
# 1. Null sink for Meet to read from
pactl load-module module-null-sink sink_name=talkye_out

# 2. Combined sink: sends to both your speakers AND talkye_out
pactl load-module module-combine-sink sink_name=talkye_combined \
  slaves=<your_speaker_sink>,talkye_out

# 3. Virtual mic source (browsers see this as a microphone)
pactl load-module module-virtual-source source_name=talkye_mic \
  master=talkye_out.monitor source_properties=device.description="Talkye_Mic"

# Find your speaker sink name:
pactl list short sinks
```

In Google Meet: Settings → Audio → Microphone → "Talkye_Mic".

Playback uses pre-buffering (150ms) to prevent underruns between TTS chunks.
Routing done via `pactl move-sink-input` after first cpal stream starts.

## Phase Roadmap

### Phase 1: CLI Pipeline ✅ COMPLETE (Feb 2026)
Replicate `prototype/test_deepgram.py` in Rust.
- `cargo run --release` → speak Romanian → hear English on speakers
- Voice clone with Oliver's voice (pre-computed .safetensors)
- Accumulator: 3w first flush, 5w subsequent, 1.5s timeout
- Parallel translation (3 concurrent, ordered output)
- Dual STT: Parakeet TDT v3 (local, production) + Deepgram (dev)
- Silero VAD V5 for speech detection + smart flush + overlap buffer
- Streaming TTS playback with 150ms pre-buffer
- Virtual audio routing to Google Meet via PulseAudio

Deliverable: working CLI binary. End-to-end latency ~2-3s.
See `docs/phase1-complete.md` for full technical decisions.

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
| Audio I/O | cpal | Cross-platform, compiles into binary, no external deps |
| Virtual devices | libpulse-binding | Programmatic PulseAudio control (Phase 2) |
| Config format | .env (dotenvy) | Simple, proven, user edits one file |
| Translation concurrency | 3 parallel + ordered | Reduces latency when multiple fragments queue up |
| TTS engine | pocket-tts | CPU, English, voice clone, streaming, ~135ms first chunk |
| STT (production) | parakeet-rs (Parakeet TDT v3) | Local, 25 EU langs, 600M params, ONNX, $0 |
| VAD | Silero VAD V5 (ONNX) | Neural speech detection, 2.2MB, ~1ms/chunk |
| STT (dev/testing) | Deepgram Nova-3 | Best streaming quality, good for comparison |
| LLM translation | Groq (Llama 3.3 70B) | ~150ms, cheap ($0.02/hr), good quality |
| Product model | $20/month subscription | 84-97% margin depending on usage |

## STT Backend Strategy

Two backends, switchable via `STT_BACKEND` in `.env`:

| Backend | Use case | Cost | Latency | Languages |
|---|---|---|---|---|
| `parakeet` | Production (app) | $0 | ~1-3s | 25 EU (incl. RO) |
| `deepgram` | Dev/testing | $0.26/hr | ~0.3-0.5s | 36+ |

Both emit the same `SttEvent` types → pipeline doesn't change.
See `docs/local-stt-research.md` for full research.

## Module Responsibilities

| File | Responsibility | Depends on |
|---|---|---|
| `config.rs` | Load .env, validate, expose typed Config struct | nothing |
| `audio/capture.rs` | Open mic, stream PCM chunks via channel | config |
| `audio/playback.rs` | Streaming ring buffer playback on speaker | config |
| `audio/virtual_device.rs` | Create/destroy PulseAudio null-sinks | config (Phase 2) |
| `stt/mod.rs` | SttBackend trait, factory, SttEvent types | config |
| `stt/deepgram.rs` | Deepgram WebSocket: send audio, emit SttEvents | config |
| `stt/parakeet.rs` | Local STT via parakeet-rs + Silero VAD | config, vad |
| `vad.rs` | Silero VAD V5 neural voice activity detection | config |
| `translate.rs` | Groq API: translate text with context window | config |
| `tts/mod.rs` | TTS backend trait + factory | config |
| `tts/pocket.rs` | Pocket TTS: CPU, English, streaming | config |
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

| Component | Where | Cost/hour |
|---|---|---|
| STT | Local (parakeet-rs) | $0 |
| Translation | Cloud (Groq) | ~$0.02 |
| TTS | Local (pocket-tts) | $0 |
| **Total** | | **~$0.02/hour** |

Revenue: $20/user/month. Margin: 84-97%.
See docs/cost-analysis.md for detailed breakdown.
