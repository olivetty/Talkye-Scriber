# Phase 2 — Flutter Desktop App

Plan complet: de la CLI la aplicație instalabilă cu UI.

## Obiectiv

Un user descarcă Talkye Meet, face setup în 5 minute (inclusiv download modele),
și poate traduce în timp real într-un video call. Linux și macOS.

## Stages

```
Stage 1: FFI Bridge          ← fundația, totul depinde de asta
Stage 2: Engine API          ← Rust API pentru Flutter
Stage 3: UI Screens          ← interfața propriu-zisă
Stage 4: Onboarding          ← first-run wizard + model download
Stage 5: Voice Clone         ← record + precompute din app
Stage 6: Virtual Audio       ← setup automat per OS
Stage 7: Packaging           ← AppImage + .dmg
Stage 8: Testing & Audit     ← integrare, UI, performance
Stage 9: Documentație & Push ← final
```

---

## Stage 1: FFI Bridge (fundația)

Conectarea Flutter ↔ Rust prin flutter_rust_bridge.
Cel mai riscant stage — dacă FRB nu merge bine, totul e blocat.

### Tasks

1.1. **Research flutter_rust_bridge v2** — verifică compatibilitate cu Rust 1.93, Flutter 3.41, ort crate
- Citește docs FRB v2, exemple desktop
- Verifică dacă async streaming (Rust → Flutter) funcționează pe Linux desktop
- Identifică limitări cunoscute

1.2. **Definește Rust API surface** — contractul între Flutter și Rust
```rust
// core/src/api.rs — public API for Flutter

// Control
fn start_pipeline(config: PipelineConfig) -> Result<()>
fn stop_pipeline() -> Result<()>
fn is_running() -> bool

// Audio
fn list_input_devices() -> Vec<AudioDevice>
fn list_output_devices() -> Vec<AudioDevice>
fn test_audio_input(device: String) -> Stream<f32>  // live level meter
fn test_audio_output(device: String) -> Result<()>   // play test sound

// Voice
fn list_voices(voices_dir: String) -> Vec<VoiceInfo>
fn precompute_voice(wav_path: String, output_path: String) -> Result<()>
fn preview_voice(voice_path: String, text: String) -> Result<()>

// Models
fn check_models(models_dir: String) -> ModelStatus
fn download_model(url: String, dest: String) -> Stream<DownloadProgress>

// Events (Rust → Flutter stream)
fn engine_events() -> Stream<EngineEvent>

enum EngineEvent {
    StatusChanged { status: String },          // "listening", "translating", "speaking", "idle"
    Transcript { original: String, translated: String, timestamp_ms: u64 },
    Error { message: String },
    ModelLoadProgress { percent: f32, label: String },
}
```

1.3. **Setup FRB în proiect** — configurare Cargo.toml, pubspec.yaml, code generation
- Adaugă `flutter_rust_bridge` în ambele
- Configurează build.rs sau FRB codegen
- Primul test: Flutter apelează o funcție Rust simplă (ping/pong)

1.4. **Test: streaming events** — verifică că Rust poate trimite un stream de events către Flutter
- Rust emite events la fiecare secundă
- Flutter le afișează într-o listă
- Confirmă că async streaming funcționează pe Linux desktop

### Done criteria
- [x] Flutter app pornește pe Linux
- [x] Apel Rust → Flutter funcționează (ping/pong)
- [x] Stream Rust → Flutter funcționează (events)
- [ ] Zero crash-uri la start/stop repetat

---

## Stage 2: Engine API (integrare core)

Expune pipeline-ul real prin API-ul definit în Stage 1.

### Tasks

2.1. **Creează `core/src/api.rs`** — implementează funcțiile din contractul API
- Wrap `Pipeline::run()` într-un task controlabil (start/stop)
- Emite `EngineEvent` prin channel la fiecare STT result, traducere, status change
- Handle errors graceful (nu panic, returnează Result)

2.2. **Audio device enumeration** — listează dispozitive prin cpal
- `list_input_devices()` — returnează nume + id
- `list_output_devices()` — returnează nume + id
- `test_audio_input()` — stream de RMS levels (pentru level meter în UI)
- `test_audio_output()` — play un beep scurt

