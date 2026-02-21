//! TTS backend abstraction — pocket-tts voice synthesis.
//!
//! pocket-tts: CPU-only, English model, voice cloning, streaming.

pub mod pocket;

use anyhow::Result;
use crate::config::TtsConfig;

/// Trait for TTS backends — generate streaming PCM audio from text.
pub trait TtsBackend: Send {
    /// Stream TTS, calling `on_chunk` with each PCM f32 chunk.
    /// `language` is the target language name (e.g. "English", "French").
    /// Returns (first_chunk_ms, total_ms).
    fn generate_stream(
        &self,
        text: &str,
        language: &str,
        on_chunk: &mut dyn FnMut(&[f32]),
    ) -> Result<(u64, u64)>;

    /// Native sample rate of the TTS output.
    fn sample_rate(&self) -> usize;

    /// Playback rate (sample_rate adjusted for speed).
    fn playback_rate(&self) -> u32;
}

/// Create the TTS backend.
pub fn create_backend(config: &TtsConfig) -> Result<Box<dyn TtsBackend>> {
    tracing::info!("[TTS] using Pocket TTS backend (CPU)");
    Ok(Box::new(pocket::PocketTts::new(config)?))
}
