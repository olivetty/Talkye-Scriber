---
inclusion: auto
---

# Coding Standards — Talkye Meet

## Language & Project

- Rust core engine in `core/`, Flutter UI in `app/` (future)
- Prototype reference in `prototype/` — read-only, never modify
- User communicates in Romanian, respond in Romanian
- User works exclusively with AI agents — code must be self-documenting

## File Rules

- Max 300 lines per file. Split if larger.
- One responsibility per file. If you can't describe it in one sentence, split it.
- File names: snake_case, descriptive (`virtual_device.rs` not `vd.rs`)

## Rust Conventions

- Error handling: `anyhow::Result` with `.context("descriptive message")`
- No `.unwrap()` in library code. Ok in `main.rs` and tests only.
- All config reads happen in `config.rs` only. Other modules receive config via constructor.
- Public API: minimal. Only expose what pipeline.rs or FFI needs.
- Types: prefer explicit types over `impl Trait` in function signatures.
- Async: tokio runtime. Channels: `tokio::sync::mpsc` between components.

## Logging (tracing crate)

- `trace!` — per-frame audio data, per-chunk TTS
- `debug!` — interim transcripts, translation context
- `info!` — final transcripts, translations, TTS playback, timing
- `warn!` — recoverable errors, fallbacks
- `error!` — failures that stop a component

## Module Pattern

Each module follows:
```rust
//! One-line description.
//!
//! Detail + prototype reference if applicable.

/// Main struct
pub struct Component { ... }

impl Component {
    /// Constructor — receives config, not env vars
    pub fn new(config: &Config) -> Result<Self> { ... }
    /// Main entry point
    pub async fn run(&self, ...) -> Result<()> { ... }
}
```

## Channel Types Between Components

- `AudioChunk = Vec<u8>` — raw 16-bit PCM, 16kHz mono
- `SttEvent` — enum: Interim, Final, UtteranceEnd
- `String` — translated text (translate → TTS)
- `Vec<f32>` — TTS PCM output (TTS → playback)

## Testing

- Unit tests in same file (`#[cfg(test)] mod tests`)
- Integration tests in `core/tests/`
- Test with `cargo test` (not watch mode)

## Key Reference Files

When modifying pipeline logic, always check:
- `prototype/test_deepgram.py` — the working Python implementation
- `docs/architecture.md` — system design and data flow
