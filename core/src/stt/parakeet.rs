//! Local STT via parakeet-rs — NVIDIA Parakeet TDT v3.
//!
//! Uses ParakeetTDT (600M params, 25 EU languages, auto-detect).
//! Chunked transcription with:
//! - Silero VAD (neural) for precise speech/silence detection
//! - Smart flush: transcribe at natural pauses (VAD dips), not fixed intervals
//! - Overlap buffer: 0.5s context carried between chunks to avoid mid-word cuts
//! - Word-level timestamps for overlap deduplication

use anyhow::{Context, Result};
use tokio::sync::mpsc;
use std::time::Instant;

use crate::audio::AudioChunk;
use crate::config::SttConfig;
use crate::vad::SileroVad;
use super::{SttEvent, SttWord};

use parakeet_rs::Transcriber;

// ── VAD thresholds ──

/// VAD probability above this = speech.
const VAD_SPEECH_THRESHOLD: f32 = 0.5;

// ── Timing constants ──

/// Minimum buffer before smart flush at a VAD pause (ms).
const MIN_FLUSH_MS: u64 = 1800;

/// Maximum buffer before forced flush during continuous speech (ms).
const MAX_FLUSH_MS: u64 = 3500;

/// Minimum speech duration before we consider transcribing (ms).
const MIN_SPEECH_MS: u64 = 300;

/// Silence duration to trigger end-of-utterance (ms).
const SILENCE_TRIGGER_MS: u64 = 600;

/// Maximum buffer duration before forced transcription (ms).
const MAX_BUFFER_MS: u64 = 8000;

/// Interval for emitting interim results (ms).
const INTERIM_INTERVAL_MS: u64 = 1500;

// ── Overlap buffer ──

/// Overlap duration in seconds — context carried to next chunk.
const OVERLAP_SECS: f32 = 0.5;

/// Overlap in samples at 16kHz.
const OVERLAP_SAMPLES: usize = (16000.0 * OVERLAP_SECS) as usize; // 8000

/// Run the Parakeet STT backend with Silero VAD.
pub async fn run_parakeet_stt(
    config: &SttConfig,
    audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();

    // Load Parakeet TDT model
    let model_path_raw = config.parakeet_model.clone()
        .unwrap_or_else(|| "models/parakeet-tdt".into());
    let model_path = if std::path::Path::new(&model_path_raw).is_absolute() {
        model_path_raw
    } else {
        project_root.join(&model_path_raw).to_string_lossy().to_string()
    };

    tracing::info!("[STT-PARAKEET] loading model from '{model_path}'...");
    let t0 = Instant::now();
    let model = tokio::task::spawn_blocking(move || {
        parakeet_rs::ParakeetTDT::from_pretrained(&model_path, None)
    })
    .await?
    .context("Failed to load Parakeet TDT model")?;
    tracing::info!("[STT-PARAKEET] model loaded in {}ms", t0.elapsed().as_millis());

    // Load Silero VAD model
    let vad_path_raw = config.vad_model.clone()
        .unwrap_or_else(|| "models/silero_vad.onnx".into());
    let vad_path = if std::path::Path::new(&vad_path_raw).is_absolute() {
        std::path::PathBuf::from(vad_path_raw)
    } else {
        project_root.join(&vad_path_raw)
    };

    let t1 = Instant::now();
    let vad = SileroVad::new(&vad_path)?;
    tracing::info!("[STT-PARAKEET] Silero VAD loaded in {}ms", t1.elapsed().as_millis());

    run_vad_loop(model, vad, audio_rx, event_tx).await
}

