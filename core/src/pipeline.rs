//! Pipeline orchestration — STT → Accumulator → Translate → TTS → Playback.
//!
//! Mirrors prototype/test_deepgram.py architecture:
//! - Accumulator with dual threshold (first flush fast, then min_words)
//! - Parallel translation (3 concurrent) with ordered output
//! - Session-reuse playback: one cpal stream per utterance, not per message

use anyhow::Result;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::{mpsc, Semaphore};

use crate::accumulator::{self, Accumulator};
use crate::audio::capture::AudioCapture;
use crate::config::Config;
use crate::engine::EngineEvent;
use crate::stt::{SttEvent, run_stt};
use crate::translate::Translator;
use crate::tts;

/// Idle timeout before finishing a playback session (ms).
/// If no new TTS message arrives within this window, the cpal stream is dropped.
/// Must be longer than typical translate latency (~300-500ms) to bridge messages.
const SESSION_IDLE_MS: u64 = 2000;

/// Don't split into clauses if message is shorter than this (words).
/// Short messages sound better as a single TTS unit.
const CLAUSE_SPLIT_MIN_WORDS: usize = 12;

/// Find paplay binary — checks PATH first, then common locations.
/// Flutter may launch the engine with a minimal PATH, so we fall back
/// to well-known paths if `paplay` isn't found via PATH alone.
fn find_paplay() -> Option<String> {
    // Try PATH first
    if std::process::Command::new("paplay")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        return Some("paplay".into());
    }
    // Fallback to common locations
    for path in ["/usr/bin/paplay", "/usr/local/bin/paplay", "/bin/paplay"] {
        if std::path::Path::new(path).exists() {
            return Some(path.into());
        }
    }
    None
}

pub struct Pipeline {
    config: Config,
    event_tx: mpsc::Sender<EngineEvent>,
    running: Arc<AtomicBool>,
}

impl Pipeline {
    pub fn new(
        config: Config,
        event_tx: mpsc::Sender<EngineEvent>,
        running: Arc<AtomicBool>,
    ) -> Self {
        Self { config, event_tx, running }
    }

    fn log(&self, level: &str, msg: String) {
        match level {
            "ERROR" => tracing::error!("{msg}"),
            "WARN" => tracing::warn!("{msg}"),
            _ => tracing::info!("{msg}"),
        }
        let _ = self.event_tx.try_send(EngineEvent::Log {
            level: level.to_string(),
            message: msg,
        });
    }

    pub async fn run(&self) -> Result<()> {
        // ── Ensure virtual audio devices are ready ──
        if let Some(ref output) = self.config.tts.output_device {
            if let Err(e) = crate::audio::r#virtual::ensure_virtual_audio(output) {
                self.log("WARN", format!("[VIRTUAL] audio setup failed: {e:#} — TTS may not be audible"));
            }
        }

        // ── Audio health watchdog (detects Bluetooth reconnect mid-session) ──
        if let Some(ref output) = self.config.tts.output_device {
            let sink = output.clone();
            let flag = self.running.clone();
            tokio::task::spawn_blocking(move || {
                crate::audio::r#virtual::watch_audio_health(&sink, &flag);
            });
        }

        self.log("INFO", format!(
            "Pipeline: STT (lang={}, backend={}) → Translate ({} → {}) → TTS (voice={}, speed={}x)",
            self.config.stt.language, self.config.stt.backend,
            self.config.translate.from_lang, self.config.translate.to_lang,
            self.config.tts.voice, self.config.tts.speed,
        ));
        self.log("INFO", format!(
            "Accumulator: first flush at {}w, then {}w",
            self.config.accumulator.first_words, self.config.accumulator.min_words,
        ));

        // ── Channels ──
        let (audio_tx, audio_rx) = mpsc::channel(256);
        let (stt_tx, mut stt_rx) = mpsc::channel(128);
        let (translate_tx, translate_rx) = mpsc::channel::<(String, u64)>(32);
        let (tts_tx, tts_rx) = mpsc::channel::<String>(32);

