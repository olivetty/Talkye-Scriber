# Talkye Meet — Architecture

AI Meeting Assistant. Capturează audio-ul unui meeting, identifică cine vorbește,
transcrie per speaker, și generează un summary trimis la un endpoint.

Aplicație desktop (Linux + macOS). Totul local, fără bot în meeting.


## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Flutter UI                                                      │
│  Meeting transcript · speaker labels · start/stop · export       │
└──────────────────────┬──────────────────────────────────────────┘
                       │ flutter_rust_bridge (FFI)
┌──────────────────────▼──────────────────────────────────────────┐
│  Rust Core Engine (core/)                                        │
│                                                                  │
│  config.rs ─── Settings (.env + Flutter overrides)               │
│                                                                  │
│  audio/                                                          │
│  ├── capture.rs ──── Mic/system audio via cpal (16kHz mono PCM)  │
│  └── virtual.rs ──── PulseAudio routing (system audio capture)   │
│                                                                  │
│  vad.rs ─────── Silero VAD V5 — speech segment detection         │
│                                                                  │
│  stt/                                                            │
│  ├── mod.rs ──────── SttBackend trait + factory                  │
│  ├── deepgram.rs ─── Deepgram Nova-3 WebSocket (dev/testing)     │
│  └── parakeet.rs ─── Local STT via parakeet-rs (production)      │
│                                                                  │
│  diarize.rs ──── WeSpeaker embeddings + speaker clustering       │
│  session.rs ──── Meeting session store (transcript + speakers)   │
│  summary.rs ──── LLM summary generation (Groq)                  │
│  export.rs ───── POST meeting data to endpoint                   │
│                                                                  │
│  pipeline.rs ── Orchestration: capture → VAD → STT + embed →     │
│                 attribute → store → summary → export              │
│                                                                  │
│  engine.rs ──── Public API for Flutter (start/stop/events)       │
└─────────────────────────────────────────────────────────────────┘
```


## Data Flow — Meeting Assistant

```
Audio Capture (cpal, 16kHz mono)
  │
  ▼
Silero VAD V5 — detectează segmente de speech
  │
  │ Speech Segment (start_ms, end_ms, audio PCM)
  ▼
┌─────────────────────────────────┐
│  Parallel (tokio tasks)         │
│                                 │
│  Parakeet STT ──→ text          │
│  WeSpeaker ──────→ embedding    │
└────────────┬────────────────────┘
             │
             ▼
Speaker Attribution
  │ Cosine similarity vs known speakers
  │ Threshold ~0.65 → same speaker / new speaker
  │
  ▼
Attributed Segment
  { speaker: "Speaker 1", text: "...", start_ms, end_ms }
  │
  ▼
Session Store (in-memory Vec<TranscriptSegment>)
  │
  ├──→ Live UI (Flutter, real-time scroll)
  │
  └──→ End of Meeting
        │
        ▼
  LLM Summary (Groq, llama-3.3-70b)
        │
        ▼
  Export POST (endpoint configurabil)