/// VAD + chunked transcription loop with overlap buffer and smart flush.
///
/// Key insight: smart flush happens when VAD detects a brief silence (micro-pause
/// between words/phrases). This is the `else if speech_active` branch where
/// `is_speech = false` but we haven't hit SILENCE_TRIGGER_MS yet.
async fn run_vad_loop(
    mut model: parakeet_rs::ParakeetTDT,
    mut vad: SileroVad,
    mut audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    let mut audio_buf: Vec<f32> = Vec::with_capacity(16000 * 10);
    let mut overlap_buf: Vec<f32> = Vec::new();
    let mut speech_active = false;
    let mut silence_start: Option<Instant> = None;
    let mut speech_start: Option<Instant> = None;
    let mut last_interim = Instant::now();

    tracing::info!("[STT-PARAKEET] ready, listening (Silero VAD + overlap buffer)...");

    while let Some(chunk) = audio_rx.recv().await {
        let samples = bytes_to_f32(&chunk);
        let vad_prob = vad.avg_probability(&samples)?;
        let is_speech = vad_prob > VAD_SPEECH_THRESHOLD;

        if is_speech {
            if !speech_active {
                speech_active = true;
                speech_start = Some(Instant::now());
                silence_start = None;
                tracing::debug!("[STT-PARAKEET] speech started (vad={vad_prob:.2})");
            } else {
                silence_start = None;
            }
            audio_buf.extend_from_slice(&samples);

            // Safety net: force flush if buffer too long during continuous speech
            let buffer_ms = samples_to_ms(audio_buf.len());
            if buffer_ms >= MAX_FLUSH_MS {
                tracing::info!(
                    "[STT-PARAKEET] forced flush ({buffer_ms}ms continuous speech, vad={vad_prob:.2})"
                );
                flush_with_overlap(
                    &mut model, &mut audio_buf, &mut overlap_buf,
                    &event_tx, false,
                ).await;
                speech_start = Some(Instant::now());
                last_interim = Instant::now();
            }
        } else if speech_active {
            // VAD says no speech, but we're in active speech mode.
            // This is a micro-pause — perfect flush opportunity!
            audio_buf.extend_from_slice(&samples);

            if silence_start.is_none() {
                silence_start = Some(Instant::now());
            }

            let silence_ms = silence_start.unwrap().elapsed().as_millis() as u64;
            let buffer_ms = samples_to_ms(audio_buf.len());

            // Smart flush: VAD detected a pause AND we have enough buffered
            if buffer_ms >= MIN_FLUSH_MS && silence_ms < SILENCE_TRIGGER_MS {
                tracing::info!(
                    "[STT-PARAKEET] smart flush at VAD pause ({buffer_ms}ms, silence={silence_ms}ms)"
                );
                flush_with_overlap(
                    &mut model, &mut audio_buf, &mut overlap_buf,
                    &event_tx, false,
                ).await;
                // Stay in speech_active — this is a mid-speech flush
                speech_start = Some(Instant::now());
                last_interim = Instant::now();
                silence_start = None;
                continue;
            }

            // Interim results during longer pauses
            if last_interim.elapsed().as_millis() as u64 >= INTERIM_INTERVAL_MS
                && audio_buf.len() > 4800
            {
                if let Some(text) = transcribe_buffer(&mut model, &audio_buf) {
                    if !text.is_empty() {
                        let _ = event_tx.send(SttEvent::Interim(text)).await;
                    }
                }
                last_interim = Instant::now();
            }

            // End of utterance: extended silence
            if silence_ms >= SILENCE_TRIGGER_MS {
                let speech_ms = speech_start.map(|s| s.elapsed().as_millis() as u64).unwrap_or(0);

                if speech_ms >= MIN_SPEECH_MS && audio_buf.len() > 4800 {
                    tracing::info!(
                        "[STT-PARAKEET] utterance end (speech={speech_ms}ms, silence={silence_ms}ms, buf={buffer_ms}ms)"
                    );
                    // Clean break — no overlap saved
                    if let Some(text) = transcribe_with_overlap(&mut model, &audio_buf, &overlap_buf) {
                        if !text.is_empty() {
                            emit_final(&event_tx, &text, true).await;
                        }
                    }
                }

                audio_buf.clear();
                overlap_buf.clear();
                vad.reset();
                speech_active = false;
                silence_start = None;
                speech_start = None;
                last_interim = Instant::now();

                let _ = event_tx.send(SttEvent::UtteranceEnd).await;
            }

            // Force transcription if buffer too long
            if buffer_ms >= MAX_BUFFER_MS {
                tracing::info!("[STT-PARAKEET] max buffer ({buffer_ms}ms), forcing transcription");
                flush_with_overlap(
                    &mut model, &mut audio_buf, &mut overlap_buf,
                    &event_tx, false,
                ).await;
                speech_active = false;
                silence_start = None;
                speech_start = None;
                last_interim = Instant::now();
            }
        }
    }

    tracing::warn!("[STT-PARAKEET] audio channel closed");
    Ok(())
}

