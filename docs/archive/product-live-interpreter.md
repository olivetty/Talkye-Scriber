# Product: Live Interpreter

Real-time voice translation for video calls. Speak your language, others hear theirs — in your voice.

## What It Does

You join a Zoom/Meet/Teams call. You speak Romanian. The other person hears English — in your voice, in real-time. They speak English, you hear Romanian. No interpreter needed. No one installs anything except you.

## Key Decisions

| Decision | Choice | Why |
|---|---|---|
| Tech stack | Flutter + Rust | Flutter = cross-platform UI. Rust = core engine (audio, TTS, pipeline) |
| TTS engine | `pocket-tts` Rust crate (v0.6.2) | Voice cloning, streaming, CPU-only, MIT license. Eliminates Python entirely |
| Flutter ↔ Rust | `flutter_rust_bridge` | Mature FFI bridge, async support, zero-copy where possible |
| MVP platforms | Linux + macOS | Windows requires signed kernel driver for virtual audio ($400/yr). Deferred. |
| Audio capture | Dual virtual devices (Krisp-style) | Clean stream separation, no feedback loop, works with any call app |
| Virtual audio (Linux) | PulseAudio/PipeWire null-sink | Trivial, app creates/removes automatically, zero user install |
| Virtual audio (macOS) | BlackHole (bundled, MIT) | Open source, user approves system extension once |
| Incoming audio UX | User hears ONLY translation | Simplest for MVP. Pass-through at -20dB as future option |
| MVP languages | RO ↔ EN | Our test case. Expand based on TTS quality per language |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter UI (system tray + settings window)                 │
│  - Language selector, on/off toggle, voice enrollment       │
│  - Status: connected, translating, error                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ flutter_rust_bridge (FFI)
┌──────────────────────▼──────────────────────────────────────┐
│  Rust Core Engine                                           │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Audio I/O   │  │ Pipeline     │  │ Virtual Devices   │  │
│  │ (cpal)      │  │ Manager      │  │ (platform-native) │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Deepgram    │  │ Groq/LLM     │  │ Pocket TTS        │  │
│  │ STT Client  │  │ Translate    │  │ (pocket-tts crate)│  │
│  │ (WebSocket) │  │ (HTTP)       │  │ Voice clone, CPU  │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Audio Routing — Dual Virtual Devices

The app creates two virtual audio devices. The user sets both in their call app (one-time setup).

```
┌──────────┐          ┌─────────────────┐          ┌──────────────────┐
│ Real Mic │ ──PCM──→ │  OUTGOING       │ ──PCM──→ │ Virtual Mic      │ ──→ Zoom sends
│          │          │  STT→Translate  │          │ "Interpreter Mic"│     to others
│          │          │  →TTS (my voice)│          │                  │
└──────────┘          └─────────────────┘          └──────────────────┘

┌──────────────────┐  ┌─────────────────┐          ┌──────────┐
│ Virtual Speaker  │  │  INCOMING       │ ──PCM──→ │ Real     │ ──→ You hear
│ "Interpreter     │──│  STT→Translate  │          │ Speakers │     translation
│  Speaker"        │  │  →TTS           │          │          │
└──────────────────┘  └─────────────────┘          └──────────┘
        ↑
   Zoom outputs here
```

