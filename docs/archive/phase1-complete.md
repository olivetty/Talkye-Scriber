# Phase 1 Complete — Talkye Meet Core Engine

Data: 20 februarie 2026

## Ce am construit

Un motor de traducere vocală în timp real, complet în Rust.
Vorbești română → auzi engleză cu vocea ta, în ~2-3 secunde.

```
Mic → Silero VAD → Parakeet TDT v3 (STT) → Accumulator → Groq LLM (traducere) → Pocket TTS (voce clonată) → Speaker
```

Totul local, cu excepția traducerii (Groq, ~$0.02/oră).

## Stack final (decizii blocate)

| Component | Alegere | Alternativă evaluată | De ce |
|---|---|---|---|
| STT (producție) | parakeet-rs + Parakeet TDT v3 0.6B | Deepgram, Whisper, sherpa-rs, Canary 1B | Singur model cu română din 25 limbi EU. Local, $0, ONNX. |
| STT (dev) | Deepgram Nova-3 | — | Referință de calitate, streaming nativ |
| VAD | Silero VAD V5 (ONNX, 2.2MB) | RMS energy | Neural > heuristic. 0.93+ pe speech, ~0.001 pe silence. ~1ms/chunk. |
| TTS | pocket-tts 0.6.2 (variant b6369a24) | — | Voice cloning, streaming, CPU-only, Rust nativ, $0 |
| Traducere | Groq (Llama 3.3 70B) | OpenAI, xAI | ~150ms latență, $0.02/oră, calitate bună |
| Audio I/O | cpal 0.15 | PulseAudio direct | Cross-platform (Linux + Mac), zero deps externe |
| Audio routing | PulseAudio null-sink + combine-sink | PipeWire native | Funcționează pe ambele (PipeWire e compatibil PA) |
| Runtime | tokio | — | Async channels între componente, parallel translation |

## Modele evaluate și respinse

| Model | De ce nu |
|---|---|
| ParakeetEOU (120M) | English only — nu suportă română |
| Parakeet RNNT 1.1B "multilingual" | 25 limbi dar NU română (AR, JA, KO, HI, etc.) |
| Parakeet CTC 1.1B / 0.6B | English only |
| Nemotron-Speech-Streaming | English only |
| Canary 1B v2 | Interesant (STT+traducere), dar netestată calitatea RO→EN |
| Whisper large-v3 | 1.6B params (vs 600M), nu are streaming nativ, mai lent |
| Silero VAD de pe GitHub | Model broken — returnează constant 0.0005 |

## Numere reale (măsurate)

| Metric | Valoare |
|---|---|
| Model load (Parakeet TDT) | ~3.2s |
| Model load (Silero VAD) | ~21ms |
| Model load (Pocket TTS) | ~460ms model + ~720ms voice |
| VAD inference | ~1ms per 32ms chunk |
| STT transcription | ~180-270ms per 1.8-2.5s audio |
| Translation (Groq) | ~140-250ms |
| TTS first chunk | ~96-120ms |
| TTS total (propoziție) | ~800-2000ms |
| End-to-end (vorbire → audio tradus) | ~2-3s |
| Pre-buffer playback | 150ms |
| Cost per oră | ~$0.02 (doar Groq) |
| Memorie RAM | ~1.5GB (modele ONNX) |

## Arhitectura streaming Parakeet

Parakeet TDT v3 e model offline (nu streaming nativ). Am construit streaming prin:

1. **Silero VAD** — detectează speech/silence la nivel de 32ms
2. **Smart flush** — transcrie la pauze naturale (micro-pauze între fraze), nu la intervale fixe
3. **Overlap buffer** — 0.5s context între chunk-uri, deduplicate prin word timestamps
4. **Forced flush** — safety net la 3.5s speech continuu
5. **End of utterance** — 600ms silence → transcrie tot, reset state

Asta dă comportament quasi-streaming cu latență acceptabilă (~2s per fragment).

## Structura codului

```
core/src/
├── main.rs          — entry point, .env loading
├── config.rs        — toate setările din .env
├── pipeline.rs      — orchestrare: STT → Accumulator → Translate → TTS
├── accumulator.rs   — batching words (3w first, 5w subsequent, 1.5s timeout)
├── vad.rs           — Silero VAD V5 wrapper
├── translate.rs     — Groq LLM cu context window
├── tts.rs           — Pocket TTS streaming + voice clone
├── stt/
│   ├── mod.rs       — SttEvent types, backend factory
│   ├── deepgram.rs  — Deepgram WebSocket client
│   └── parakeet.rs  — Parakeet TDT + Silero VAD loop
└── audio/
    ├── mod.rs       — AudioChunk type
    ├── capture.rs   — mic input via cpal
    └── playback.rs  — streaming ring buffer + PA routing
```

14 unit tests (accumulator) + E2E integration test.
Max 300 linii per fișier. Fiecare modul primește config prin constructor, nu citește .env direct.

## Limitări cunoscute

- Parakeet TDT v3 nu e perfect pe română — ocazional confundă cuvinte scurte sau zgomot de fond
- Latența e ~2-3s (vs ~0.5s Deepgram) — acceptabil, interpreții umani au 3-5s
- Voice cloning (pocket-tts) sună robotic pe propoziții scurte (sub 3 cuvinte)
- Virtual audio modules sunt efemere — se pierd la reboot
- Nu există fallback dacă Groq e down (ar trebui retry + alt provider)
- TTS nu suportă CUDA — CPU only (dar suficient de rapid)

## Ce urmează

- **Phase 2**: Virtual audio devices programatic (creare/ștergere la start/stop)
- **Phase 3**: Traducere bidirecțională (două pipeline-uri paralele)
- **Phase 4**: Flutter UI (system tray, language selector, voice enrollment)
- **Viitor**: Canary 1B v2 (STT + traducere într-un singur model → elimină Groq complet)