        // ── Audio capture (blocking thread) ──
        let capture = AudioCapture::new(&self.config.audio)?;
        self.log("INFO", "[CAPTURE] audio device opened".into());
        let capture_evt = self.event_tx.clone();
        tokio::task::spawn_blocking(move || {
            let _ = capture_evt.try_send(EngineEvent::Log {
                level: "INFO".into(), message: "[CAPTURE] thread started".into(),
            });
            if let Err(e) = capture.start(audio_tx) {
                let _ = capture_evt.try_send(EngineEvent::Log {
                    level: "ERROR".into(), message: format!("[CAPTURE] fatal: {e:#}"),
                });
            }
        });

        // ── STT ──
        let stt_config = self.config.stt.clone();
        tokio::spawn(async move {
            tracing::info!("[STT] task started (backend={})", stt_config.backend);
            if let Err(e) = run_stt(&stt_config, audio_rx, stt_tx).await {
                tracing::error!("[STT] fatal: {e:#}");
            }
        });

        // ── Parallel translator with ordered output ──
        let translator = Arc::new(Translator::new(&self.config.translate));
        let semaphore = Arc::new(Semaphore::new(3));
        let tts_tx_ordered = tts_tx.clone();
        let evt_translate = self.event_tx.clone();

        tokio::spawn(async move {
            tracing::info!("[TRANSLATE] task started");
            Self::ordered_translator(translate_rx, tts_tx_ordered, translator, semaphore, evt_translate).await;
        });

        // ── TTS playback (blocking thread with session reuse) ──
        let tts_config = crate::config::TtsConfig {
            voice: self.config.tts.voice.clone(),
            speed: self.config.tts.speed,
            output_device: self.config.tts.output_device.clone(),
            language: self.config.tts.language.clone(),
        };
        let tts_event_tx = self.event_tx.clone();
        std::thread::spawn(move || {
            Self::tts_thread(tts_config, tts_event_tx, tts_rx);
        });

        // ── Accumulator loop ──
        let mut accum = Accumulator::new(&accumulator::AccumulatorConfig {
            first_words: self.config.accumulator.first_words,
            min_words: self.config.accumulator.min_words,
        });
        let mut seq: u64 = 0;
        let flush_timeout = tokio::time::Duration::from_millis(1500);

        self.log("INFO", "[ACCUM] loop started, waiting for STT events".into());

        loop {
            if !self.running.load(Ordering::Relaxed) {
                self.log("INFO", "[ACCUM] stop signal received".into());
                break;
            }

            let event = if !accum.has_words() {
                match tokio::time::timeout(
                    tokio::time::Duration::from_millis(500),
                    stt_rx.recv(),
                ).await {
                    Ok(Some(e)) => e,
                    Ok(None) => break,
                    Err(_) => continue,
                }
            } else {
                match tokio::time::timeout(flush_timeout, stt_rx.recv()).await {
                    Ok(Some(e)) => e,
                    Ok(None) => break,
                    Err(_) => {
                        if let Some(text) = accum.timeout_flush() {
                            let wc = text.split_whitespace().count();
                            self.log("INFO", format!("[ACCUM] ⏰ timeout flush seq={seq} ({wc}w): \"{text}\""));
                            let _ = translate_tx.send((text, seq)).await;
                            seq += 1;
                        }
                        continue;
                    }
                }
            };

            match event {
                SttEvent::Interim(text) => {
                    self.log("INFO", format!("[STT] interim: \"{text}\""));
                }
                SttEvent::Final { transcript, words, speech_final } => {
                    self.log("INFO", format!(
                        "[STT] ✓ final: \"{transcript}\" speech_final={speech_final} words={}",
                        words.len()
                    ));
                    let word_texts: Vec<String> = words.iter().map(|w| w.word.clone()).collect();

                    if let Some(text) = accum.add_words(word_texts, speech_final) {
                        let wc = text.split_whitespace().count();
                        self.log("INFO", format!("[ACCUM] → flush seq={seq} ({wc}w): \"{text}\""));
                        let _ = translate_tx.send((text, seq)).await;
                        seq += 1;
                    }
                }
                SttEvent::UtteranceEnd => {
                    self.log("INFO", format!("[ACCUM] ── utterance end ── (accum={}w)", accum.word_count()));
                    if let Some(text) = accum.utterance_end() {
                        let wc = text.split_whitespace().count();
                        self.log("INFO", format!("[ACCUM] → flush seq={seq} ({wc}w): \"{text}\""));
                        let _ = translate_tx.send((text, seq)).await;
                        seq += 1;
                    }
                }
            }
        }

