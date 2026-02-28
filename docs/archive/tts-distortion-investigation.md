# TTS Distortion Investigation — Interpreter Pipeline

**Data**: 2026-02-22
**Problemă**: Vocea din Live Interpreter se aude distorsionată
**Scop**: Identificarea și rezolvarea sistematică a cauzei/cauzelor
**Metodă**: O cauză pe rând. Testăm, notăm rezultatul. Nu trecem la următoarea până nu confirmăm.

---

## Pipeline-ul complet (referință)

```
Mic (16kHz i16) → cpal capture → channel
  → Parakeet STT + Silero VAD → SttEvent::Final (cuvinte)
  → Accumulator (3w first flush, 5w subsequent)
  → Groq Translate (llama-3.3-70b, max 3 paralel, ordonat)
  → Clause Split (>12 cuvinte → split la virgulă/punct)
  → TTS Backend (Pocket CPU sau Chatterbox GPU streaming)
  → cpal playback (ringbuf lock-free SPSC, session reuse 2s idle)
```

**Fișiere implicate**:
- `core/src/audio/playback.rs` — playback cpal (ringbuf lock-free)
- `core/src/pipeline.rs` — orchestrare + clause split + TTS thread
- `core/src/tts/pocket.rs` — Pocket TTS (Rust, CPU, English)
- `core/src/tts/sidecar.rs` — Chatterbox sidecar (Python, GPU, 23 limbi)
- `sidecar/chatterbox_worker.py` — server TTS Python (generare + streaming)

---

## Cronologie & Jurnal Principal

| # | Data | Ce s-a făcut | Rezultat | Note |
|---|------|-------------|----------|------|
| 1 | 2026-02-22 | Baseline: ambele TTS distorsionate, preview OK | CONFIRMAT | Mutex<VecDeque> = cauza principală |
| 2 | 2026-02-22 | PRE_BUFFER 0.12→0.4s + counters diagnostic | NU A AJUTAT | Cuvinte tăiate, distorsionat |
| 3 | 2026-02-22 | **Mutex<VecDeque> → ringbuf lock-free SPSC** | **IMPROVEMENT MAJOR** | Distorsiunea principală rezolvată |
| 4 | 2026-02-22 | +fade-in underrun recovery +fade-out finish +watermark off | REGRESIE | Fade-out pe chunk-uri Chatterbox = cuvinte tăiate |
| 5 | 2026-02-22 | Revert fade-out chunk-uri, revert watermark | LA FEL CA #3 | Artefacte rămân — cauza: RTF ≈ 1.0 |
| 6 | 2026-02-22 | Revert complet la ringbuf curat (fără fade/watermark changes) | LA FEL | Confirmă: problema e RTF, nu playback |
| 7 | 2026-02-22 | **TEST B: Pocket TTS cu ringbuf** | TOT RĂU | RTF=0.81-0.93 (OK!), fc=120ms (rapid!), dar underrun=16-62% |
| 8 | 2026-02-22 | **DESCOPERIRE**: "mai grav la început, mai bine pe parcurs" | CLUE CRITIC | PRE_BUFFER 0.2s = prea mic, buffer gol între chunk-uri mici |
| 9 | 2026-02-22 | PRE_BUFFER 0.2s → 1.0s | PENDING TEST | Buffer se umple 1s înainte de playback, absoarbe jitter |
| 10 | 2026-02-22 | **BATCH MODE pentru Pocket TTS** | PENDING TEST | Colectează TOATE sample-urile, apoi push dintr-o dată. Zero underrun teoretic. |

---

## Analiză Profundă — Cauza Fundamentală (post ringbuf fix)

### Ce a rezolvat ringbuf-ul
- Mutex contention între cpal callback (real-time thread) și push() (TTS thread)
- `pop_front()` per sample (480 apeluri/frame) cu Mutex blocat → înlocuit cu `pop_slice()` lock-free
- Aceasta era cauza distorsiunii CONSTANTE din baseline

