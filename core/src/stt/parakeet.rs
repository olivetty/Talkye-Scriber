//! Local STT via parakeet-rs — NVIDIA Parakeet TDT v3.
//!
//! Chunked transcription with:
//! - Silero VAD for speech/silence detection
//! - Smart flush at natural pauses (speech_active stays true)
//! - Small overlap buffer (300ms) as phonetic anchor for TDT context
//! - speech_chunks_in_buf prevents transcribing silence after flush
//! - Utterance end only resets state when there's actual speech to close

use anyhow::{Context, Result};
use tokio::sync::mpsc;
use std::time::Instant;

use crate::audio::AudioChunk;
use crate::config::SttConfig;
use crate::vad::SileroVad;
use super::{SttEvent, SttWord};

use parakeet_rs::Transcriber;

/// VAD probability above this = speech.
const VAD_SPEECH_THRESHOLD: f32 = 0.35;

/// Minimum buffer before smart flush at a VAD pause (ms).
const MIN_FLUSH_MS: u64 = 3000;

/// Maximum buffer before forced flush during continuous speech (ms).
const MAX_FLUSH_MS: u64 = 6000;

/// Silence duration to trigger end-of-utterance (ms).
const SILENCE_TRIGGER_MS: u64 = 1500;

/// Maximum buffer duration before forced transcription (ms).
const MAX_BUFFER_MS: u64 = 8000;

/// Interval for emitting interim results (ms).
const INTERIM_INTERVAL_MS: u64 = 1500;

/// Minimum audio samples to attempt transcription (0.5s at 16kHz).
const MIN_TRANSCRIBE_SAMPLES: usize = 8000;

/// Overlap kept as phonetic anchor for TDT context (300ms at 16kHz).
const OVERLAP_SAMPLES: usize = 4800;

/// Minimum silence before smart flush triggers (ms).
/// Catch fast speaker breath pauses.
const MIN_SILENCE_FOR_FLUSH_MS: u64 = 600;