**Why no feedback loop:**
- Outgoing TTS → Virtual Mic only (Zoom hears it, you don't)
- Incoming TTS → Real speakers only (you hear it, Zoom doesn't)
- Zoom's output goes to Virtual Speaker, not real speakers
- Real mic captures your voice, not the incoming TTS (speakers ≠ mic)

### Linux Implementation (PulseAudio/PipeWire)

```bash
# App creates these on startup, removes on exit

# Virtual speaker — call app outputs here
pactl load-module module-null-sink sink_name=live_interp_out \
  sink_properties=device.description="Interpreter-Speaker"

# Virtual mic sink — TTS writes here
pactl load-module module-null-sink sink_name=live_interp_in \
  sink_properties=device.description="Interpreter-Mic-Sink"

# Virtual mic source — call app reads from here
pactl load-module module-remap-source \
  master=live_interp_in.monitor \
  source_name=live_interp_mic \
  source_properties=device.description="Interpreter-Mic"
```

Reading incoming: `parec --device=live_interp_out.monitor`
Writing outgoing TTS: `paplay --device=live_interp_in`

In Rust: `libpulse-binding` crate for programmatic control.

### macOS Implementation

Bundle BlackHole (MIT license, open source) compiled as two virtual devices:
- "Interpreter Mic" (2ch)
- "Interpreter Speaker" (2ch)

User approves system extension once in System Preferences → Privacy & Security.

In Rust: `coreaudio-rs` crate or `cpal` for cross-platform audio I/O.

## Bidirectional Pipeline

Two independent pipelines running in parallel, each with its own STT connection, translate queue, and TTS output:

```
OUTGOING (you → them):
  Real Mic → Deepgram STT (your language)
    → LLM translate (your lang → their lang)
    → Pocket TTS (your cloned voice)
    → Virtual Mic → Call app sends

INCOMING (them → you):
  Call app → Virtual Speaker → Deepgram STT (their language)
    → LLM translate (their lang → your lang)
    → Pocket TTS (built-in voice)
    → Real Speakers/Headphones
```

## What We Already Have (from test_deepgram.py prototype)

- Deepgram streaming STT with endpointing ✓
- Groq LLM translation with context window ✓
- Pocket TTS with voice cloning + streaming ✓
- Accumulator-based flushing (first flush 4w, then 8w) ✓
- Parallel translation with sequence-ordered output ✓
- Latency: ~3-4s sound-to-sound ✓
- Virtual mic on Linux (PulseAudio null-sink) ✓

## Latency

Current prototype: ~3-4s sound-to-sound.
Target: ~2-2.5s (competitive with human interpreters at ~2-3s).

| Stage | Current | Optimized |
|---|---|---|
| Deepgram STT (endpointing + processing) | ~500-1000ms | ~300-700ms (endpointing 300ms) |
| Accumulator wait | ~500-1500ms | ~300-1000ms (first flush 3 words) |
| Groq translation | ~150-300ms | ~150-300ms (already fast) |
| Pocket TTS first chunk | ~140-180ms | ~100-140ms (Rust native, no GIL) |
| **Total to first sound** | **~1.3-3s** | **~0.9-2.1s** |

Future: speculative translation on interim results (start translating before is_final, discard if changed).

## Multi-Language Support

| Component | Language coverage |
|---|---|
| Deepgram STT | 36+ languages |
| LLM Translation | Any pair (Groq Llama 3.3 70B) |
| Pocket TTS | English (excellent), other languages (varies) |

MVP: RO ↔ EN. Voice cloning works across languages (clone your voice, it speaks the target language). Expand language pairs based on TTS output quality testing.

## Competition

| Product | Approach | Pricing | Weakness |
|---|---|---|---|
| **Pinch** | Own video platform | $49-149/mo | Forces you off Zoom/Meet |
| **Toby** | Desktop app, virtual mic | Early stage | 15 languages, no voice cloning — robotic |
| **Krisp** | SDK for CX platforms (B2B) | Enterprise | Not consumer, SDK only |
| **Google Meet** | Built-in translated captions | Free w/ Workspace | Text only, no voice |
| **Zoom** | AI Companion captions | Included in paid | Text only, no voice |

## Our Advantage

1. **Voice cloning** — you sound like yourself. Pocket TTS is free, local, natural.
2. **Works with any call app** — virtual mic/speaker, no platform lock-in
3. **Low cost** — ~$0.52/hour outgoing, TTS is free (local CPU)
4. **No Python, no cloud TTS** — Rust binary, fast, no dependencies for end user
5. **Only the speaker needs the app** — zero friction for the other party

## Cost Per User

| Direction | Cost/hour | Cost/month (4h/day) |
|---|---|---|
| Outgoing only | $0.52 | $62 |
| Bidirectional | $1.04 | $125 |

See [cost-analysis.md](cost-analysis.md) for detailed breakdown.

## Pricing Model

| Plan | Price | Includes |
|---|---|---|
| Free | $0 | 60 min/month |
| Personal | $14/month | 30 hours, 1 language pair |
| Pro | $29/month | Unlimited, all languages, voice cloning |
| Team | $19/seat/month | Pro + admin dashboard |

## Target Users

1. **Remote workers in Eastern Europe** — devs, designers working with US/EU clients
2. **Sales teams** — selling internationally, need to sound natural
3. **Freelancers** — compete globally on Upwork/Fiverr without language barrier
4. **Customer support** — multilingual without hiring native speakers
5. **Immigrants** — doctor appointments, government calls, school meetings

## MVP Scope

### Phase 1 — Core (Linux)
- [ ] Rust core: audio capture, Deepgram STT client, Groq translate, Pocket TTS
- [ ] Virtual mic + virtual speaker (PulseAudio, automatic)
- [ ] Outgoing translation pipeline
- [ ] Voice enrollment (record 30s on first run)
- [ ] Flutter UI: tray icon, on/off, language selector, status
- [ ] CLI mode (headless, for testing)

### Phase 2 — Full Product
- [ ] Incoming translation pipeline (bidirectional)
- [ ] macOS support (BlackHole bundled)
- [ ] 10+ language pairs
- [ ] Settings persistence, auto-start
- [ ] Stripe billing, usage tracking

### Phase 3 — Scale
- [ ] Windows support (if virtual audio driver solved)
- [ ] Browser extension (Chrome, for web-based calls)
- [ ] SDK/API for integrations
- [ ] Team management + analytics
- [ ] Mobile companion app

## Name Ideas

- **Mira** (from our wake word, means "look/wonder" in Romanian)
- Vox (voice)
- Ponte (bridge, Italian/Portuguese)
- Ecou (echo, Romanian)
- Lingua
