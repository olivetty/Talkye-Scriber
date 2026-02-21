# Live Interpreter — Status & Roadmap

Mode 1 al Talkye Meet: vorbesti intr-o limba, ceilalti aud in alta — cu vocea ta.
Interpretare live in timp real, ca un translator uman la conferinta.


## Ce avem acum (v0.2.1)

### Core Engine (Rust) — FUNCTIONAL
- Parakeet TDT v3 STT local (25 limbi, ONNX, ~2.4GB model)
- Deepgram STT cloud (backup, configurabil din .env)
- Silero VAD V5 (neural voice activity detection)
- Smart flush cu fast first flush (prima transcriere ~2s mai rapida)
- Accumulator dual threshold (3w first, 5w subsequent, 1.5s timeout)
- Traducere LLM via Groq API (llama-3.3-70b-versatile)
- Length guard anti-hallucinare (reject >3x word count)
- Traducere paralela (3 concurrent, ordered output via BTreeMap)
- pocket-tts v0.6 (voice cloning, streaming, CPU-only, English model)
- Pre-computed voice states (.wav → .safetensors, load 720ms vs 15s)
- Session-reuse playback (un cpal stream per utterance, gapless)
- Dynamic drain timeout (bazat pe buffer size real)
- Clause splitting la delimitatori naturali (min 3 cuvinte)
- Virtual audio auto-setup (null-sink + combine-sink + virtual-source)
- Watchdog audio (detecteaza Bluetooth reconnect, recreaza combine-sink)
- Audio capture 16kHz mono via cpal

### Flutter Desktop App — FUNCTIONAL (basic)
- FFI bridge via flutter_rust_bridge v2.11.1
- Start/stop engine din UI
- System tray (dark/light/live icons)
- Close = hide to tray
- Dark/light theme toggle
- Logo + branding
- Fereastra fixa 400x700, top-right positioning

### CLI Mode — FUNCTIONAL
- `talkye-cli` alias (build + run --release)
- Full logging cu tracing
- Identic cu app-ul ca functionalitate

### Configurare (.env)
- Toate setarile centralizate in .env cu comentarii
- STT_BACKEND=parakeet|deepgram
- Limbi, viteza TTS, voice path, audio routing
- Accumulator tuning (ACCUM_FIRST_WORDS, ACCUM_MIN_WORDS)

### Documentatie
- docs/architecture.md
- docs/test-script.md (text etalon + criterii de verificare)
- docs/cost-analysis.md
- docs/local-stt-research.md
- docs/pocket-tts-analysis.md
- .kiro/steering/ (coding standards, architecture)


## Ce lipseste

### P0 — Blocante pentru produs

**Voice Cloning din App**
- Acum: vocea se face manual (record .wav, ruleaza precompute_voice binary)
- Trebuie: buton "Record Voice" in app → 10s recording → precompute → gata
- Flow: record via cpal (FFI) → save .wav → precompute .safetensors → set as active
- Voice management: lista voci, preview, delete, select
- Default voice: "alba" (built-in pocket-tts) pentru cine nu vrea sa cloneze
- Stocare: ~/.talkye/voices/

**Onboarding (First Run Wizard)**
- Step 1: Welcome
- Step 2: Language selection (speak/hear)
- Step 3: Audio check (mic level meter, speaker test, virtual audio setup)
- Step 4: Voice clone (record 10s sau skip)
- Step 5: Test drive — vorbesti, auzi traducerea cu vocea ta (momentul WOW)
- Model download integrat (Parakeet TDT ~2.4GB cu progress bar)
- First-run detection (flag in local storage)

**Settings Screen**
- Languages: FROM/TO dropdowns cu swap
- Voice: lista voci, preview, record new
- Audio: input/output device dropdowns, test buttons, virtual audio status
- Speed: TTS speed control
- Advanced: STT backend, API keys

**Transcript Live in UI**
- Scroll area cu perechi original/tradus
- Timestamp per entry
- Status indicator (Listening/Translating/Speaking)
- Auto-scroll

**Error Recovery**
- Groq API timeout → retry cu backoff
- STT stall → restart STT task
- Audio device lost → detectie + notificare
- Model missing → redirect la download

