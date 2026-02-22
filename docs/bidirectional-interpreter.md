# Bidirectional Live Interpreter — Design Document

**Status:** Design complet, implementare planificată
**Data:** Februarie 2026
**Prerequisite:** Task 44 (Chatterbox streaming TTS în interpreter) — DONE

## Viziune

Interpretare vocală bidirecțională în timp real pentru video calls.
Tu vorbești limba ta, celălalt aude limba lui — cu vocea ta.
El vorbește limba lui, tu auzi limba ta — cu vocea lui.

Zero intervenție umană. Zero configurare în timpul call-ului.

## Arhitectura curentă (unidirecțional)

```
OUTGOING (tu → ei):
  Mic real → Parakeet STT (limba ta) → Groq Translate → Chatterbox TTS (vocea ta, limba lor)
  → Virtual Mic (talkye_mic) → Zoom/Meet/Teams trimite
```

Funcțional, testat, performant. Latență ~2-3s sound-to-sound.

## Arhitectura bidirecțională (target)

```
OUTGOING (tu → ei):
  Mic real → Parakeet STT (limba ta)
  → Groq Translate (limba ta → limba lor)
  → Chatterbox TTS (vocea ta clonată, limba lor)
  → Virtual Mic (talkye_mic) → Zoom trimite

INCOMING (ei → tu):
  Zoom → Virtual Speaker (live_interp_out) → Monitor capture
  → Parakeet STT (limba lor)
  → Groq Translate (limba lor → limba ta)
  → Chatterbox TTS (vocea lor clonată*, limba ta)
  → Căști/speakers reale

  * Prima ~15-20s: voce generică (fără clone)
  * După auto-enrollment: vocea lor clonată
```

Două pipeline-uri independente. Același Chatterbox worker (port 8180).
Zero feedback loop prin design-ul audio routing-ului.

## Audio Routing

```
┌──────────┐                              ┌──────────────┐
│ Mic real  │──→ Outgoing Pipeline ──→     │ Virtual Mic  │──→ Zoom trimite
└──────────┘    (STT→Translate→TTS)       │ (talkye_mic) │
                                          └──────────────┘

┌──────────────────┐                      ┌──────────┐
│ Virtual Speaker   │──→ Incoming Pipeline │ Căști    │
│ (live_interp_out) │   (STT→Translate    │ reale    │
│ .monitor          │    →TTS)        ──→ │          │
└──────────────────┘                      └──────────┘
        ↑
   Zoom redă aici
```

### Setup utilizator (one-time, în Zoom/Meet/Teams):
- Microphone → "Interpreter Mic" (talkye_mic)
- Speaker → "Interpreter Speaker" (live_interp_out)

### De ce nu există feedback loop:
- Outgoing TTS → virtual mic only (Zoom aude, tu nu)
- Incoming TTS → căști reale only (tu auzi, Zoom nu)
- Zoom nu redă propriul tău audio înapoi (echo cancellation nativ)
- Mic-ul real captează doar vocea ta, nu TTS-ul incoming (căști)

### Cerință: utilizatorul TREBUIE să folosească căști
Dacă folosește boxe, TTS-ul incoming ajunge în mic → outgoing pipeline
îl captează → traduce traducerea → feedback loop.

## Voice Cloning — Două sisteme

### Outgoing: vocea TA (pre-înregistrată)
- Utilizatorul înregistrează 10-30s de vorbire (flow existent în app)
- WAV-ul se salvează în voices/
- Chatterbox folosește WAV-ul direct ca voice_ref
- prepare_conditionals() extrage embeddings (~1-2s pe GPU, o singură dată)
- Vocea ta e gata instant la pornirea call-ului

