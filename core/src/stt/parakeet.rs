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

/// Faster first flush for lower initial latency (ms).
/// After the first transcription in an utterance, reverts to MIN_FLUSH_MS.
const FIRST_FLUSH_MS: u64 = 2000;

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
const MIN_SILENCE_FOR_FLUSH_MS: u64 = 600;

/// Shorter silence window for first flush (ms).
const FIRST_SILENCE_FOR_FLUSH_MS: u64 = 400;

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

/// Mutable VAD state — extracted to reduce duplication in the main loop.
struct VadState {
    audio_buf: Vec<f32>,
    overlap_buf: Vec<f32>,
    speech_active: bool,
    silence_start: Option<Instant>,
    last_interim: Instant,
    speech_chunks_in_buf: u32,
    idle_since: Option<Instant>,
    first_flush_done: bool,
    // Heartbeat
    hb_timer: Instant,
    hb_chunks: u64,
    hb_speech: u64,
    last_event_time: Instant,
    stall_warned: bool,
}

impl VadState {
    fn new() -> Self {
        let now = Instant::now();
        Self {
            audio_buf: Vec::with_capacity(16000 * 10),
            overlap_buf: Vec::new(),
            speech_active: false,
            silence_start: None,
            last_interim: now,
            speech_chunks_in_buf: 0,
            idle_since: None,
            first_flush_done: false,
            hb_timer: now,
            hb_chunks: 0,
            hb_speech: 0,
            last_event_time: now,
            stall_warned: false,
        }
    }

    /// Full reset — utterance boundary. Clears everything including overlap.
    fn full_reset(&mut self, vad: &mut SileroVad) {
        self.overlap_buf.clear();
        self.audio_buf.clear();
        self.speech_chunks_in_buf = 0;
        vad.reset();
        self.speech_active = false;
        self.silence_start = None;
        self.idle_since = None;
        self.first_flush_done = false;
        self.last_interim = Instant::now();
        self.last_event_time = Instant::now();
        self.stall_warned = false;
    }

    /// Soft reset after a flush — keeps speech_active and overlap.
    fn soft_reset(&mut self) {
        self.speech_chunks_in_buf = 0;
        self.last_interim = Instant::now();
        self.last_event_time = Instant::now();
        self.stall_warned = false;
    }
}