/// Flush audio buffer with overlap: transcribe, emit, save overlap for next chunk.
async fn flush_with_overlap(
    model: &mut parakeet_rs::ParakeetTDT,
    audio_buf: &mut Vec<f32>,
    overlap_buf: &mut Vec<f32>,
    event_tx: &mpsc::Sender<SttEvent>,
    speech_final: bool,
) {
    if let Some(text) = transcribe_with_overlap(model, audio_buf, overlap_buf) {
        if !text.is_empty() {
            emit_final(event_tx, &text, speech_final).await;
        }
    }

    // Save last OVERLAP_SAMPLES as context for next chunk
    if audio_buf.len() > OVERLAP_SAMPLES {
        *overlap_buf = audio_buf[audio_buf.len() - OVERLAP_SAMPLES..].to_vec();
    } else {
        *overlap_buf = audio_buf.clone();
    }
    audio_buf.clear();
}

/// Transcribe audio with overlap prefix. Uses word timestamps to skip overlap region.
fn transcribe_with_overlap(
    model: &mut parakeet_rs::ParakeetTDT,
    audio_buf: &[f32],
    overlap_buf: &[f32],
) -> Option<String> {
    if audio_buf.is_empty() {
        return None;
    }

    // Prepend overlap buffer for context
    let (full_audio, overlap_duration) = if !overlap_buf.is_empty() {
        let mut combined = Vec::with_capacity(overlap_buf.len() + audio_buf.len());
        combined.extend_from_slice(overlap_buf);
        combined.extend_from_slice(audio_buf);
        let overlap_secs = overlap_buf.len() as f64 / 16000.0;
        (combined, overlap_secs)
    } else {
        (audio_buf.to_vec(), 0.0)
    };

    let t0 = Instant::now();
    match model.transcribe_samples(
        full_audio,
        16000,
        1,
        Some(parakeet_rs::TimestampMode::Words),
    ) {
        Ok(result) => {
            let ms = t0.elapsed().as_millis();
            let audio_ms = samples_to_ms(audio_buf.len());

            if overlap_duration > 0.0 && !result.tokens.is_empty() {
                // Filter out words that fall within the overlap region
                let new_words: Vec<&str> = result.tokens.iter()
                    .filter(|t| t.start as f64 >= overlap_duration - 0.05) // 50ms tolerance
                    .map(|t| t.text.as_str())
                    .collect();

                let text = new_words.join(" ").trim().to_string();
                let skipped = result.tokens.len() - new_words.len();
                tracing::info!(
                    "[STT-PARAKEET] transcribed {audio_ms}ms (overlap={:.0}ms, skipped={skipped}w) in {ms}ms: \"{text}\"",
                    overlap_duration * 1000.0
                );
                Some(text)
            } else {
                tracing::info!(
                    "[STT-PARAKEET] transcribed {audio_ms}ms in {ms}ms: \"{}\"",
                    result.text
                );
                Some(result.text)
            }
        }
        Err(e) => {
            tracing::error!("[STT-PARAKEET] transcription error: {e:#}");
            None
        }
    }
}

/// Transcribe audio buffer without overlap (used for interim results).
fn transcribe_buffer(model: &mut parakeet_rs::ParakeetTDT, audio: &[f32]) -> Option<String> {
    let t0 = Instant::now();
    match model.transcribe_samples(audio.to_vec(), 16000, 1, Some(parakeet_rs::TimestampMode::Words)) {
        Ok(result) => {
            let ms = t0.elapsed().as_millis();
            let audio_ms = samples_to_ms(audio.len());
            tracing::info!(
                "[STT-PARAKEET] interim {audio_ms}ms in {ms}ms: \"{}\"",
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

/// Convert sample count to milliseconds at 16kHz.
fn samples_to_ms(samples: usize) -> u64 {
    (samples as u64 * 1000) / 16000
}