### Incoming: vocea LOR (auto-enrollment din call)
- La începutul call-ului, incoming TTS folosește voce generică
- În background, sistemul captează audio-ul celuilalt de pe virtual speaker
- VAD filtrează — păstrează doar segmentele cu vorbire
- După ~5-10 secunde de vorbire acumulată → salvează ca WAV temporar
- Următorul apel Chatterbox include acest WAV ca voice_ref
- prepare_conditionals() durează ~1-2s → de acum TTS sună ca ei
- WAV-ul se poate actualiza periodic (la 15-20s) pentru calitate mai bună

### Experiența utilizatorului:
```
Secunda 0-5:    Call începe. Tu vorbești. Ei aud vocea ta (instant, pre-clonată).
Secunda 5-15:   Ei răspund. Tu auzi traducerea cu voce generică.
                Background: sistemul colectează audio-ul lor.
Secunda 15-20:  Suficient audio colectat. Voice clone pregătit.
Secunda 20+:    Tu auzi traducerea cu VOCEA LOR. Tranziție la granița propoziției.
```

## Chatterbox prepare_conditionals — ce face exact

```python
def prepare_conditionals(self, wav_fpath, exaggeration=0.5):
    # 1. Încarcă WAV, resample la 24kHz și 16kHz
    s3gen_ref_wav = librosa.load(wav_fpath, sr=24000)
    ref_16k_wav = librosa.resample(s3gen_ref_wav, 24000, 16000)

    # 2. S3Gen embed_ref — embedding audio pentru decodor
    s3gen_ref_dict = self.s3gen.embed_ref(s3gen_ref_wav, 24000)

    # 3. Tokenizare audio referință — conditioning pentru T3
    t3_cond_prompt_tokens = s3_tokzr.forward([ref_16k_wav], max_len=plen)

    # 4. VoiceEncoder — speaker embedding
    ve_embed = self.ve.embeds_from_wavs([ref_16k_wav], sample_rate=16000)

    # 5. Construiește conditionalele (ținute în memorie)
    self.conds = Conditionals(t3_cond, s3gen_ref_dict)
```

NU e training. E inferență — extrage features din WAV.
Durează ~1-2 secunde pe GPU. Se face o singură dată per voce.
Nu salvează nimic pe disk — ține embeddings în memorie.

### Comparație cu Pocket TTS voice cloning:
| Aspect | Pocket TTS | Chatterbox |
|--------|-----------|------------|
| Input | WAV (10-30s) | WAV (10-30s) |
| Procesare | Mimi encoder → .safetensors (~15s, CPU) | prepare_conditionals (~1-2s, GPU) |
| Output | Fișier .safetensors pe disk | Embeddings în memorie |
| La runtime | Încarcă .safetensors (~720ms) | Deja în memorie |
| Limbi | English only | 23 limbi |
| Hardware | CPU | GPU |

## Chatterbox Worker — Partajare între pipeline-uri

Ambele pipeline-uri folosesc același worker (port 8180).
Worker-ul procesează o cerere la un moment dat (GPU single-stream).

### Problema: voice switching overhead
Când pipeline-urile alternează, worker-ul schimbă vocea:
- Outgoing: voice_ref = vocea_ta.wav
- Incoming: voice_ref = vocea_lor.wav

Fiecare schimbare = prepare_conditionals (~1-2s overhead).

### Soluție: voice caching în worker
```python
# Cache conditionals per voice_ref path
_voice_cache = {}  # path → Conditionals

def prepare_conditionals_cached(self, wav_fpath, exaggeration=0.5):
    cache_key = (wav_fpath, exaggeration)
    if cache_key in _voice_cache:
        self.conds = _voice_cache[cache_key]
        return  # instant, 0ms
    self.prepare_conditionals(wav_fpath, exaggeration)
    _voice_cache[cache_key] = self.conds
```

Cu cache: prima utilizare ~1-2s, apoi instant.
Memoria: ~50-100MB per voce cached (embeddings).

### Optimizare avansată: predictive voice loading
```
Tu termini de vorbit → outgoing TTS done →
  Worker: pre-load vocea lor (cache hit = instant)
Ei încep să vorbească → incoming STT → translate →
  TTS: vocea lor deja pregătită, zero delay!
```