```

Fiecare săgeată e un `tokio::mpsc` channel. Componentele nu se cunosc între ele —
doar pipeline-ul le conectează.


## Componente

### Audio Capture (existent)
- `cpal` pentru I/O audio cross-platform
- 16kHz mono PCM (16-bit)
- Suportă: mic fizic, system audio (PulseAudio monitor)
- Virtual audio routing pentru capturarea audio-ului din meeting

### VAD — Voice Activity Detection (existent)
- Silero VAD V5 (ONNX, 2.2MB, ~1ms/chunk)
- Detectează segmente de speech vs silence
- Output: speech segments cu timestamps

### STT — Speech-to-Text (existent)
- Dual backend: Parakeet TDT v3 (local, $0) sau Deepgram Nova-3 (cloud, $0.26/hr)
- Switchable via `STT_BACKEND` în .env
- Ambele emit aceleași `SttEvent` types
- Parakeet: 25 limbi europene, 600M params, ONNX
- Deepgram: 36+ limbi, streaming WebSocket

### Diarizare — Speaker Identification (NOU)
- WeSpeaker ResNet34 (ONNX, ~25MB)
- Extrage embedding vector (256 dim) per speech segment
- Cosine similarity pentru clustering
- ~5-10ms per segment pe CPU
- Max ~10 speakeri simultani

### Session Store (NOU)
- In-memory durante meeting
- Persist la final: `~/.talkye/meetings/{id}.json`
- Structuri: MeetingSession, Participant, TranscriptSegment

### LLM Summary (NOU)
- Groq API (llama-3.3-70b-versatile)
- Un singur call la finalul meeting-ului
- Output: topics, decisions, action items, next steps
- Cost: ~$0.001-0.005 per meeting

### Export (NOU)
- POST request cu meeting data (JSON)
- Endpoint + API key configurabile
- Include: summary, action items, full transcript, participants


## Module Responsibilities

| File | Responsabilitate | Status |
|---|---|---|
| `config.rs` | Load .env, validate, expose Config struct | Existent — de extins |
| `audio/capture.rs` | Mic/system audio, stream PCM chunks | Existent |
| `audio/virtual.rs` | PulseAudio routing | Existent |
| `vad.rs` | Silero VAD V5 speech detection | Existent |
| `stt/mod.rs` | SttBackend trait, factory, SttEvent types | Existent |
| `stt/deepgram.rs` | Deepgram WebSocket streaming | Existent |
| `stt/parakeet.rs` | Local STT via parakeet-rs | Existent |
| `diarize.rs` | WeSpeaker embeddings + speaker clustering | NOU |
| `session.rs` | Meeting session store + persistence | NOU |
| `summary.rs` | Groq LLM summary generation | NOU |
| `export.rs` | POST meeting data to endpoint | NOU |
| `pipeline.rs` | Wire everything together | De rescris |
| `engine.rs` | Public API for Flutter | De extins |

### Module depreciate (din faza interpreter)
| File | Era | Acum |
|---|---|---|
| `translate.rs` | Groq LLM translation | De eliminat |
| `tts/` | Pocket TTS + Chatterbox | De eliminat |
| `voice.rs` | Voice cloning | De eliminat |
| `accumulator.rs` | Word batching for translation | De eliminat |
| `audio/playback.rs` | Speaker output for TTS | De eliminat |


## Modele ONNX

| Model | Size | Scop | Status |
|---|---|---|---|
| Parakeet TDT v3 | ~2.4GB | Local STT (25 limbi EU) | Existent |
| Silero VAD V5 | ~2.2MB | Speech detection | Existent |
| WeSpeaker ResNet34 | ~25MB | Speaker embeddings | De adăugat |


## STT Backend Strategy

Două backend-uri, switchable via `STT_BACKEND`:

| Backend | Use case | Cost | Latency | Languages |
|---|---|---|---|---|
| `parakeet` | Production | $0 | ~1-3s | 25 EU |
| `deepgram` | Dev/testing | $0.26/hr | ~0.3-0.5s | 36+ |

Ambele emit aceleași `SttEvent` types → pipeline-ul nu se schimbă.


## Cost Model

| Component | Unde | Cost/meeting (1h) |
|---|---|---|
| STT | Local (Parakeet) | $0 |
| VAD | Local (Silero) | $0 |
| Diarizare | Local (WeSpeaker) | $0 |
| Summary | Cloud (Groq) | ~$0.005 |
| **Total** | | **~$0.005/meeting** |

Cu Deepgram STT: +$0.26/hr.


## Flutter UI — Meeting Assistant

```
┌──────────────────────────────────┐
│  ● Meeting Assistant        LIVE │
│  Weekly Standup                  │
│  3 participants                  │
├──────────────────────────────────┤
│                                  │
│  [Oliver] 00:01                  │
│  Bună ziua, azi discutăm        │
│  despre lansarea produsului      │
│                                  │
│  [Maria] 02:15                   │
│  Eu am terminat design-ul       │
│                                  │
│  [Alex] 03:42                    │
│  Trebuie să vorbim și despre    │
│  buget                           │
│                                  │
│  ● Oliver vorbește...            │
├──────────────────────────────────┤
│  [Stop] [Summary] [Export]       │
└──────────────────────────────────┘
```


## FFI API (Flutter ↔ Rust)

### Funcții păstrate
- `start_engine(config, sink)` — pornește pipeline-ul
- `stop_engine()` — oprește pipeline-ul
- `is_engine_running()` — status
- `list_input_devices()` — enumerate audio devices
- `check_models(...)` — verifică modele pe disk

### Funcții noi (meeting assistant)
- `get_meeting_session(id)` — returnează sesiunea curentă
- `list_speaker_profiles()` — profile de voce cunoscute
- `rename_speaker(session_id, speaker_id, name)` — redenumire speaker
- `generate_summary(session_id)` — generează summary
- `export_meeting(session_id, endpoint, api_key)` — export POST

### Funcții de eliminat (interpreter)
- `list_voices`, `record_voice`, `precompute_voice`, `preview_voice`
- `play_preview`, `delete_voice`, `voices_dir`, `list_builtin_voices`

### Events (Rust → Flutter)

```rust
enum EngineEvent {
    StatusChanged { status: String },
    // NOU: segment atribuit unui speaker
    TranscriptSegment {
        speaker_id: u8,
        speaker_name: String,
        text: String,
        start_ms: u64,
        end_ms: u64,
    },
    // NOU: speaker nou detectat
    SpeakerDetected {
        speaker_id: u8,
        suggested_name: String,
    },
    Error { message: String },
    Log { level: String, message: String },
}
```


## Faze de implementare

### Faza 1: Diarizare de bază
1. Integrăm WeSpeaker ONNX pentru speaker embeddings
2. Speaker clustering cu cosine similarity
3. Pipeline nou: VAD → STT + Embedding → Attributed transcript
4. UI simplă cu transcript per speaker
5. Participant names manual

### Faza 2: Summary + Export
1. LLM summary la finalul meeting-ului (Groq)
2. Export POST la endpoint configurabil
3. Meeting history (lista meeting-uri anterioare)

### Faza 3: Google Integration
1. Sign In with Google în Flutter
2. Google Calendar API — lista meeting-uri + attendees
3. Auto-match speakers cu attendees
4. Voice profile database

### Faza 4: Polish
1. Voice enrollment flow (guided)
2. Meeting templates
3. Keyboard shortcuts (start/stop/mark)
4. Error recovery și performance tuning


## Key Decisions

| Decizie | Alegere | De ce |
|---|---|---|
| Audio I/O | cpal | Cross-platform, no external deps |
| STT (production) | Parakeet TDT v3 | Local, 25 EU langs, $0 |
| STT (dev) | Deepgram Nova-3 | Best streaming quality |
| VAD | Silero V5 | Neural, 2.2MB, ~1ms/chunk |
| Speaker embeddings | WeSpeaker ResNet34 | ONNX, CPU, ~5ms/segment |
| Summary LLM | Groq (Llama 3.3 70B) | ~150ms, $0.005/meeting |
| Config | .env (dotenvy) | Simple, proven |
| Async runtime | Tokio | Channels, tasks, timers |
| FFI bridge | flutter_rust_bridge | Proven, async streaming |