2.3. **Model management** — verificare și download
- `check_models()` — verifică dacă Parakeet TDT, Silero VAD, TTS model există
- `download_model()` — HTTP download cu progress stream (reqwest + tokio)
- Resume pe failure (HTTP Range headers)

2.4. **Config bridge** — Flutter trimite config, Rust o folosește
- Înlocuiește .env cu config primit de la Flutter
- Flutter salvează settings în local storage, le trimite la start_pipeline()
- .env rămâne ca fallback pentru development

### Done criteria
- [ ] Start/stop pipeline din Flutter funcționează
- [ ] Live transcript apare în Flutter (STT → translate → event)
- [ ] Audio devices listate corect
- [ ] Model download cu progress funcționează
- [ ] Config din Flutter overrides .env

---

## Stage 3: UI Screens

Interfața propriu-zisă, conform `docs/ux-vision.md`.

### Tasks

3.1. **App shell + routing** — MaterialApp, dark theme, navigation
- `lib/main.dart` — entry point, FRB init
- `lib/app.dart` — MaterialApp, theme, routes
- `lib/theme/` — dark mode default, culori (verde/gri/roșu)

3.2. **Home screen** — fereastra principală cu transcript live
- Header: logo + settings icon
- Language bar: `RO → EN` cu timer de sesiune
- Transcript area: scroll automat, perechi 🎤/🔊, fade pe vechi
- Status bar: ● Listening / Translating / Speaking
- Action button: Start/Stop (mare, centrat)
- Responsive: funcționează la 400x500 și la fullscreen

3.3. **Settings screen** — configurare
- Tab Languages: FROM/TO dropdowns cu swap ⇅
- Tab Voice: lista voci, preview, record new
- Tab Audio: input/output device dropdowns, test buttons, virtual audio status
- Tab Advanced: STT backend, API key, reset defaults
- Salvare în local storage (shared_preferences sau similar)

3.4. **System tray** — integrare cu desktop
- Package: `system_tray` sau `tray_manager`
- Icon states: gri (idle), verde (activ), roșu (eroare)
- Left click: toggle window
- Right click: Start/Stop, Open, Settings, Quit
- Close window = minimize to tray (nu quit)

3.5. **Widgets reutilizabile**
- `TranscriptEntry` — o pereche original/tradus cu timestamp
- `StatusIndicator` — dot animat cu label
- `AudioLevelMeter` — bară de nivel pentru mic test
- `DownloadProgress` — progress bar cu procent și ETA

### Done criteria
- [ ] Home screen afișează transcript live din engine
- [ ] Start/Stop funcționează din UI
- [ ] Settings se salvează și se aplică
- [ ] System tray funcționează (icon, menu, toggle)
- [ ] Dark mode arată bine
- [ ] Window resize funcționează (min 350x450)

---

## Stage 4: Onboarding

First-run wizard — de la install la "WOW" în 5 minute.

### Tasks

4.1. **Onboarding flow** — 5 screens conform UX vision
- Step 1: Welcome
- Step 2: Language selection (FROM/TO)
- Step 3: Audio check (mic level meter, speaker test, virtual audio setup)
- Step 4: Voice clone (record 10s, precompute, sau skip)
- Step 5: Test drive (vorbește → auzi traducerea = momentul WOW)

4.2. **Model download în onboarding** — integrat în Step 3
- Verifică ce modele lipsesc
- Download Parakeet TDT (~2.4GB) cu progress bar
- Download în background, user poate citi instrucțiunile audio între timp
- Retry pe failure, resume din unde a rămas

4.3. **Virtual audio setup automat**
- Linux: `pactl load-module` (deja implementat în Rust)
- macOS: detectează BlackHole, dacă lipsește → descarcă + lansează installer
- Verificare: confirmă că virtual devices există după setup

4.4. **First-run detection** — știe dacă e prima deschidere
- Flag în local storage: `onboarding_complete: bool`
- Dacă false → onboarding wizard
- Dacă true → direct home screen

