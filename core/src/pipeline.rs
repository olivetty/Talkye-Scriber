//! Pipeline orchestration — STT → Accumulator → Translate → TTS → Playback.
//!
//! Mirrors prototype/test_deepgram.py architecture:
//! - Accumulator with dual threshold (4w first, 8w subsequent)
//! - Parallel translation (3 concurrent) with ordered output
//! - Sequential TTS playback (never drop audio)

use anyhow::Result;
use std::collections::BTreeMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Semaphore};

use crate::audio::capture::AudioCapture;
use crate::audio::playback::AudioPlayback;
use crate::config::Config;
use crate::stt::{SttClient, SttEvent};
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
            self.config.stt.language,
            self.config.stt.endpointing_ms,
            self.config.translate.from_lang,
            self.config.translate.to_lang,
            self.config.tts.voice,
            self.config.tts.speed,
        );
        tracing::info!(
            "Accumulator: first flush at {}w, then {}w",
            self.config.accumulator.first_words,
            self.config.accumulator.min_words,
        );

        // ── Channels ──
        let (audio_tx, audio_rx) = mpsc::channel(64);
        let (stt_tx, mut stt_rx) = mpsc::channel(64);
        let (translate_tx, translate_rx) = mpsc::channel::<(String, u64)>(32);
        let (tts_tx, mut tts_rx) = mpsc::channel::<String>(32);

        // ── Audio capture (blocking thread) ──
        let capture = AudioCapture::new(&self.config.audio)?;
        tokio::task::spawn_blocking(move || {
            if let Err(e) = capture.start(audio_tx) {
                tracing::error!("Audio capture error: {e}");
            }
        });

        // ── STT ──
        let stt = SttClient::new(&self.config.stt);
        tokio::spawn(async move {
            if let Err(e) = stt.run(audio_rx, stt_tx).await {
                tracing::error!("STT error: {e}");
            }
        });

        // ── Parallel translator with ordered output ──
        let translator = Arc::new(Translator::new(&self.config.translate));
        let semaphore = Arc::new(Semaphore::new(3)); // max 3 concurrent
        let tts_tx_ordered = tts_tx.clone();

        tokio::spawn(async move {
            Self::ordered_translator(translate_rx, tts_tx_ordered, translator, semaphore).await;
        });

        // ── TTS playback (blocking thread) ──
        let tts_config = crate::config::TtsConfig {
            voice: self.config.tts.voice.clone(),
            speed: self.config.tts.speed,
        };
        std::thread::spawn(move || {
            let tts = match TtsEngine::new(&tts_config) {
                Ok(t) => t,
                Err(e) => { tracing::error!("TTS init failed: {e}"); return; }
            };
            let playback = match AudioPlayback::new() {
                Ok(p) => p,
                Err(e) => { tracing::error!("Playback init failed: {e}"); return; }
            };

            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all().build().unwrap();

            rt.block_on(async {
                while let Some(text) = tts_rx.recv().await {
                    tracing::info!("🔊 TTS: {text}");
                    let mut all_samples = Vec::new();
                    match tts.generate_stream(&text, |chunk| {
                        all_samples.extend_from_slice(chunk);
                    }) {
                        Ok((fc_ms, total_ms)) => {
                            tracing::info!("  TTS: first_chunk={fc_ms}ms total={total_ms}ms");
                            if let Err(e) = playback.play(&all_samples, tts.playback_rate()) {
                                tracing::error!("Playback error: {e}");
                            }
                        }
                        Err(e) => tracing::error!("TTS error: {e}"),
                    }
                }
            });
        });

        // ── Accumulator loop ──
        let mut accum_words: Vec<String> = Vec::new();
        let mut first_flushed = false;
        let mut seq: u64 = 0;

        while let Some(event) = stt_rx.recv().await {
            match event {
                SttEvent::Interim(text) => {
                    tracing::debug!("... {text}");
                }
                SttEvent::Final { transcript, words, speech_final } => {
                    tracing::info!("✓ {transcript}{}", if speech_final { " ◼" } else { "" });

                    let word_texts: Vec<String> = words.iter().map(|w| w.word.clone()).collect();
                    accum_words.extend(word_texts);

                    let threshold = if !first_flushed {
                        self.config.accumulator.first_words
                    } else {
                        self.config.accumulator.min_words
                    };

                    if accum_words.len() >= threshold || speech_final {
                        let text = accum_words.join(" ");
                        accum_words.clear();
                        first_flushed = true;

                        tracing::info!("→ flush ({} words): {text}", text.split_whitespace().count());
                        let _ = translate_tx.send((text, seq)).await;
                        seq += 1;

                        if speech_final {
                            first_flushed = false;
                        }
                    }
                }
                SttEvent::UtteranceEnd => {
                    tracing::info!("── utterance end ──");
                    if !accum_words.is_empty() {
                        let text = accum_words.join(" ");
                        accum_words.clear();
                        tracing::info!("→ flush ({} words): {text}", text.split_whitespace().count());
                        let _ = translate_tx.send((text, seq)).await;
                        seq += 1;
                    }
                    first_flushed = false;
                }
            }
        }

        Ok(())
    }

    /// Translate fragments in parallel (max 3), output to TTS in sequence order.
    /// Reference: prototype/test_deepgram.py translate_worker().
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

                match translator.translate(&text).await {
                    Ok(translated) => {
                        tracing::info!("🇬🇧 {translated}");
                        let mut map = pending.lock().await;
                        map.insert(seq, translated);

                        // Flush in order
                        let mut next = next_seq.lock().await;
                        while let Some(result) = map.remove(&*next) {
                            let _ = tx.send(result).await;
                            *next += 1;
                        }
                    }
                    Err(e) => {
                        tracing::error!("Translate error: {e}");
                        // Skip this seq to avoid blocking
                        let mut next = next_seq.lock().await;
                        if *next == seq {
                            *next += 1;
                        }
                    }
                }
            });
        }
    }
}
