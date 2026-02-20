//! STT backends — pluggable speech-to-text engines.
//!
//! Two backends:
//! - `deepgram`: Cloud streaming via WebSocket (dev/testing, best quality)
//! - `parakeet`: Local via parakeet-rs + NVIDIA Parakeet TDT v3 (production, $0)
//!
//! Both emit the same SttEvent types — pipeline doesn't care which one.

pub mod deepgram;
pub mod parakeet;

use anyhow::Result;
use serde::Deserialize;
use tokio::sync::mpsc;

use crate::audio::AudioChunk;
use crate::config::SttConfig;

/// Events emitted by any STT backend.
#[derive(Debug, Clone)]
pub enum SttEvent {
    /// Interim (partial) transcript — may change.
    Interim(String),
    /// Final transcript for a phrase.
    Final {
        transcript: String,
        words: Vec<SttWord>,
        speech_final: bool,
    },
    /// Utterance ended (long silence).
    UtteranceEnd,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SttWord {
    pub word: String,
    pub start: f64,
    pub end: f64,
}

/// Create and run the configured STT backend.
pub async fn run_stt(
    config: &SttConfig,
    audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    match config.backend.as_str() {
        "deepgram" => {
            let client = deepgram::DeepgramStt::new(config);
            client.run(audio_rx, event_tx).await
        }
        "parakeet" => {
            parakeet::run_parakeet_stt(config, audio_rx, event_tx).await
        }
        other => anyhow::bail!("Unknown STT backend: '{other}'. Use 'deepgram' or 'parakeet'."),
    }
}