async fn run_vad_loop(
    mut model: parakeet_rs::ParakeetTDT,
    mut vad: SileroVad,
    mut audio_rx: mpsc::Receiver<AudioChunk>,
    event_tx: mpsc::Sender<SttEvent>,
) -> Result<()> {
    let mut st = VadState::new();

    tracing::info!("[STT-PARAKEET] ready (VAD + 300ms overlap anchor)...");

    while let Some(chunk) = audio_rx.recv().await {
        let samples = bytes_to_f32(&chunk);
        let vad_prob = vad.avg_probability(&samples)?;
        let is_speech = vad_prob > VAD_SPEECH_THRESHOLD;

        st.hb_chunks += 1;
        if is_speech { st.hb_speech += 1; }
        if st.hb_timer.elapsed().as_secs() >= 5 {
            let stall = st.last_event_time.elapsed().as_secs();
            tracing::info!(
                "[STT-PARAKEET] heartbeat: chunks={} speech={} \
                 vad={vad_prob:.2} active={} buf={}ms \
                 overlap={}ms spk_in_buf={} last_evt={}s",
                st.hb_chunks, st.hb_speech, st.speech_active,
                samples_to_ms(st.audio_buf.len()),
                samples_to_ms(st.overlap_buf.len()),
                st.speech_chunks_in_buf, stall,
            );
            if stall >= 10 && !st.stall_warned {
                tracing::warn!("[STT-PARAKEET] STALL: no events for {stall}s!");
                st.stall_warned = true;
            }
            st.hb_timer = Instant::now();
            st.hb_chunks = 0;
            st.hb_speech = 0;
        }

        if is_speech {
            st.speech_active = true;
            st.silence_start = None;
            st.idle_since = None;
            st.audio_buf.extend_from_slice(&samples);
            st.speech_chunks_in_buf += 1;

            let buffer_ms = samples_to_ms(st.audio_buf.len());
            if buffer_ms >= MAX_FLUSH_MS {
                tracing::info!("[STT-PARAKEET] forced flush ({buffer_ms}ms continuous)");
                do_flush(&mut model, &mut st.audio_buf, &mut st.overlap_buf,
                         &event_tx, false).await;
                st.soft_reset();
            }
        } else if st.speech_active {
            st.audio_buf.extend_from_slice(&samples);

            if st.silence_start.is_none() {
                st.silence_start = Some(Instant::now());
            }
            let silence_ms = st.silence_start.unwrap().elapsed().as_millis() as u64;
            let buffer_ms = samples_to_ms(st.audio_buf.len());

            // Smart flush: use faster thresholds for first flush in utterance
            let flush_ms = if st.first_flush_done { MIN_FLUSH_MS } else { FIRST_FLUSH_MS };
            let silence_needed = if st.first_flush_done { MIN_SILENCE_FOR_FLUSH_MS } else { FIRST_SILENCE_FOR_FLUSH_MS };

            if buffer_ms >= flush_ms
                && silence_ms >= silence_needed
                && silence_ms < SILENCE_TRIGGER_MS
            {
                tracing::info!(
                    "[STT-PARAKEET] smart flush ({buffer_ms}ms, silence={silence_ms}ms, \
                     spk={}, first={})",
                    st.speech_chunks_in_buf, !st.first_flush_done
                );
                st.first_flush_done = true;
                do_flush(&mut model, &mut st.audio_buf, &mut st.overlap_buf,
                         &event_tx, false).await;
                st.soft_reset();
                st.silence_start = None;
                continue;
            }

            // Interim results
            if st.last_interim.elapsed().as_millis() as u64 >= INTERIM_INTERVAL_MS
                && st.audio_buf.len() > 4800 && st.speech_chunks_in_buf > 0
            {
                if let Some(text) = transcribe_with_anchor(&mut model, &st.audio_buf, &st.overlap_buf) {
                    if !text.is_empty() {
                        send_event(&event_tx, SttEvent::Interim(text)).await;
                    }
                }
                st.last_interim = Instant::now();
            }

            // Utterance end: extended silence
            if silence_ms >= SILENCE_TRIGGER_MS {
                if st.speech_chunks_in_buf > 0 && st.audio_buf.len() >= MIN_TRANSCRIBE_SAMPLES {
                    tracing::info!(
                        "[STT-PARAKEET] utterance end (buf={buffer_ms}ms, \
                         spk={})", st.speech_chunks_in_buf
                    );
                    if let Some(text) = transcribe_with_anchor(
                        &mut model, &st.audio_buf, &st.overlap_buf
                    ) {
                        if !text.is_empty() {
                            emit_final(&event_tx, &text, true).await;
                        }
                    }
                    st.full_reset(&mut vad);
                    send_event(&event_tx, SttEvent::UtteranceEnd).await;
                } else if st.speech_chunks_in_buf == 0 {
                    // Pure silence after a smart flush — allow continuation briefly
                    if st.idle_since.is_none() {
                        st.idle_since = Some(Instant::now());
                    }
                    let idle_ms = st.idle_since.unwrap().elapsed().as_millis() as u64;

                    if idle_ms >= 5000 {
                        tracing::info!(
                            "[STT-PARAKEET] idle timeout after flush ({idle_ms}ms) — full reset"
                        );
                        st.full_reset(&mut vad);
                        send_event(&event_tx, SttEvent::UtteranceEnd).await;
                    } else {
                        tracing::debug!(
                            "[STT-PARAKEET] silence after flush ({buffer_ms}ms, idle={idle_ms}ms) \
                             — clearing, keeping speech_active"
                        );
                        st.audio_buf.clear();
                        st.silence_start = None;
                    }
                } else {
                    // Has some speech but too short — transcribe anyway
                    tracing::info!(
                        "[STT-PARAKEET] utterance end short ({buffer_ms}ms) — transcribing"
                    );
                    if let Some(text) = transcribe_with_anchor(
                        &mut model, &st.audio_buf, &st.overlap_buf
                    ) {
                        if !text.is_empty() {
                            emit_final(&event_tx, &text, true).await;
                        }
                    }
                    st.full_reset(&mut vad);
                    send_event(&event_tx, SttEvent::UtteranceEnd).await;
                }
            }

            // Force transcription if buffer too long
            if buffer_ms >= MAX_BUFFER_MS {
                tracing::info!("[STT-PARAKEET] max buffer ({buffer_ms}ms), forcing");
                do_flush(&mut model, &mut st.audio_buf, &mut st.overlap_buf,
                         &event_tx, false).await;
                st.full_reset(&mut vad);
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
