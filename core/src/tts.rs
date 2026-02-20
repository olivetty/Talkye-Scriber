//! Pocket TTS wrapper — voice cloning, streaming, CPU-only.
//!
//! Uses the `pocket-tts` crate (v0.6.x) for text-to-speech with voice cloning.
//! The model runs locally on CPU — no API costs, no rate limits.

use anyhow::{Context, Result};
use std::time::Instant;

/// TTS engine wrapping Pocket TTS.
pub struct TtsEngine {
    model: pocket_tts::TTSModel,
    voice_state: pocket_tts::ModelState,
    sample_rate: usize,
    speed: f32,
}

impl TtsEngine {
    /// Load the TTS model and prepare voice state.
    ///
    /// `voice` can be:
    /// - A built-in voice name (e.g., "alba")
    /// - A path to a .wav file for voice cloning
    pub fn new(voice: &str, speed: f32) -> Result<Self> {
        let t0 = Instant::now();
        let model = pocket_tts::TTSModel::load("default")
            .context("Failed to load Pocket TTS model")?;
        let load_ms = t0.elapsed().as_millis();

        let t1 = Instant::now();
        let voice_state = model
            .get_voice_state(voice)
            .context("Failed to load voice")?;
        let voice_ms = t1.elapsed().as_millis();

        let sample_rate = model.sample_rate;
        tracing::info!(
            "Pocket TTS loaded in {load_ms}ms + voice '{voice}' in {voice_ms}ms (sr={sample_rate})"
        );

        Ok(Self {
            model,
            voice_state,
            sample_rate,
            speed,
        })
    }

    /// Generate speech audio for the given text.
    ///
    /// Returns PCM samples as `Vec<f32>` at `self.sample_rate`.
    pub fn generate(&self, text: &str) -> Result<Vec<f32>> {
        let mut samples = Vec::new();
        for chunk_result in self.model.generate_stream(text, &self.voice_state) {
            let tensor = chunk_result.map_err(|e| anyhow::anyhow!("{e}"))?;
            let chunk_data: Vec<f32> = tensor
                .flatten_all()
                .map_err(|e| anyhow::anyhow!("{e}"))?
                .to_vec1()
                .map_err(|e| anyhow::anyhow!("{e}"))?;
            samples.extend(chunk_data);
        }
        Ok(samples)
    }

    /// Stream speech audio chunk by chunk.
    ///
    /// Calls `on_chunk` with each PCM f32 chunk as it's generated.
    /// Returns (first_chunk_ms, total_ms).
    pub fn generate_stream(
        &self,
        text: &str,
        mut on_chunk: impl FnMut(&[f32]),
    ) -> Result<(u64, u64)> {
        let t0 = Instant::now();
        let mut first_chunk_ms = 0u64;
        let mut first = true;

        for chunk_result in self.model.generate_stream(text, &self.voice_state) {
            let tensor = chunk_result.map_err(|e| anyhow::anyhow!("{e}"))?;
            let chunk_data: Vec<f32> = tensor
                .flatten_all()
                .map_err(|e| anyhow::anyhow!("{e}"))?
                .to_vec1()
                .map_err(|e| anyhow::anyhow!("{e}"))?;
            if first {
                first_chunk_ms = t0.elapsed().as_millis() as u64;
                first = false;
            }
            on_chunk(&chunk_data);
        }

        let total_ms = t0.elapsed().as_millis() as u64;
        Ok((first_chunk_ms, total_ms))
    }

    pub fn sample_rate(&self) -> usize {
        self.sample_rate
    }

    /// Effective playback sample rate (adjusted for speed).
    pub fn playback_rate(&self) -> u32 {
        (self.sample_rate as f32 * self.speed) as u32
    }
}