### P1 — Importante dar nu blocante

**Device Selection din UI**
- Input/output device dropdowns (list_input_devices/list_output_devices exista deja in FFI)
- Test buttons (play beep, show level meter)
- Salvare in settings

**Model Auto-Download**
- Check la startup daca modelele exista
- Download cu progress bar (Parakeet TDT, Silero VAD)
- Resume pe failure (HTTP Range headers)
- Stocare: ~/.talkye/models/ (sau models/ relativ)

**macOS Support**
- Build + test pe macOS
- BlackHole integration pentru virtual audio
- Code signing
- .dmg packaging

**Packaging**
- Linux: AppImage (un fisier, dublu-click)
- macOS: .dmg
- Installer mic (~80MB), modele descarcate la prima rulare

### P2 — Nice to have

- Keyboard shortcuts (Ctrl+Shift+T toggle global)
- Session statistics (durata, numar traduceri)
- Transcript export (copy all, save as text)
- Auto-detect limba vorbita (Parakeet face auto-detect, UI nu expune)
- Always-on-top toggle
- Notificari desktop (start/stop/error)
- Telemetry opt-in


## Voice Cloning — Design detaliat

Asta e urmatorul pas. Iata cum functioneaza:

### Ce avem deja in Rust
- `pocket_tts::TTSModel::load("b6369a24")` — incarca modelul TTS
- `model.get_voice_state(path)` — incarca voce din .wav (LENT: ~15s, trece prin Mimi encoder)
- `model.get_voice_state_from_prompt_file(path)` — incarca voce din .safetensors (RAPID: ~720ms)
- `precompute_voice.rs` binary — face .wav → .safetensors offline
- `voices/oliver.safetensors` — vocea pre-computata existenta (1.4KB)

### Ce trebuie construit

**1. Recording API (Rust FFI)**
```rust
// Inregistreaza N secunde de la mic, salveaza ca .wav
fn record_voice(output_path: String, duration_secs: u32, sink: StreamSink<RecordingEvent>)

enum RecordingEvent {
    Progress { elapsed_secs: f32, level: f32 },  // level meter
    Done { path: String },
    Error { message: String },
}
```
- Foloseste cpal (deja il avem) pentru capture
- Salveaza 16-bit PCM mono .wav
- Stream de events pentru progress + level meter in UI

**2. Precompute API (Rust FFI)**
```rust
// Converteste .wav → .safetensors (voice state pre-computat)
fn precompute_voice(wav_path: String, output_path: String, sink: StreamSink<PrecomputeEvent>)

enum PrecomputeEvent {
    Progress { stage: String, percent: f32 },  // "Loading model", "Encoding voice"
    Done { safetensors_path: String, size_bytes: u64 },
    Error { message: String },
}
```
- Reutilizeaza logica din precompute_voice.rs
- Dureaza 5-15s (Mimi encoder)
- Progress events pentru UI

**3. Voice Preview API (Rust FFI)**
```rust
// Genereaza si reda un text scurt cu vocea selectata
fn preview_voice(voice_path: String, text: String)
```
- Text default: "Hello, this is how I sound in English"
- Reda direct pe default speaker