### Done criteria
- [ ] Prima deschidere → onboarding wizard automat
- [ ] Model download funcționează cu progress și retry
- [ ] Virtual audio se creează automat pe Linux
- [ ] Voice clone din onboarding funcționează
- [ ] Test drive (Step 5) produce traducere reală cu vocea userului
- [ ] A doua deschidere → direct home screen

---

## Stage 5: Voice Clone

Record + precompute din app.

### Tasks

5.1. **Audio recording** — capturează 10s de la mic
- Folosește Rust (cpal) prin FFI, nu Flutter audio plugins
- Salvează ca `.wav` (16-bit, mono, sample rate nativ)
- Live level meter în UI în timpul înregistrării
- Countdown vizual: "Recording... 7s / 10s"

5.2. **Precompute voice** — `.wav` → `.safetensors`
- Apelează `precompute_voice()` prin FFI
- Progress indicator (poate dura 5-15s)
- Salvează în `~/.local/share/talkye-meet/voices/` (Linux) sau echivalent macOS

5.3. **Voice management UI**
- Lista vocilor: nume, dată, preview button
- Delete voice
- Set as active
- Record new voice (deschide recording flow)

### Done criteria
- [ ] Record 10s funcționează cu level meter
- [ ] Precompute generează .safetensors valid
- [ ] Voice preview funcționează (TTS cu vocea selectată)
- [ ] Multiple voci pot fi salvate și selectate
- [ ] Vocea selectată e folosită de pipeline

---

## Stage 6: Virtual Audio (programatic)

Setup automat, nu manual cu comenzi pactl.

### Tasks

6.1. **Linux: PulseAudio module management din Rust**
- Creează null-sink, combine-sink, virtual-source la start
- Cleanup la stop (opțional, configurabil)
- Detectează sink-ul real al userului automat
- Handle cazul când modulele există deja (nu duplica)

6.2. **macOS: BlackHole integration**
- Detectează dacă BlackHole e instalat (`/Library/Audio/Plug-Ins/HAL/`)
- Dacă nu: descarcă installer, lansează cu `open` (trigger admin prompt)
- După instalare: configurează aggregate device programatic (CoreAudio API)
- Sau: ghidează userul să selecteze BlackHole în System Preferences

6.3. **Audio routing verification**
- După setup, verifică că virtual mic funcționează
- Test: play audio → verifică că apare pe virtual source
- Afișează status în Settings → Audio: "✅ Virtual audio configured"

### Done criteria
- [ ] Linux: virtual audio se creează automat la start pipeline
- [ ] Linux: cleanup la stop (dacă configurat)
- [ ] macOS: BlackHole detection funcționează
- [ ] macOS: installer flow funcționează
- [ ] Verificare routing funcționează pe ambele platforme

---

## Stage 7: Packaging

De la cod sursă la installer descărcabil.

### Tasks

7.1. **Linux: AppImage**
- Script de build: `flutter build linux` → AppImage
- Include: Flutter app, libtalkye_core.so, ONNX Runtime libs
- Include modele mici: silero_vad.onnx (~2.2MB), TTS base model (~50MB)
- NU include Parakeet TDT (~2.4GB) — download la prima rulare
- Test: AppImage pornește pe Ubuntu 22.04+ fără deps extra
- Desktop entry + icon

7.2. **macOS: .dmg**
- Script de build: `flutter build macos` → .app → .dmg
- Include: Flutter app, libtalkye_core.dylib, ONNX Runtime framework
- Include modele mici (ca Linux)
- Code signing (self-signed pentru development, Apple cert pentru release)
- Test: .dmg funcționează pe macOS 13+

7.3. **CI/CD setup** (opțional, dar recomandat)
- GitHub Actions: build pe push to main
- Artifacts: AppImage + .dmg
- Sau: script local de build pentru ambele platforme

### Done criteria
- [ ] AppImage funcționează pe Ubuntu 22.04+ fresh install
- [ ] .dmg funcționează pe macOS 13+
- [ ] Installer size < 100MB (fără modele mari)
- [ ] Prima rulare descarcă modele și funcționează end-to-end

---

## Stage 8: Testing & Audit

### Tasks

