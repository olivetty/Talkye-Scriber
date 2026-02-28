# Scriber Cleanup Plan

Branch: `scriber`
Scop: Eliminarea completă a interpreter-ului, voice clone, TTS, Rust engine.
Rămâne: Scriber (dictation) + Chat + Settings + Python sidecar.

## Fișiere de ȘTERS

### Flutter screens
- `app/lib/screens/interpreter_screen.dart` — Live Interpreter UI
- `app/lib/screens/voice_screen.dart` — Voice Clone UI

### Flutter helpers
- `app/lib/voice_names.dart` — display names pentru builtin voices

### Rust core engine (tot)
- `core/` — tot folderul (audio, VAD, STT, translate, TTS, pipeline, voice, accumulator)

### Rust FFI bridge
- `app/rust/` — tot folderul (flutter_rust_bridge, FFI API)
- `app/lib/src/rust/` — generated Dart bindings

### Models ONNX
- `models/` — Parakeet TDT, Silero VAD, etc. (Scriber nu le folosește)

### Config
- `.env` / `.env.example` — config pentru Rust engine

### Docs obsolete
- `docs/architecture.md` — rescris pentru Scriber
- `docs/meeting-assistant-design.md` — nu aparține Scriber-ului
- `docs/archive/` — tot (referințe interpreter)
- `docs/models/` — tot (modele ONNX pentru engine)

## Fișiere de CURĂȚAT

### `app/lib/sidebar.dart`
- Scoatem din NavSection: `interpreter`, `assistant`, `calendar`, `voice`
- Rămân: `dictate`, `chat`, `settings`
- Titlu: "Talkye Meet" → "Talkye Scriber"

### `app/lib/main.dart`
- Scoatem importuri: interpreter_screen, voice_screen, engine.dart, frb_generated
- Scoatem din AppSettings: `sttBackend`, `activeVoicePath`, `sourceLang`, `targetLang`
- Scoatem: `_interpreterKey`, `_engineRunning`, `_updateTrayIcon` (engine logic)
- Scoatem din `_buildContent()`: case-urile interpreter, assistant, calendar, voice
- Scoatem: `RustLib.init()` din main()
- Default section: `NavSection.dictate`
- Titlu fereastră: "Talkye Scriber"

### `app/lib/screens/settings_screen.dart`
- Scoatem: secțiunea "TEXT TO SPEECH" (Pocket TTS)
- Scoatem: secțiunea "SPEECH RECOGNITION" (STT backend — Scriber are propriul STT)
- Scoatem: `engineRunning` parameter și logica aferentă
- Scoatem: `engineVersion()` din About (vine din Rust FFI)
- Scoatem: import `src/rust/api/simple.dart`
- Rămâne: Audio info, About (simplificat), Diagnostics

### `app/pubspec.yaml`
- Scoatem: `flutter_rust_bridge` dependency
- Scoatem: referințe la rust builder

### `app/flutter_rust_bridge.yaml`
- De șters (nu mai avem Rust)

## Fișiere care RĂMÂN neschimbate

- `app/lib/screens/dictate_screen.dart` — ecranul principal Scriber
- `app/lib/screens/chat_screen.dart` — chat cu LLM
- `app/lib/screens/key_picker_dialog.dart` — keyboard trigger picker
- `app/lib/status_bar.dart` — RAM/CPU/GPU monitor
- `app/lib/theme.dart` — dark theme
- `sidecar/` — Python server (tot)
- `app/assets/` — icons, animations

## Ordine de execuție

1. Ștergem fișierele pure (interpreter, voice, voice_names)
2. Curățăm sidebar.dart
3. Curățăm main.dart (imports, settings, build content)
4. Curățăm settings_screen.dart
5. Eliminăm Rust: core/, app/rust/, app/lib/src/rust/, FRB config
6. Curățăm pubspec.yaml
7. Ștergem docs obsolete, rescriem README
8. Ștergem models/, .env
9. Test build: `cd app && flutter build linux`

## Risc principal

Eliminarea flutter_rust_bridge din build system. FRB se integrează adânc
în Flutter build (rust_builder, codegen). Dacă build-ul se strică,
alternativa e să păstrăm FRB cu un API gol (doar engineVersion).
