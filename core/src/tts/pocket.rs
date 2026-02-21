//! Pocket TTS backend — voice cloning, streaming, CPU-only.
//!
//! Wraps the pocket-tts crate. English-only model but fast on CPU.
//! Reference: prototype/test_deepgram.py init_pocket() + speak_pocket().

use anyhow::{Context, Result};
use std::time::Instant;

use crate::config::TtsConfig;
use super::TtsBackend;

/// Pocket TTS engine with voice cloning support.
pub struct PocketTts {
    model: pocket_tts::TTSModel,
    voice_state: pocket_tts::ModelState,
    sample_rate: usize,
    speed: f32,
}

impl PocketTts {
    /// Load model and voice. `voice` is a built-in name, path to .wav, or .safetensors.
    pub fn new(config: &TtsConfig) -> Result<Self> {
        let t0 = Instant::now();
        let model = pocket_tts::TTSModel::load("b6369a24")
            .context("Failed to load Pocket TTS model")?;
        let load_ms = t0.elapsed().as_millis();

        let t1 = Instant::now();
        let voice_state = if config.voice.ends_with(".safetensors") {
            model.get_voice_state_from_prompt_file(&config.voice)
                .context("Failed to load pre-computed voice")?
        } else {
            model.get_voice_state(&config.voice)
                .context("Failed to load voice")?
        };
        let voice_ms = t1.elapsed().as_millis();

        let sample_rate = model.sample_rate;
        tracing::info!(
            "[TTS-POCKET] loaded in {load_ms}ms + voice '{}' in {voice_ms}ms (sr={sample_rate})",
            config.voice
        );

        Ok(Self { model, voice_state, sample_rate, speed: config.speed })
    }
}

impl TtsBackend for PocketTts {
    fn generate_stream(
        &self,
        text: &str,
        _language: &str, // pocket-tts is English-only, ignores language
        on_chunk: &mut dyn FnMut(&[f32]),
    ) -> Result<(u64, u64)> {
        let t0 = Instant::now();
        let mut first_chunk_ms = 0u64;
        let mut first = true;

        for chunk_result in self.model.generate_stream(text, &self.voice_state) {
            let tensor = chunk_result.map_err(|e| anyhow::anyhow!("{e}"))?;
            let data: Vec<f32> = tensor
                .flatten_all().map_err(|e| anyhow::anyhow!("{e}"))?
                .to_vec1().map_err(|e| anyhow::anyhow!("{e}"))?;
            if first {
                first_chunk_ms = t0.elapsed().as_millis() as u64;
                first = false;
            }
            on_chunk(&data);
        }

        let total_ms = t0.elapsed().as_millis() as u64;
        Ok((first_chunk_ms, total_ms))
    }

    fn sample_rate(&self) -> usize {
        self.sample_rate
    }

    fn playback_rate(&self) -> u32 {
        (self.sample_rate as f32 * self.speed) as u32
    }
}