pub async fn run_parakeet_stt(
    config: &SttConfig,
    audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();

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

async fn run_vad_loop(
    mut model: parakeet_rs::ParakeetTDT,
    mut vad: SileroVad,
    mut audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    let mut audio_buf: Vec<f32> = Vec::with_capacity(16000 * 10);
    let mut overlap_buf: Vec<f32> = Vec::new(); // 300ms phonetic anchor
    let mut speech_active = false;
    let mut silence_start: Option<Instant> = None;
    let mut last_interim = Instant::now();
    let mut speech_chunks_in_buf: u32 = 0;
    // When we enter "silence after flush" state, track how long we stay there.
    let mut idle_since: Option<Instant> = None;

    // Heartbeat
    let mut hb_timer = Instant::now();
    let mut hb_chunks: u64 = 0;
    let mut hb_speech: u64 = 0;
    let mut last_event_time = Instant::now();
    let mut stall_warned = false;

    tracing::info!("[STT-PARAKEET] ready (VAD + 300ms overlap anchor)...");

    while let Some(chunk) = audio_rx.recv().await {
        let samples = bytes_to_f32(&chunk);
        let vad_prob = vad.avg_probability(&samples)?;
        let is_speech = vad_prob > VAD_SPEECH_THRESHOLD;

        hb_chunks += 1;
        if is_speech { hb_speech += 1; }
        if hb_timer.elapsed().as_secs() >= 5 {
            let stall = last_event_time.elapsed().as_secs();
            tracing::info!(
                "[STT-PARAKEET] heartbeat: chunks={hb_chunks} speech={hb_speech} \
                 vad={vad_prob:.2} active={speech_active} buf={}ms \
                 overlap={}ms spk_in_buf={speech_chunks_in_buf} last_evt={}s",
                samples_to_ms(audio_buf.len()),
                samples_to_ms(overlap_buf.len()), stall,
            );
            if stall >= 10 && !stall_warned {
                tracing::warn!("[STT-PARAKEET] STALL: no events for {stall}s!");
                stall_warned = true;
            }
            hb_timer = Instant::now();
            hb_chunks = 0;
            hb_speech = 0;
        }

        if is_speech {
            if !speech_active {
                speech_active = true;
                silence_start = None;
                idle_since = None;
            } else {
                silence_start = None;
                idle_since = None;
            }
            audio_buf.extend_from_slice(&samples);
            speech_chunks_in_buf += 1;

            let buffer_ms = samples_to_ms(audio_buf.len());
            if buffer_ms >= MAX_FLUSH_MS {
                tracing::info!("[STT-PARAKEET] forced flush ({buffer_ms}ms continuous)");
                do_flush(&mut model, &mut audio_buf, &mut overlap_buf,
                         &event_tx, false).await;
                speech_chunks_in_buf = 0;
                last_interim = Instant::now();
                last_event_time = Instant::now();
                stall_warned = false;
            }
        } else if speech_active {
            audio_buf.extend_from_slice(&samples);

            if silence_start.is_none() {
                silence_start = Some(Instant::now());
            }
            let silence_ms = silence_start.unwrap().elapsed().as_millis() as u64;
            let buffer_ms = samples_to_ms(audio_buf.len());

            // Smart flush: 2.5s+ buffered + real pause (500ms+)
            if buffer_ms >= MIN_FLUSH_MS
                && silence_ms >= MIN_SILENCE_FOR_FLUSH_MS
                && silence_ms < SILENCE_TRIGGER_MS
            {
                tracing::info!(
                    "[STT-PARAKEET] smart flush ({buffer_ms}ms, silence={silence_ms}ms, \
                     spk={speech_chunks_in_buf})"
                );
                do_flush(&mut model, &mut audio_buf, &mut overlap_buf,
                         &event_tx, false).await;
                speech_chunks_in_buf = 0;
                // speech_active stays TRUE
                last_interim = Instant::now();
                last_event_time = Instant::now();
                stall_warned = false;
                silence_start = None;
                continue;
            }

            // Interim results
            if last_interim.elapsed().as_millis() as u64 >= INTERIM_INTERVAL_MS
                && audio_buf.len() > 4800 && speech_chunks_in_buf > 0
            {
                if let Some(text) = transcribe_with_anchor(&mut model, &audio_buf, &overlap_buf) {
                    if !text.is_empty() {
                        send_event(&event_tx, SttEvent::Interim(text)).await;
                    }
                }
                last_interim = Instant::now();
            }

            // Utterance end: extended silence
            if silence_ms >= SILENCE_TRIGGER_MS {
                if speech_chunks_in_buf > 0 && audio_buf.len() >= MIN_TRANSCRIBE_SAMPLES {
                    tracing::info!(
                        "[STT-PARAKEET] utterance end (buf={buffer_ms}ms, \
                         spk={speech_chunks_in_buf})"
                    );
                    if let Some(text) = transcribe_with_anchor(
                        &mut model, &audio_buf, &overlap_buf
                    ) {
                        if !text.is_empty() {
                            emit_final(&event_tx, &text, true).await;
                        }
                    }
                    // Real utterance end — full reset, clear overlap too
                    overlap_buf.clear();
                    audio_buf.clear();
                    speech_chunks_in_buf = 0;
                    vad.reset();
                    speech_active = false;
                    silence_start = None;
                    idle_since = None;
                    last_interim = Instant::now();
                    send_event(&event_tx, SttEvent::UtteranceEnd).await;
                    last_event_time = Instant::now();
                    stall_warned = false;
                } else if speech_chunks_in_buf == 0 {
                    // Pure silence after a smart flush.
                    // Keep speech_active for a while to allow continuation,
                    // but if idle too long (5s), do full reset to prevent stall.
                    if idle_since.is_none() {
                        idle_since = Some(Instant::now());
                    }
                    let idle_ms = idle_since.unwrap().elapsed().as_millis() as u64;

                    if idle_ms >= 5000 {
                        // Idle too long — full reset
                        tracing::info!(
                            "[STT-PARAKEET] idle timeout after flush ({idle_ms}ms) — full reset"
                        );
                        overlap_buf.clear();
                        audio_buf.clear();
                        speech_chunks_in_buf = 0;
                        vad.reset();
                        speech_active = false;
                        silence_start = None;
                        idle_since = None;
                        last_interim = Instant::now();
                        send_event(&event_tx, SttEvent::UtteranceEnd).await;
                        last_event_time = Instant::now();
                        stall_warned = false;
                    } else {
                        tracing::debug!(
                            "[STT-PARAKEET] silence after flush ({buffer_ms}ms, idle={idle_ms}ms) \
                             — clearing, keeping speech_active"
                        );
                        audio_buf.clear();
                        silence_start = None;
                    }
                } else {
                    // Has some speech but too short — transcribe anyway
                    tracing::info!(
                        "[STT-PARAKEET] utterance end short ({buffer_ms}ms) — transcribing"
                    );
                    if let Some(text) = transcribe_with_anchor(
                        &mut model, &audio_buf, &overlap_buf
                    ) {
                        if !text.is_empty() {
                            emit_final(&event_tx, &text, true).await;
                        }
                    }
                    overlap_buf.clear();
                    audio_buf.clear();
                    speech_chunks_in_buf = 0;
                    vad.reset();
                    speech_active = false;
                    silence_start = None;
                    idle_since = None;
                    last_interim = Instant::now();
                    send_event(&event_tx, SttEvent::UtteranceEnd).await;
                    last_event_time = Instant::now();
                    stall_warned = false;
                }
            }

            // Force transcription if buffer too long
            if buffer_ms >= MAX_BUFFER_MS {
                tracing::info!("[STT-PARAKEET] max buffer ({buffer_ms}ms), forcing");
                do_flush(&mut model, &mut audio_buf, &mut overlap_buf,
                         &event_tx, false).await;
                speech_chunks_in_buf = 0;
                speech_active = false;
                silence_start = None;
                idle_since = None;
                last_interim = Instant::now();
                last_event_time = Instant::now();
                stall_warned = false;
            }
        }
    }

    tracing::warn!("[STT-PARAKEET] audio channel closed");
    Ok(())
}

/// Flush: transcribe with overlap anchor, save new overlap, clear buf.
async fn do_flush(
    model: &mut parakeet_rs::ParakeetTDT,
    audio_buf: &mut Vec<f32>,
    overlap_buf: &mut Vec<f32>,
    event_tx: &mpsc::Sender<SttEvent>,
    speech_final: bool,
) {
    if audio_buf.len() < MIN_TRANSCRIBE_SAMPLES {
        return; // Don't clear — let it accumulate
    }
    if let Some(text) = transcribe_with_anchor(model, audio_buf, overlap_buf) {
        if !text.is_empty() {
            emit_final(event_tx, &text, speech_final).await;
        }
    }
    // Save last 300ms as phonetic anchor for next chunk
    if audio_buf.len() > OVERLAP_SAMPLES {
        *overlap_buf = audio_buf[audio_buf.len() - OVERLAP_SAMPLES..].to_vec();
    } else {
        *overlap_buf = audio_buf.clone();
    }
    audio_buf.clear();
}

/// Transcribe with overlap anchor prepended. Uses word timestamps to skip
/// the overlap region so we don't duplicate words.
fn transcribe_with_anchor(
    model: &mut parakeet_rs::ParakeetTDT,
    audio: &[f32],
    overlap: &[f32],
) -> Option<String> {
    if audio.is_empty() { return None; }

    let (full_audio, overlap_secs) = if !overlap.is_empty() {
        let mut combined = Vec::with_capacity(overlap.len() + audio.len());
        combined.extend_from_slice(overlap);
        combined.extend_from_slice(audio);
        (combined, overlap.len() as f64 / 16000.0)
    } else {
        (audio.to_vec(), 0.0)
    };

    let t0 = Instant::now();
    match model.transcribe_samples(
        full_audio, 16000, 1,
        Some(parakeet_rs::TimestampMode::Words),
    ) {
        Ok(result) => {
            let ms = t0.elapsed().as_millis();
            let audio_ms = samples_to_ms(audio.len());

            if overlap_secs > 0.0 && !result.tokens.is_empty() {
                // Skip words that fall within the overlap region
                let new_words: Vec<&str> = result.tokens.iter()
                    .filter(|t| t.start as f64 >= overlap_secs - 0.05)
                    .map(|t| t.text.as_str())
                    .collect();
                let text = new_words.join(" ").trim().to_string();
                let skipped = result.tokens.len() - new_words.len();
                tracing::info!(
                    "[STT-PARAKEET] transcribed {audio_ms}ms (anchor={:.0}ms, \
                     skip={skipped}w) in {ms}ms: \"{text}\"",
                    overlap_secs * 1000.0
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

async fn emit_final(tx: &mpsc::Sender<SttEvent>, text: &str, speech_final: bool) {
    let words: Vec<SttWord> = text
        .split_whitespace()
        .map(|w| SttWord { word: w.to_string(), start: 0.0, end: 0.0 })
        .collect();
    send_event(tx, SttEvent::Final {
        transcript: text.to_string(), words, speech_final,
    }).await;
}

async fn send_event(tx: &mpsc::Sender<SttEvent>, event: SttEvent) {
    match tokio::time::timeout(
        tokio::time::Duration::from_millis(100),
        tx.send(event),
    ).await {
        Ok(Ok(())) => {}
        Ok(Err(_)) => tracing::warn!("[STT-PARAKEET] event channel closed"),
        Err(_) => tracing::warn!("[STT-PARAKEET] event send timeout (100ms)"),
    }
}

fn bytes_to_f32(bytes: &[u8]) -> Vec<f32> {
    bytes.chunks_exact(2)
        .map(|p| i16::from_le_bytes([p[0], p[1]]) as f32 / 32768.0)
        .collect()
}

fn samples_to_ms(samples: usize) -> u64 {
    (samples as u64 * 1000) / 16000
}
