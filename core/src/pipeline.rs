//! Pipeline orchestration — STT → Accumulator → Translate → TTS → Playback.
//!
//! Mirrors prototype/test_deepgram.py architecture:
//! - Accumulator with dual threshold (4w first, then min_words)
//! - Parallel translation (3 concurrent) with ordered output
//! - Sequential TTS playback (never drop audio)

use anyhow::Result;
use std::collections::BTreeMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Semaphore};

use crate::accumulator::{self, Accumulator};
use crate::audio::capture::AudioCapture;
use crate::audio::playback::AudioPlayback;
use crate::config::Config;
use crate::stt::{SttEvent, run_stt};
use crate::translate::Translator;
use crate::tts::TtsEngine;

pub struct Pipeline {
    config: Config,
}

impl Pipeline {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    pub async fn run(&self) -> Result<()> {
        tracing::info!(
            "Pipeline: STT (lang={}, endpointing={}ms) → Translate ({} → {}) → TTS (voice={}, speed={}x)",
            self.config.stt.language, self.config.stt.endpointing_ms,
            self.config.translate.from_lang, self.config.translate.to_lang,
            self.config.tts.voice, self.config.tts.speed,
        );
        tracing::info!(
            "Accumulator: first flush at {}w, then {}w",
            self.config.accumulator.first_words, self.config.accumulator.min_words,
        );

        // ── Channels ──
        let (audio_tx, audio_rx) = mpsc::channel(64);
        let (stt_tx, mut stt_rx) = mpsc::channel(64);
        let (translate_tx, translate_rx) = mpsc::channel::<(String, u64)>(32);
        let (tts_tx, mut tts_rx) = mpsc::channel::<String>(32);