**4. Voice Management (Dart/Flutter)**
- Lista voci din ~/.talkye/voices/*.safetensors
- Metadata: nume, data creare, size
- CRUD: create (record + precompute), delete, rename, set active
- Vocea activa salvata in settings
- Default fallback: "alba" (built-in pocket-tts)

### Flow complet in UI

```
Settings → Voice tab
┌──────────────────────────────────────────┐
│  Your Voices                             │
│                                          │
│  ● Oliver (active)     [Preview] [Delete]│
│    Created Feb 21, 2026                  │
│                                          │
│  ○ Default (Alba)      [Preview]         │
│    Built-in voice                        │
│                                          │
│  ──────────────────────────────────       │
│                                          │
│  [ + Record New Voice ]                  │
│                                          │
└──────────────────────────────────────────┘

Click "Record New Voice":
┌──────────────────────────────────────────┐
│  Record Your Voice                       │
│                                          │
│  Read this text naturally:               │
│  "The quick brown fox jumps over the     │
│   lazy dog. I enjoy working with my      │
│   team on interesting projects."         │
│                                          │
│  ████████████░░░░░░  7s / 10s           │
│  ▓▓▓▓▓▓▓▓░░░░ (level meter)            │
│                                          │
│  [ Cancel ]              [ ■ Stop ]      │
└──────────────────────────────────────────┘

Dupa recording:
┌──────────────────────────────────────────┐
│  Processing Your Voice...                │
│                                          │
│  ████████████████░░░░  80%              │
│  Encoding voice profile...               │
│                                          │
│  This takes about 10 seconds.            │
└──────────────────────────────────────────┘

Done:
┌──────────────────────────────────────────┐
│  Voice Created!                          │
│                                          │
│  Name: [ My Voice           ]            │
│                                          │
│  [ Preview ]    [ Use This Voice ]       │
└──────────────────────────────────────────┘
```

### Sfaturi pentru recording quality
- Afisam in UI: "Use a quiet room, speak naturally, avoid whispering"
- Minimum 5s, recomandat 10s, maximum 30s
- Level meter live — userul vede daca mic-ul prinde
- Daca level e prea mic: warning "Speak louder or move closer to mic"

### Stocare

```
~/.talkye/
  voices/
    oliver.safetensors      # vocea pre-computata
    oliver.wav              # sursa originala (optional, pentru re-encode)
    maria.safetensors
    maria.wav
  voice_profiles.json       # metadata
```

voice_profiles.json:
```json
{
  "active": "oliver",
  "voices": [
    {
      "id": "oliver",
      "name": "Oliver",
      "created_at": "2026-02-21T10:00:00Z",
      "safetensors": "voices/oliver.safetensors",
      "source_wav": "voices/oliver.wav"
    }
  ]
}
```


## Limitari cunoscute

| Limitare | Impact | Solutie posibila |
|---|---|---|
| pocket-tts e English-only | Nu poti genera TTS in franceza/germana | Asteptam model multilingv sau alt TTS engine |
| Voice clone suna ~80% ca tine | Expectatii | Documentam clar: "sounds similar, not identical" |
| Parakeet TDT model e 2.4GB | Download lung la prima rulare | Progress bar, resume, download in background |
| Latenta totala ~3-5s | Perceptibila | Fast first flush ajuta, dar e limita fizica |
| CPU-only TTS | Lent pe masini slabe | pocket-tts e optimizat, dar nu GPU-accelerated |


## Faze de implementare

### Faza 1: Voice Cloning (urmatorul pas)
1. Recording API in Rust (cpal capture → .wav)
2. Precompute API in Rust (reutilizam precompute_voice.rs)
3. Preview API in Rust
4. Voice management UI in Flutter
5. Integrare in pipeline (voice selectata din settings)

### Faza 2: Settings + Transcript UI
1. Settings screen complet (languages, voice, audio, advanced)
2. Transcript live in UI (scroll area cu perechi)
3. Device selection din UI
4. Status indicators

### Faza 3: Onboarding
1. First-run wizard (5 steps)
2. Model download cu progress
3. Voice clone integrat in onboarding
4. Test drive (momentul WOW)

### Faza 4: Error Recovery + Polish
1. Retry logic pentru Groq API
2. STT restart pe stall
3. Audio device lost detection
4. Notificari desktop

### Faza 5: Packaging + macOS
1. AppImage Linux
2. .dmg macOS
3. BlackHole integration
4. Auto-update mechanism


## Relatie cu Mode 2 (Meeting Assistant)

Mode 1 si Mode 2 partajeaza:
- Audio capture (cpal)
- Silero VAD
- Parakeet STT
- Config system
- Flutter app shell + system tray
- Google OAuth (cand va fi implementat)

Diferenta e ce se intampla DUPA STT:
- Mode 1: Accumulator → Translate → TTS → Playback
- Mode 2: Speaker Embedding → Clustering → Attributed Transcript → Summary

Voice cloning (Faza 1 de mai sus) e relevant DOAR pentru Mode 1.
Meeting Assistant nu are nevoie de TTS — doar transcrie si sumarizeaza.