8.1. **Integration tests (Flutter ↔ Rust)**
- Start/stop pipeline: 10 cicluri fără crash
- Event streaming: verifică că toate event types ajung în Flutter
- Config bridge: settings din Flutter se aplică corect în Rust
- Model download: interrupt + resume funcționează
- Voice clone: record → precompute → use in pipeline

8.2. **UI tests**
- Home screen: transcript scroll, start/stop, status changes
- Settings: save/load, language swap, device selection
- Onboarding: parcurge toți 5 pașii
- System tray: icon states, menu actions
- Window resize: min/max, always-on-top toggle

8.3. **Performance audit**
- Memorie: < 2GB RAM în timpul traducerii (modele + Flutter)
- CPU: < 30% idle (când ascultă dar nu vorbește nimeni)
- Latență: end-to-end < 3s (speech → audio tradus)
- Startup: < 10s de la click la "Ready" (fără model download)
- TTS first chunk: < 150ms

8.4. **Code audit**
- Max 300 linii per fișier (Rust și Dart)
- Fiecare modul are o singură responsabilitate
- Error handling: nu panic, nu unwrap pe Result-uri din user input
- Logging: tracing pe Rust, structured logs
- No hardcoded paths — totul configurabil

8.5. **Cross-platform testing**
- Linux: Ubuntu 22.04, 24.04 (PulseAudio + PipeWire)
- macOS: Ventura (13), Sonoma (14), Sequoia (15)
- Audio: built-in mic, USB mic, Bluetooth headset
- Video calls: Google Meet, Zoom (verifică că virtual mic funcționează)

### Done criteria
- [ ] Zero crash-uri în 30 minute de utilizare continuă
- [ ] Toate testele trec pe Linux
- [ ] Toate testele trec pe macOS
- [ ] Performance targets met
- [ ] Code audit passed

---

## Stage 9: Documentație & Push

### Tasks

9.1. **Update docs/**
- `architecture.md` — actualizat cu Flutter layer, FFI, packaging
- `phase2-complete.md` — decizii finale, numere măsurate
- `ux-vision.md` — marcat ce s-a implementat vs ce rămâne

9.2. **README.md** — instrucțiuni de instalare
- Download links (AppImage, .dmg)
- First-run guide cu screenshots
- Troubleshooting (audio issues, model download fails)
- Build from source instructions

9.3. **Screenshots**
- Home screen (idle + active)
- Onboarding wizard (fiecare step)
- Settings
- System tray

9.4. **Git cleanup & push**
- Squash commits dacă e nevoie
- Tag: `v0.2.0-beta`
- Push to main

### Done criteria
- [ ] README are instrucțiuni complete de instalare
- [ ] Screenshots în docs/
- [ ] architecture.md actualizat
- [ ] Tag v0.2.0-beta pe main

---

## Riscuri

| Risc | Impact | Mitigare |
|---|---|---|
| FRB incompatibil cu ort/parakeet-rs | Blocker | Research în Stage 1 înainte de orice altceva |
| System tray inconsistent pe Linux DEs | Medium | Fallback: window-only mode, fără tray |
| BlackHole install eșuează pe macOS | Medium | Ghid manual ca fallback |
| ONNX Runtime .so/.dylib bundling | Medium | Test packaging devreme (Stage 7 în paralel cu Stage 5-6) |
| Model download lent/eșuat | Low | Resume support, retry, progress feedback |
| Memorie > 2GB cu Flutter + modele | Medium | Lazy loading modele, unload când nu e activ |

## Ordine de execuție

```
Stage 1 (FFI Bridge)
  ↓
Stage 2 (Engine API)
  ↓
Stage 3 (UI Screens) ←──── Stage 5 (Voice Clone) poate începe în paralel
  ↓
Stage 4 (Onboarding) ←──── Stage 6 (Virtual Audio) poate începe în paralel
  ↓
Stage 7 (Packaging)
  ↓
Stage 8 (Testing & Audit)
  ↓
Stage 9 (Docs & Push)
```

Stage 1 e critic — dacă FRB nu merge, trebuie alternativă (dart:ffi manual, sau alt bridge).
