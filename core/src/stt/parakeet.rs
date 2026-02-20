//! Local STT via parakeet-rs — NVIDIA Parakeet TDT v3.
//!
//! Uses ParakeetTDT (600M params, 25 EU languages, auto-detect).
//! Since TDT is batch (not streaming), we implement chunked transcription:
//! - Accumulate audio in a buffer
//! - Simple energy-based VAD to detect speech/silence
//! - Transcribe when silence detected or buffer exceeds max duration
//! - Emit SttEvent::Final with word-level timestamps

use anyhow::{Context, Result};
use tokio::sync::mpsc;
use std::time::Instant;

use crate::audio::AudioChunk;
use crate::config::SttConfig;
use super::{SttEvent, SttWord};

// Trait needed for transcribe_samples()
use parakeet_rs::Transcriber;

/// Energy threshold for speech detection (RMS of i16 samples).
/// Silence is typically < 200, speech > 500.
const SPEECH_ENERGY_THRESHOLD: f64 = 300.0;

/// Minimum speech duration before we consider transcribing (ms).
const MIN_SPEECH_MS: u64 = 300;

/// Silence duration to trigger end-of-utterance (ms).
const SILENCE_TRIGGER_MS: u64 = 600;

/// Maximum buffer duration before forced transcription (ms).
const MAX_BUFFER_MS: u64 = 8000;

/// Periodic flush during active speech — prevents huge batches (ms).
/// Similar to Deepgram's endpointing: transcribe every ~2.5s even without silence.
const PERIODIC_FLUSH_MS: u64 = 2500;

/// Interval for emitting interim results (ms).
const INTERIM_INTERVAL_MS: u64 = 1500;

/// Run the Parakeet STT backend.
pub async fn run_parakeet_stt(
    config: &SttConfig,
    audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    let model_path_raw = config.parakeet_model.clone()
        .unwrap_or_else(|| "models/parakeet-tdt".into());

    // Resolve relative to project root (same as .env resolution)
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let model_path = if std::path::Path::new(&model_path_raw).is_absolute() {
        model_path_raw
    } else {
        project_root.join(&model_path_raw).to_string_lossy().to_string()
    };

    tracing::info!("[STT-PARAKEET] loading model from '{model_path}'...");
    let t0 = Instant::now();

    // Load model in blocking thread (heavy I/O + ONNX init)
    let model = tokio::task::spawn_blocking(move || {
        parakeet_rs::ParakeetTDT::from_pretrained(&model_path, None)
    })
    .await?
    .context("Failed to load Parakeet TDT model")?;

    let load_ms = t0.elapsed().as_millis();
    tracing::info!("[STT-PARAKEET] model loaded in {load_ms}ms");

    // Run the VAD + transcription loop
    run_vad_loop(model, audio_rx, event_tx).await
}