        // ── Audio capture (blocking thread) ──
        let capture = AudioCapture::new(&self.config.audio)?;
        tokio::task::spawn_blocking(move || {
            tracing::info!("[CAPTURE] thread started");
            if let Err(e) = capture.start(audio_tx) {
                tracing::error!("[CAPTURE] fatal: {e:#}");
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

        tokio::spawn(async move {
            tracing::info!("[TRANSLATE] task started");
            Self::ordered_translator(translate_rx, tts_tx_ordered, translator, semaphore).await;
        });

        // ── TTS playback (blocking thread) ──
        let tts_config = crate::config::TtsConfig {
            voice: self.config.tts.voice.clone(),
            speed: self.config.tts.speed,
            output_device: self.config.tts.output_device.clone(),
        };
        std::thread::spawn(move || {
            tracing::info!("[TTS] thread started");
            let tts = match TtsEngine::new(&tts_config) {
                Ok(t) => t,
                Err(e) => { tracing::error!("[TTS] init failed: {e:#}"); return; }
            };
            let mut playback = match AudioPlayback::new(tts_config.output_device.as_deref()) {
                Ok(p) => p,
                Err(e) => { tracing::error!("[TTS] playback init failed: {e:#}"); return; }
            };

            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all().build().unwrap();

            rt.block_on(async {
                tracing::info!("[TTS] ready, waiting for messages");
                while let Some(text) = tts_rx.recv().await {
                    Self::speak(&tts, &mut playback, &mut tts_rx, text);
                }
            });
        });

        // ── Accumulator loop ──
        let mut accum = Accumulator::new(&accumulator::AccumulatorConfig {
            first_words: self.config.accumulator.first_words,
            min_words: self.config.accumulator.min_words,
        });
        let mut seq: u64 = 0;
        let flush_timeout = tokio::time::Duration::from_millis(1500);

        tracing::info!("[ACCUM] loop started, waiting for STT events");

        loop {
            let event = if !accum.has_words() {
                match stt_rx.recv().await {
                    Some(e) => e,
                    None => break,
                }
            } else {
                match tokio::time::timeout(flush_timeout, stt_rx.recv()).await {
                    Ok(Some(e)) => e,
                    Ok(None) => break,
                    Err(_) => {
                        if let Some(text) = accum.timeout_flush() {
                            let wc = text.split_whitespace().count();
                            tracing::info!("[ACCUM] ⏰ timeout flush seq={seq} ({wc}w): \"{text}\"");
                            let _ = translate_tx.send((text, seq)).await;
                            seq += 1;
                        }
                        continue;
                    }
                }
            };

            match event {
                SttEvent::Interim(text) => {
                    tracing::info!("[ACCUM] ... interim: \"{text}\"");
                }
                SttEvent::Final { transcript, words, speech_final } => {
                    tracing::info!(
                        "[ACCUM] ✓ final: \"{transcript}\" speech_final={speech_final} words={}",
                        words.len()
                    );
                    let word_texts: Vec<String> = words.iter().map(|w| w.word.clone()).collect();

                    if let Some(text) = accum.add_words(word_texts, speech_final) {
                        let wc = text.split_whitespace().count();
                        tracing::info!("[ACCUM] → flush seq={seq} ({wc}w): \"{text}\"");
                        let _ = translate_tx.send((text, seq)).await;
                        seq += 1;
                    }
                }
                SttEvent::UtteranceEnd => {
                    tracing::info!("[ACCUM] ── utterance end ── (accum={}w)", accum.word_count());
                    if let Some(text) = accum.utterance_end() {
                        let wc = text.split_whitespace().count();
                        tracing::info!("[ACCUM] → flush seq={seq} ({wc}w): \"{text}\"");
                        let _ = translate_tx.send((text, seq)).await;
                        seq += 1;
                    }
                }
            }
        }

        Ok(())
    }

    /// Drain queued messages, split clauses, generate TTS, play.
    fn speak(
        tts: &TtsEngine,
        playback: &mut AudioPlayback,
        rx: &mut mpsc::Receiver<String>,
        text: String,
    ) {
        // Drain queued messages — never drop content
        let mut combined = text;
        let mut drained = 0u32;
        while let Ok(next) = rx.try_recv() {
            combined.push_str(". ");
            combined.push_str(&next);
            drained += 1;
        }
        if drained > 0 {
            tracing::info!("[TTS] ⏩ merged {drained} queued message(s)");
        }

        let clauses = accumulator::split_clauses(&combined);
        let n = clauses.len();
        tracing::info!("[TTS] 🔊 \"{combined}\" [{n} clause(s)]");

        let stream = match playback.stream(tts.playback_rate()) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!("[TTS] playback stream error: {e:#}");
                return;
            }
        };

        let t0 = std::time::Instant::now();
        let mut first_chunk_ms = 0u64;
        let mut first = true;

        for (i, clause) in clauses.iter().enumerate() {
            tracing::info!("[TTS] generating clause {}/{n}: \"{clause}\"", i + 1);
            match tts.generate_stream(clause, |chunk| {
                if first {
                    first_chunk_ms = t0.elapsed().as_millis() as u64;
                    first = false;
                }
                stream.push(chunk);
            }) {
                Ok((fc, tot)) => {
                    tracing::info!("[TTS]   clause {}/{n} done: fc={fc}ms tot={tot}ms", i + 1);
                }
                Err(e) => tracing::error!("[TTS] clause {}/{n} error: {e:#}", i + 1),
            }
        }

        let total_ms = t0.elapsed().as_millis();
        tracing::info!("[TTS] ✅ total: first_chunk={first_chunk_ms}ms total={total_ms}ms");
        stream.finish();
    }

    /// Translate fragments in parallel (max 3), output to TTS in sequence order.
    async fn ordered_translator(
        mut rx: mpsc::Receiver<(String, u64)>,
        tx: mpsc::Sender<String>,
        translator: Arc<Translator>,
        semaphore: Arc<Semaphore>,
    ) {
        let pending: Arc<tokio::sync::Mutex<BTreeMap<u64, String>>> =
            Arc::new(tokio::sync::Mutex::new(BTreeMap::new()));
        let next_seq = Arc::new(tokio::sync::Mutex::new(0u64));

        while let Some((text, seq)) = rx.recv().await {
            let translator = translator.clone();
            let semaphore = semaphore.clone();
            let pending = pending.clone();
            let next_seq = next_seq.clone();
            let tx = tx.clone();

            tokio::spawn(async move {
                let _permit = semaphore.acquire().await.unwrap();
                let t0 = std::time::Instant::now();
                match translator.translate(&text).await {
                    Ok(translated) => {
                        let ms = t0.elapsed().as_millis();
                        tracing::info!("[TRANSLATE] seq={seq} done in {ms}ms: \"{translated}\"");

                        let mut map = pending.lock().await;
                        map.insert(seq, translated);

                        let mut next = next_seq.lock().await;
                        while let Some(result) = map.remove(&*next) {
                            let _ = tx.send(result).await;
                            *next += 1;
                        }
                    }
                    Err(e) => {
                        tracing::error!("[TRANSLATE] seq={seq} error: {e:#}");
                        let mut next = next_seq.lock().await;
                        if *next == seq { *next += 1; }
                    }
                }
            });
        }
    }
}
