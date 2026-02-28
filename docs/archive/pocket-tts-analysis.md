# Analiza pocket-tts (babybirdprd/pocket-tts)

Sursa: https://github.com/babybirdprd/pocket-tts — Rust/Candle port al Kyutai Pocket TTS.
Aceasta e aceeași librărie pe care o folosim ca dependență (`pocket-tts = "0.6"`).

## Descoperiri critice pentru performanță

### 1. MKL e dependență DEFAULT dar trebuie activat explicit
`intel-mkl-src` e inclus automat pe non-WASM, dar candle nu-l folosește fără feature flag:
```toml
pocket-tts = { version = "0.6", features = ["mkl"] }
```
Fără `features = ["mkl"]`, candle face operații matriciale în Rust pur — de 3-5x mai lent.

### 2. `target-cpu=native` e obligatoriu
Repo-ul are `.cargo/config.toml`:
```toml
[build]
rustflags = ["-C", "target-cpu=native"]
```
Asta activează AVX2/SSE4.2 pe CPU-ul nostru (Ryzen 7 3800X). Fără el, compilatorul generează cod generic x86_64.

### 3. Release profile agresiv
```toml
[profile.release]
lto = "fat"        # Link-Time Optimization complet
codegen-units = 1  # Optimizare maximă (compilare mai lentă)
panic = "abort"    # Fără overhead de unwinding
```

### 4. GPU NU ajută
Modelul e prea mic (~90MB). Overhead-ul de transfer CPU↔GPU depășește câștigul computațional.
Python-ul original setează `torch.set_num_threads(1)` — nici multi-threading nu ajută semnificativ.

### 5. Voice state pre-calculat (.safetensors)
Vocile predefinite (alba, marius, etc.) sunt stocate ca `.safetensors` pre-calculate pe HuggingFace.
Se încarcă cu `get_voice_state_from_prompt_file()` — sare encoding-ul Mimi (partea lentă, 15s).
Trebuie să pre-calculăm `oliver.wav` → `oliver.safetensors`.

### 6. Quantizarea e simulată
Nu e int8 real — doar valori f32 discretizate la 256 nivele. Câștig minim pe CPU.

## Benchmarks (din repo)

| Text      | Python (PyTorch) | Rust (release+MKL) | Speedup |
|-----------|-----------------|---------------------|---------|
| Scurt     | 10.3s           | 1.4s                | 6.2x    |
| Mediu     | 11.9s           | 2.8s                | 3.5x    |
| Lung      | 19.4s           | 12.1s               | 1.6x    |

RTF (Real-Time Factor): ~0.33 pe CPU = 3x mai rapid decât real-time.
Latență first chunk: ~80ms (optimizat, release build).

## Ce lipsea la noi

| Problemă | Impact | Fix |
|----------|--------|-----|
| Fără MKL | 3-5x mai lent | `features = ["mkl"]` |
| Fără `target-cpu=native` | ~30% mai lent | `.cargo/config.toml` |
| Dev build | 2-3x mai lent | `--release` |
| Fără LTO | ~20% mai lent | `profile.release` agresiv |
| Voice state recalculat | +15s la fiecare start | Pre-compute `.safetensors` |
| Playback non-streaming | +2-4s latență | Streaming playback (fixat) |

## Arhitectură internă relevantă

- **FlowLM**: Transformer care generează latent representations din text (LSD - Lagrangian Self Distillation)
- **Mimi (SEANet)**: Codec neural audio — comprimă/decomprimă audio ↔ latent
- **SDPA custom**: Scaled Dot Product Attention cu tiling și skip-mask pentru single-query (streaming)
- **KV-cache**: Ring buffer pentru attention keys/values — evită recalcularea
- **Voice cache**: Server-ul cachează voice states cu key bazat pe path + mtime + size
