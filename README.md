# Talkye Meet — AI Meeting Assistant

Înregistrează meeting-uri, identifică cine vorbește, transcrie per speaker,
și generează un summary pe care îl trimite la un endpoint.

Totul local, fără bot în meeting. Aplicația stă pe desktop și ascultă.

## Ce face

1. **Capturează audio** — system audio sau mic, orice meeting platform
2. **Diarizare** — identifică speakerii prin voice embeddings (wespeaker)
3. **Transcrie** — speech-to-text per speaker (Parakeet TDT local sau Deepgram)
4. **Summary** — la finalul meeting-ului, LLM generează summary structurat
5. **Export** — trimite summary + transcript la un endpoint configurabil

## Arhitectura

```
┌─────────────────────────────────────────────────────────┐
│  Flutter UI (desktop)                                    │
│  Meeting transcript · speaker labels · controls          │
└──────────────────────┬──────────────────────────────────┘
                       │ flutter_rust_bridge (FFI)
┌──────────────────────▼──────────────────────────────────┐
│  Rust Core Engine                                        │
│                                                          │
│  Audio Capture (cpal) → Silero VAD → Speech Segments     │
│                                          │               │
│                                    ┌─────┴─────┐        │
│                                    │           │         │
│                              Parakeet STT  WeSpeaker     │
│                              (transcript)  (embedding)   │
│                                    │           │         │
│                                    └─────┬─────┘        │
│                                          │               │
│                                  Speaker Attribution     │
│                                          │               │
│                                  Session Transcript      │
│                                          │               │
│                                    ┌─────┴─────┐        │
│                                    │           │         │
│                              LLM Summary  Export POST    │
└─────────────────────────────────────────────────────────┘
```

## Structura proiectului

```
talkye-meet/
├── core/          # Rust — engine (audio, VAD, STT, diarizare, summary)
├── app/           # Flutter — desktop UI
├── models/        # ONNX models (parakeet-tdt, silero_vad, wespeaker)
└── docs/          # Documentație
```

## Platforme meeting suportate

Orice platformă — capturăm system audio, nu ne integrăm cu API-ul lor:
- Google Meet
- Zoom
- Microsoft Teams
- Discord
- Orice altceva

## Setup (development)

```bash
cp .env.example .env
# Editează .env cu API keys

cd core
cargo build --release
cargo run --release
```

## Documentație

| Document | Descriere |
|---|---|
| [Architecture](docs/architecture.md) | Arhitectura tehnică completă |
| [Meeting Assistant Design](docs/meeting-assistant-design.md) | Specificația detaliată |
| [Local STT Research](docs/local-stt-research.md) | Comparație Parakeet vs Deepgram |
| [Desktop Dictation](docs/desktop-dictation.md) | Modul Scriber (push-to-talk) |

## License

Proprietary. All rights reserved.