        // ── Graceful shutdown: drop senders to signal downstream tasks ──
        self.log("INFO", "[PIPELINE] shutting down — closing channels".into());
        drop(translate_tx);
        drop(tts_tx);
        // stt_rx will close when STT task drops its sender

        Ok(())
    }

    /// TTS thread — generates audio via TTS backend, streams to paplay.
    ///
    /// Uses paplay (PulseAudio CLI) instead of cpal for reliable Linux audio.
    /// cpal had sample rate mismatches and buffer underruns causing distortion.
    /// Streams PCM chunks directly to paplay stdin as they arrive from TTS —
    /// audio starts playing at first chunk, generation continues in parallel.
    fn tts_thread(
        tts_config: crate::config::TtsConfig,
        event_tx: mpsc::Sender<EngineEvent>,
        mut tts_rx: mpsc::Receiver<String>,
    ) {
        let log = {
            let tx = event_tx.clone();
            move |level: &str, msg: String| {
                match level {
                    "ERROR" => tracing::error!("{msg}"),
                    "WARN" => tracing::warn!("{msg}"),
                    _ => tracing::info!("{msg}"),
                }
                let _ = tx.try_send(EngineEvent::Log {
                    level: level.to_string(), message: msg,
                });
            }
        };

        log("INFO", "[TTS] thread started".into());
        log("INFO", format!("[TTS] loading model + voice: {}...", tts_config.voice));

        let t0 = std::time::Instant::now();
        let tts = match tts::create_backend(&tts_config) {
            Ok(t) => {
                let secs = t0.elapsed().as_secs();
                log("INFO", format!("[TTS] model loaded in {secs}s (sr={})", t.sample_rate()));
                t
            }
            Err(e) => {
                log("ERROR", format!("[TTS] init failed: {e:#}"));
                let _ = event_tx.blocking_send(EngineEvent::Error {
                    message: format!("TTS init failed: {e:#}"),
                });
                return;
            }
        };

        // Verify paplay is available
        let paplay_bin = match find_paplay() {
            Some(p) => p,
            None => {
                log("ERROR", "[TTS] paplay not found — install pulseaudio-utils".into());
                return;
            }
        };
        log("INFO", format!("[TTS] playback ready (paplay={}, sr={})", paplay_bin, tts.playback_rate()));

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all().build().unwrap();

        rt.block_on(async {
            log("INFO", "[TTS] ready, waiting for messages".into());

            // Persistent paplay process — stays alive across messages for gapless playback.
            // We keep writing PCM to its stdin. Only killed on idle timeout or shutdown.
            let mut paplay_child: Option<std::process::Child> = None;
            let idle_timeout = tokio::time::Duration::from_millis(SESSION_IDLE_MS);

            loop {
                let text = if paplay_child.is_some() {
                    match tokio::time::timeout(idle_timeout, tts_rx.recv()).await {
                        Ok(Some(t)) => t,
                        Ok(None) => {
                            log("INFO", "[TTS] channel closed, thread exiting".into());
                            // Close stdin → paplay finishes naturally
                            if let Some(mut c) = paplay_child.take() {
                                c.stdin.take();
                                let _ = c.wait();
                            }
                            break;
                        }
                        Err(_) => {
                            log("INFO", "[TTS] session idle timeout — finishing stream".into());
                            // Close stdin → paplay drains remaining audio and exits
                            if let Some(mut c) = paplay_child.take() {
                                c.stdin.take();
                                let _ = c.wait();
                            }
                            continue;
                        }
                    }
                } else {
                    match tts_rx.recv().await {
                        Some(t) => t,
                        None => {
                            log("INFO", "[TTS] channel closed, thread exiting".into());
                            break;
                        }
                    }
                };

                // Drain queued messages
                let mut combined = text;
                let mut drained_count = 0u32;
                while let Ok(next) = tts_rx.try_recv() {
                    combined.push_str(". ");
                    combined.push_str(&next);
                    drained_count += 1;
                }
                if drained_count > 0 {
                    log("INFO", format!("[TTS] merged {drained_count} queued message(s)"));
                }

                // Ensure paplay session exists (reuse across messages for gapless audio)
                if paplay_child.is_none() {
                    let sr = tts.playback_rate().to_string();
                    match std::process::Command::new(&paplay_bin)
                        .args(["--format=s16le", &format!("--rate={sr}"), "--channels=1", "--raw"])
                        .stdin(std::process::Stdio::piped())
                        .spawn()
                    {
                        Ok(child) => {
                            log("INFO", "[TTS] new paplay session started".into());
                            paplay_child = Some(child);
                        }
                        Err(e) => {
                            log("ERROR", format!("[TTS] paplay spawn failed: {e}"));
                            continue;
                        }
                    }
                }

                // Split into clauses only for longer messages
                let word_count = combined.split_whitespace().count();
                let clauses = if word_count < CLAUSE_SPLIT_MIN_WORDS {
                    vec![combined.clone()]
                } else {
                    accumulator::split_clauses(&combined)
                };
                let n = clauses.len();
                log("INFO", format!("[TTS] \"{combined}\" [{n} clause(s), {word_count}w]"));

                let t0 = std::time::Instant::now();
                let mut first_chunk_ms = 0u64;
                let mut first = true;
                let mut chunk_count = 0u32;
                let mut total_samples = 0usize;
                let mut write_error = false;

                for (i, clause) in clauses.iter().enumerate() {
                    log("INFO", format!("[TTS] generating clause {}/{n}: \"{clause}\"", i + 1));
                    match tts.generate_stream(clause, &tts_config.language, &mut |chunk| {
                        chunk_count += 1;
                        total_samples += chunk.len();
                        let elapsed = t0.elapsed().as_millis();
                        let chunk_dur_ms = chunk.len() as u64 * 1000 / tts.playback_rate() as u64;
                        let total_dur_ms = total_samples as u64 * 1000 / tts.playback_rate() as u64;
                        if first {
                            first_chunk_ms = elapsed as u64;
                            first = false;
                            log("INFO", format!(
                                "[TTS] chunk#{chunk_count}: {} samples ({chunk_dur_ms}ms audio), first_chunk={elapsed}ms",
                                chunk.len()
                            ));
                        } else if chunk_count <= 5 || chunk_count % 10 == 0 {
                            log("INFO", format!(
                                "[TTS] chunk#{chunk_count}: {} samples ({chunk_dur_ms}ms), total={total_samples} ({total_dur_ms}ms audio), wall={elapsed}ms",
                                chunk.len()
                            ));
                        }
                        // Stream directly to paplay stdin — audio plays while we generate
                        if !write_error {
                            if let Some(ref mut child) = paplay_child {
                                if let Some(ref mut stdin) = child.stdin {
                                    use std::io::Write;
                                    let mut buf = Vec::with_capacity(chunk.len() * 2);
                                    for &s in chunk {
                                        let val = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
                                        buf.extend_from_slice(&val.to_le_bytes());
                                    }
                                    if stdin.write_all(&buf).is_err() {
                                        write_error = true;
                                    }
                                }
                            }
                        }
                    }) {
                        Ok((fc, tot)) => {
                            let total_dur_ms = total_samples as u64 * 1000 / tts.playback_rate() as u64;
                            log("INFO", format!(
                                "[TTS] clause {}/{n} done: fc={fc}ms tot={tot}ms chunks={chunk_count} samples={total_samples} ({total_dur_ms}ms audio)",
                                i + 1
                            ));
                        }
                        Err(e) => log("ERROR", format!("[TTS] clause {}/{n} error: {e:#}", i + 1)),
                    }
                }

                // If paplay died mid-stream, clean up
                if write_error {
                    log("WARN", "[TTS] paplay write error — restarting session".into());
                    if let Some(mut c) = paplay_child.take() {
                        let _ = c.kill();
                        let _ = c.wait();
                    }
                }

                let total_ms = t0.elapsed().as_millis();
                let dur_ms = total_samples as u64 * 1000 / tts.playback_rate() as u64;
                log("INFO", format!("[TTS] total: first_chunk={first_chunk_ms}ms total={total_ms}ms audio={dur_ms}ms"));
            }
        });
    }

    /// Translate fragments in parallel (max 3), output to TTS in sequence order.
    async fn ordered_translator(
        mut rx: mpsc::Receiver<(String, u64)>,
        tx: mpsc::Sender<String>,
        translator: Arc<Translator>,
        semaphore: Arc<Semaphore>,
        event_tx: mpsc::Sender<EngineEvent>,
    ) {
        let pending: Arc<tokio::sync::Mutex<BTreeMap<u64, (String, String)>>> =
            Arc::new(tokio::sync::Mutex::new(BTreeMap::new()));
        let next_seq = Arc::new(tokio::sync::Mutex::new(0u64));

        while let Some((text, seq)) = rx.recv().await {
            let translator = translator.clone();
            let semaphore = semaphore.clone();
            let pending = pending.clone();
            let next_seq = next_seq.clone();
            let tx = tx.clone();
            let event_tx = event_tx.clone();

            tokio::spawn(async move {
                let _permit = semaphore.acquire().await.unwrap();
                let t0 = std::time::Instant::now();
                match translator.translate(&text).await {
                    Ok(translated) => {
                        let ms = t0.elapsed().as_millis();

                        // Length guard: reject LLM hallucinations
                        let in_wc = text.split_whitespace().count();
                        let out_wc = translated.split_whitespace().count();
                        let rejected = in_wc < 10 && out_wc > in_wc * 3;

                        if rejected {
                            tracing::warn!(
                                "[TRANSLATE] REJECTED seq={seq} (in={in_wc}w out={out_wc}w): \
                                 \"{text}\" → \"{translated}\""
                            );
                            let _ = event_tx.send(EngineEvent::Log {
                                level: "WARN".into(),
                                message: format!("[TRANSLATE] rejected hallucination seq={seq}"),
                            }).await;
                        } else {
                            let log_msg = format!(
                                "[TRANSLATE] seq={seq} ({ms}ms): \"{text}\" → \"{translated}\""
                            );
                            tracing::info!("{log_msg}");
                            let _ = event_tx.send(EngineEvent::Log {
                                level: "INFO".into(), message: log_msg,
                            }).await;
                        }

                        let final_text = if rejected { String::new() } else { translated };
                        let mut map = pending.lock().await;
                        map.insert(seq, (text.clone(), final_text));

                        let mut next = next_seq.lock().await;
                        while let Some((original, result)) = map.remove(&*next) {
                            if !result.is_empty() {
                                let _ = event_tx.send(EngineEvent::Transcript {
                                    original,
                                    translated: result.clone(),
                                }).await;
                                let _ = tx.send(result).await;
                            }
                            *next += 1;
                        }
                    }
                    Err(e) => {
                        tracing::error!("[TRANSLATE] seq={seq} error: {e:#}");
                        let _ = event_tx.send(EngineEvent::Error {
                            message: format!("Translation error: {e:#}"),
                        }).await;
                        let mut map = pending.lock().await;
                        map.insert(seq, (text.clone(), String::new()));
                        let mut next = next_seq.lock().await;
                        while let Some((_original, result)) = map.remove(&*next) {
                            if !result.is_empty() {
                                let _ = tx.send(result).await;
                            }
                            *next += 1;
                        }
                    }
                }
            });
        }
    }
}
