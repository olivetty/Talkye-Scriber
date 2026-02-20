# Local STT Research — Talkye Meet

Research pentru înlocuirea Deepgram cu STT local în aplicația downloadabilă.

## Cerințe

- Streaming real-time (latență sub 3s)
- Suport limba română (și alte limbi europene)
- Rulează local pe CPU sau GPU (CUDA Linux, Metal Mac)
- Integrare Rust nativă (fără Python sidecar)
- Word-level timestamps (pentru accumulator)
- Licență comercială permisivă

## Opțiuni Evaluate

### 1. ⭐ parakeet-rs + NVIDIA Parakeet TDT 0.6B v3

**Verdict: PRIMA OPȚIUNE**

- Crate Rust: `parakeet-rs` (v0.3.3, activ, ~750 downloads/week)
- Model: `nvidia/parakeet-tdt-0.6b-v3` — 600M parametri
- 25 limbi europene inclusiv **română** (auto-detect)
- ONNX Runtime — CUDA, Metal, CPU
- Licență: CC-BY-4.0 (model), MIT/Apache-2.0 (crate)
- Word-level timestamps ✓
- **Streaming via ParakeetEOU** — end-of-utterance detection, 160ms chunks
- 600M params vs Whisper 1.6B = mai mic, mai rapid
- #1 pe HuggingFace ASR leaderboard (v2, English)
- WER competitiv: IT 4.3%, ES 5.4%, EN 6.1%, DE 7.4%, FR 7.7%

Modele disponibile prin parakeet-rs:
- **ParakeetTDT** — offline, 25 limbi, auto-detect, timestamps
- **ParakeetEOU** — streaming, end-of-utterance detection
- **Nemotron** — cache-aware streaming, punctuation (EN only deocamdată)

```rust
// Streaming cu ParakeetEOU
use parakeet_rs::ParakeetEOU;
let mut parakeet = ParakeetEOU::from_pretrained("./eou", None)?;
const CHUNK_SIZE: usize = 2560; // 160ms at 16kHz
for chunk in audio.chunks(CHUNK_SIZE) {
    let text = parakeet.transcribe(chunk, false)?;
    print!("{}", text);
}
```

GPU support:
```toml
parakeet-rs = { version = "0.3", features = ["cuda"] }
```

### 2. sherpa-rs + sherpa-onnx

- Crate Rust: `sherpa-rs` (v0.6.8, ~380 downloads/week)
- Backend: sherpa-onnx (Next-gen Kaldi)
- Suportă: Whisper, Parakeet, Zipformer, SenseVoice
- Streaming ASR ✓, VAD ✓, Speaker diarization ✓
- Cross-platform: Linux, Mac, Windows, Android, iOS
- Licență: MIT
- Mai complex de configurat, dar foarte flexibil
- Poate rula orice model ONNX

### 3. whisper-rs (whisper.cpp bindings)

- Crate Rust: `whisper-rs`
- Backend: whisper.cpp (C++)
- CUDA + Metal support
- 99 limbi (cel mai larg suport)
- Streaming: manual (chunk + re-transcribe)
- Nu are streaming nativ — trebuie implementat VAD + chunking
- Matur, stabil, comunitate mare
- Whisper large-v3: 1.6B params (mai mare decât Parakeet)

### 4. NVIDIA Canary 1B v2

- Model encoder-decoder: FastConformer + Transformer
- 25 limbi europene + **traducere directă** (ASR + AST)
- Ar putea înlocui STT + Translation într-un singur model
- 1B parametri
- ONNX disponibil via `istupakov/canary-1b-v2-onnx`
- Integrare prin sherpa-rs sau direct ONNX Runtime
- Licență: CC-BY-4.0

**Notă importantă**: Canary face STT + traducere. Dacă calitatea traducerii
e suficientă, am putea elimina și Groq din pipeline → cost $0 total.
Necesită testare separată.

### 5. Mistral Voxtral (3B / 24B)

- STT + traducere + comprehension într-un singur model
- 3B (edge) sau 24B (production)
- Apache 2.0
- Foarte nou (iulie 2025), ecosistem imatur
- Nu are integrare Rust directă încă
- 32K context window
- Interesant pentru viitor, prea devreme acum

### 6. Moonshine (Useful Sensors)

- Ultra-lightweight, optimizat pentru edge/embedded
- ONNX, rulează pe CPU modest
- Predominant English
- Nu are suport bun pentru română
- Nu e potrivit pentru use case-ul nostru

## Comparație Finală

| Criteriu | parakeet-rs | sherpa-rs | whisper-rs | Canary 1B v2 |
|---|---|---|---|---|
| Rust crate | ✅ nativ | ✅ bindings | ✅ bindings | ❌ (via sherpa) |
| Streaming | ✅ EOU | ✅ | ⚠️ manual | ⚠️ manual |
| Română | ✅ (25 EU) | ✅ (depinde de model) | ✅ (99 limbi) | ✅ (25 EU) |
| Params | 600M | variabil | 1.6B | 1B |
| CUDA | ✅ | ✅ | ✅ | ✅ |
| Metal (Mac) | ⚠️ CPU ok | ✅ | ✅ | ⚠️ |
| Timestamps | ✅ word-level | ✅ | ✅ | ✅ |
| Licență | CC-BY-4.0 | MIT | MIT | CC-BY-4.0 |
| Traducere | ❌ | ❌ | ❌ | ✅ built-in |
| Maturitate | Nouă dar activă | Matură | Foarte matură | Nouă |

## Plan de Implementare

### Faza 1: parakeet-rs (ParakeetEOU streaming)
1. Adaugă `parakeet-rs` în Cargo.toml cu feature `cuda`
2. Creează `core/src/stt/mod.rs` cu trait `SttBackend`
3. Mută Deepgram în `core/src/stt/deepgram.rs`
4. Creează `core/src/stt/whisper_local.rs` cu ParakeetEOU
5. Configurare din `.env`: `STT_BACKEND=deepgram|parakeet`
6. Download model la prima rulare sau la install
7. Testare comparativă: latență, acuratețe, WER pe română

### Faza 2: Canary 1B v2 (STT + traducere)
1. Testare calitate traducere RO→EN vs Groq
2. Dacă suficient de bună → pipeline simplificat (un singur model)
3. Ar elimina complet costul Groq → $0 total per user

### Faza 3: Benchmark comparativ
1. Extend `bench.rs` cu STT local benchmarks
2. Măsoară: latență per chunk, WER, memorie GPU, CPU usage
3. Compară cu Deepgram pe aceleași audio samples

## Resurse

- [parakeet-rs crate](https://lib.rs/crates/parakeet-rs)
- [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [nvidia/canary-1b-v2](https://huggingface.co/nvidia/canary-1b-v2)
- [sherpa-rs crate](https://lib.rs/crates/sherpa-rs)
- [whisper-rs crate](https://github.com/tazz4843/whisper-rs)
- [Mistral Voxtral](https://mistral.ai/news/voxtral)