### Ce NU a rezolvat ringbuf-ul
Underrun-uri cauzate de **RTF (Real-Time Factor) ≈ 1.0** al Chatterbox pe RTX 4070.

**Dovezi din loguri:**

Sesiunea 1 (voce "marius", improvement major):
- pushed=198,720 samples (8.28s audio), underrun=15,296 (7.7%)
- Generare: fc=970ms, tot=7908ms → RTF = 7908/8280 = **0.955**
- Underrun-urile sunt din gap-ul de 970ms first-chunk + variații inter-chunk

Sesiunea 2 (voce "impresiv_", la fel cu întreruperi):
- pushed=101,760 (4.24s audio), underrun=31,232 (**30.7%!**)
- Generare: fc=960ms, tot=4384ms → RTF = 4384/4240 = **1.034**
- RTF > 1.0 = generarea e MAI LENTĂ decât playback-ul → buffer se golește inevitabil

Sesiunea multi-mesaj (2 mesaje consecutive):
- Între mesaje: ~944ms first-chunk latency = buffer gol complet
- 14,144 underrun din 196,800 pushed = 0.59s de liniște în mijlocul vorbirii

### De ce preview-ul sună OK
Preview-ul colectează TOATE sample-urile înainte de playback.
Nu contează RTF-ul — chiar dacă generarea durează 10s, audio-ul e complet când pornește playback-ul.

### Concluzie
**Problema fundamentală: Chatterbox streaming RTF ≈ 1.0 pe RTX 4070.**
Când RTF ≥ 1.0, niciun buffer nu poate preveni underrun-urile pe termen lung.
Ring buffer-ul lock-free a eliminat distorsiunea de la Mutex, dar underrun-urile rămân.

---

## Stare Curentă a Codului (2026-02-22)

### playback.rs
- **ringbuf lock-free SPSC** (ringbuf 0.4.8 crate)
- Consumer (cpal callback): 100% lock-free, `pop_slice()` bulk read
- Producer (TTS thread): `Mutex<HeapProd>` — zero contention (un singur thread)
- PRE_BUFFER_SECS = 1.0
- RING_BUFFER_SECS = 4.0
- Counters: underrun_count, total_pushed

### pipeline.rs
- **Batch mode** (Pocket TTS): colectează TOATE chunk-urile în Vec, apoi push dintr-o dată
- **Streaming mode** (Chatterbox): push imediat per chunk (RTF ≈ 1.0, nu putem aștepta)
- Clause splitting: CLAUSE_SPLIT_MIN_WORDS = 12
- Session reuse: SESSION_IDLE_MS = 2000

### chatterbox_worker.py
- Streaming: chunk_size=25 tokeni, context_window=50
- Fade-in 40ms pe fiecare chunk (fără fade-out)
- Watermark activ per-chunk

---

## Plan de Acțiune — Următorii Pași

### TEST B: Pocket TTS cu ringbuf (PRIORITAR)
**Scop**: Confirmă că ringbuf-ul funcționează corect cu un TTS care are RTF << 1.0.
Pocket TTS e Rust nativ, CPU, fără overhead de rețea. Dacă sună curat, confirmăm:
1. Ringbuf-ul funcționează corect
2. Problema cu Chatterbox e 100% RTF

**Cum testăm**: Schimbă TTS backend la "pocket" din Settings, pornește Interpreter.

### Dacă Pocket sună curat → Fix-uri pentru Chatterbox:
| # | Fix | Efort | Impact |
|---|-----|-------|--------|
| A | PRE_BUFFER 0.2→1.5s | Mic | Absoarbe variații RTF, +1.3s latență |
| B | CLAUSE_SPLIT_MIN_WORDS 12→999 | Mic | Elimină inter-clause first-chunk gaps |
| C | Chatterbox chunk_size 25→50 | Mic | Reduce overhead per-chunk, crește RTF |
| D | Optimizare chatterbox_worker.py | Mediu | Reduce overhead Python/HTTP |

### Dacă Pocket NU sună curat → Problemă în playback.rs:
Investigăm mai departe: sample rate mismatch, cpal buffer size, PipeWire config.
