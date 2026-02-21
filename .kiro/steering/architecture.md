---
inclusion: auto
---

# Architecture Reference -- Talkye Meet

## What This Is

Real-time voice translation for video calls. Rust core engine, Flutter UI.

## Project Layout

Pocket TTS only. No qwen3. See docs/architecture.md for full details.

## Data Flow

Mic (cpal) -> STT (parakeet|deepgram) -> Accumulator -> Parallel Translator (3 concurrent, ordered) -> Pocket TTS -> Speaker

All arrows are tokio::mpsc channels. Components are independent.

## API Keys Required

- GROQ_API_KEY -- translation
- DEEPGRAM_API_KEY -- STT, dev/testing only
- HF_TOKEN -- HuggingFace, for pocket-tts model download
- Pocket TTS -- free, local, no key needed
- Parakeet STT -- free, local, no key needed