## Resurse hardware

### VRAM (RTX 4070, 12GB):
- Chatterbox Multilingual: ~5-6GB (un singur model, partajat)
- Voice cache (2 voci): ~100-200MB
- Total: ~6GB — confortabil

### CPU:
- 2x Parakeet STT (outgoing + incoming): moderat
- Audio capture (2 surse): minimal
- VAD (2 instanțe): minimal

### Rețea:
- 2x Groq Translate: ~$0.04/oră (ambele direcții)
- STT local: $0

## Implementare — Faze

### Faza A: Bidirecțional de bază
1. Audio capture din virtual speaker monitor (nouă sursă audio)
2. Al doilea Pipeline cu config inversat
3. UI: mod bidirecțional (start/stop ambele pipeline-uri)
4. Incoming TTS cu voce generică Chatterbox
5. Test cu Zoom/Meet

### Faza B: Auto voice cloning
1. Buffer audio VAD-filtrat din incoming pipeline
2. Salvare WAV după 5-10s de vorbire
3. Switch voice_ref la runtime în SidecarTts
4. Voice caching în Chatterbox worker
5. UI indicator: "Cloning voice..." → "Voice cloned ✓"

### Faza C: Optimizare
1. Predictive voice loading (pre-load la schimbarea de tură)
2. Actualizare periodică WAV (calitate mai bună cu mai mult audio)
3. Echo detection (safety net pentru cazul fără căști)
4. Latency optimization

## Riscuri și mitigări

| Risc | Impact | Mitigare |
|------|--------|----------|
| Zoom nu redă pe virtual speaker | Blocker | Documentare clară setup, check în UI |
| Calitate clone din audio comprimat | Mediu | Chatterbox e robust la audio comprimat; testare empirică |
| Feedback loop fără căști | Major | Require headphones; detectare echo |
| Două TTS simultane pe un GPU | Latență | Voice caching; conversația e turn-based natural |
| VRAM insuficient | Blocker | Un singur model Chatterbox, partajat; 6GB din 12GB |
| Latență incoming > 3s | UX | Acceptabil (ca interpret uman); optimizare în Faza C |

## Voice Clone Flow — Nou (Chatterbox-native)

Flowul actual de voice clone trece prin Pocket TTS:
```
Record WAV → precompute_voice (Mimi encoder, ~15s) → .safetensors → Pocket TTS
```

Flow nou propus (Chatterbox-native):
```
Record WAV → salvează WAV → Chatterbox folosește direct
```

### Ce trebuie schimbat:
1. Settings: opțiune "Voice clone engine" — Pocket (CPU) sau Chatterbox (GPU)
2. Când Chatterbox e selectat, skip precompute — WAV-ul e suficient
3. SidecarTts primește WAV path direct (nu .safetensors)
4. Pocket TTS primește .safetensors (ca acum)

### Backward compatibility:
- Vocile existente (.safetensors) continuă să funcționeze cu Pocket TTS
- WAV-urile originale sunt păstrate în voices/ (deja le avem)
- Chatterbox folosește WAV-ul, Pocket folosește .safetensors
- Utilizatorul alege backend-ul din settings

## Relație cu alte module

| Modul | Impact |
|-------|--------|
| core/src/pipeline.rs | Al doilea pipeline instance |
| core/src/tts/sidecar.rs | Dynamic voice_ref (Arc<Mutex>) |
| core/src/audio/capture.rs | Nouă sursă: virtual speaker monitor |
| core/src/audio/virtual.rs | Deja creează sink-urile necesare |
| sidecar/chatterbox_worker.py | Voice caching, prepare endpoint |
| app/lib/screens/interpreter_screen.dart | UI bidirecțional |
| app/rust/src/api/engine.rs | Start/stop două pipeline-uri |