/// VAD + chunked transcription loop.
async fn run_vad_loop(
    mut model: parakeet_rs::ParakeetTDT,
    mut audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    // Audio buffer: f32 samples at 16kHz
    let mut audio_buf: Vec<f32> = Vec::with_capacity(16000 * 10); // 10s capacity
    let mut speech_active = false;
    let mut silence_start: Option<Instant> = None;
    let mut speech_start: Option<Instant> = None;
    let mut last_interim = Instant::now();

    tracing::info!("[STT-PARAKEET] ready, listening...");

    while let Some(chunk) = audio_rx.recv().await {
        // Convert i16 LE bytes to f32 samples
        let samples = bytes_to_f32(&chunk);
        let energy = rms_energy(&samples);

        let is_speech = energy > SPEECH_ENERGY_THRESHOLD;

        if is_speech {
            if !speech_active {
                speech_active = true;
                speech_start = Some(Instant::now());
                silence_start = None;
                tracing::debug!("[STT-PARAKEET] speech started (energy={energy:.0})");
            } else {
                silence_start = None;
            }
            audio_buf.extend_from_slice(&samples);

            // Periodic flush during continuous speech — prevents huge batches
            let buffer_ms = (audio_buf.len() as u64 * 1000) / 16000;
            if buffer_ms >= PERIODIC_FLUSH_MS {
                tracing::info!(
                    "[STT-PARAKEET] periodic flush ({buffer_ms}ms of active speech)"
                );
                if let Some(text) = transcribe_buffer(&mut model, &audio_buf) {
                    if !text.is_empty() {
                        emit_final(&event_tx, &text, false).await;
                    }
                }
                audio_buf.clear();
                // Keep speech_active=true, reset speech_start for next interval
                speech_start = Some(Instant::now());
                last_interim = Instant::now();
            }
        } else if speech_active {
            // Still accumulating during short silence
            audio_buf.extend_from_slice(&samples);

            if silence_start.is_none() {
                silence_start = Some(Instant::now());
            }

            let silence_ms = silence_start.unwrap().elapsed().as_millis() as u64;
            let buffer_ms = (audio_buf.len() as u64 * 1000) / 16000;

            // Emit interim results periodically
            if last_interim.elapsed().as_millis() as u64 >= INTERIM_INTERVAL_MS
                && audio_buf.len() > 4800 // at least 300ms
            {
                if let Some(text) = transcribe_buffer(&mut model, &audio_buf) {
                    if !text.is_empty() {
                        let _ = event_tx.send(SttEvent::Interim(text)).await;
                    }
                }
                last_interim = Instant::now();
            }

            // End of utterance: silence exceeded threshold
            if silence_ms >= SILENCE_TRIGGER_MS {
                let speech_ms = speech_start.map(|s| s.elapsed().as_millis() as u64).unwrap_or(0);

                if speech_ms >= MIN_SPEECH_MS && audio_buf.len() > 4800 {
                    tracing::info!(
                        "[STT-PARAKEET] utterance end (speech={speech_ms}ms, silence={silence_ms}ms, buf={}ms)",
                        buffer_ms
                    );

                    if let Some(text) = transcribe_buffer(&mut model, &audio_buf) {
                        if !text.is_empty() {
                            emit_final(&event_tx, &text, true).await;
                        }
                    }
                }

                // Reset
                audio_buf.clear();
                speech_active = false;
                silence_start = None;
                speech_start = None;
                last_interim = Instant::now();

                let _ = event_tx.send(SttEvent::UtteranceEnd).await;
            }

            // Force transcription if buffer too long
            if buffer_ms >= MAX_BUFFER_MS {
                tracing::info!("[STT-PARAKEET] max buffer reached ({buffer_ms}ms), forcing transcription");

                if let Some(text) = transcribe_buffer(&mut model, &audio_buf) {
                    if !text.is_empty() {
                        emit_final(&event_tx, &text, false).await;
                    }
                }

                audio_buf.clear();
                speech_active = false;
                silence_start = None;
                speech_start = None;
                last_interim = Instant::now();
            }
        }
        // If not speech_active and not is_speech, just discard silence
    }

    tracing::warn!("[STT-PARAKEET] audio channel closed");
    Ok(())
}

/// Transcribe audio buffer using ParakeetTDT.
fn transcribe_buffer(model: &mut parakeet_rs::ParakeetTDT, audio: &[f32]) -> Option<String> {
    let t0 = Instant::now();
    match model.transcribe_samples(audio.to_vec(), 16000, 1, Some(parakeet_rs::TimestampMode::Words)) {
        Ok(result) => {
            let ms = t0.elapsed().as_millis();
            let audio_ms = (audio.len() as u64 * 1000) / 16000;
            tracing::info!(
                "[STT-PARAKEET] transcribed {audio_ms}ms audio in {ms}ms: \"{}\"",
                result.text
            );
            Some(result.text)
        }
        Err(e) => {
            tracing::error!("[STT-PARAKEET] transcription error: {e:#}");
            None
        }
    }
}

/// Emit a Final event with words extracted from the transcript text.
async fn emit_final(tx: &mpsc::Sender<SttEvent>, text: &str, speech_final: bool) {
    let words: Vec<SttWord> = text
        .split_whitespace()
        .map(|w| SttWord {
            word: w.to_string(),
            start: 0.0,
            end: 0.0,
        })
        .collect();

    let _ = tx.send(SttEvent::Final {
        transcript: text.to_string(),
        words,
        speech_final,
    }).await;
}

/// Convert raw i16 LE bytes to f32 samples normalized to [-1, 1].
fn bytes_to_f32(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(2)
        .map(|pair| {
            let sample = i16::from_le_bytes([pair[0], pair[1]]);
            sample as f32 / 32768.0
        })
        .collect()
}

/// Calculate RMS energy of f32 samples.
fn rms_energy(samples: &[f32]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples.iter().map(|s| (*s as f64) * (*s as f64)).sum();
    (sum / samples.len() as f64).sqrt() * 32768.0 // Scale back to i16 range for threshold
}
