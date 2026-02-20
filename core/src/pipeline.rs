//! Pipeline orchestration — connects STT → Translate → TTS.
//!
//! Mirrors the Python prototype's architecture:
//! - Accumulator: collects words from STT finals, flushes at threshold
//! - Parallel translation with sequence-ordered output
//! - Sequential TTS playback (no dropping)

use anyhow::Result;
use tokio::sync::mpsc;

use crate::audio::AudioCapture;
use crate::stt::{SttClient, SttConfig, SttEvent};
use crate::translate::{TranslateConfig, Translator};
use crate::tts::TtsEngine;

pub struct Pipeline {
    stt_config: SttConfig,
    translator: Translator,
    accum_first_words: usize,
    accum_min_words: usize,
    audio_source: Option<String>,
    voice: String,
    speed: f32,
}

impl Pipeline {
    pub fn new() -> Result<Self> {
        let stt_config = SttConfig::from_env()?;
        let translate_config = TranslateConfig::from_env()?;

        let accum_first_words: usize = std::env::var("ACCUM_FIRST_WORDS")
            .unwrap_or_else(|_| "4".into())
            .parse()
            .unwrap_or(4);
        let accum_min_words: usize = std::env::var("ACCUM_MIN_WORDS")
            .unwrap_or_else(|_| "8".into())
            .parse()
            .unwrap_or(8);
        let audio_source = std::env::var("AUDIO_SOURCE")
            .or_else(|_| std::env::var("DICTATE_SOURCE_NAME"))
            .ok()
            .filter(|s| !s.is_empty());
        let voice = std::env::var("POCKET_VOICE").unwrap_or_else(|_| "alba".into());
        let speed: f32 = std::env::var("POCKET_SPEED")
            .unwrap_or_else(|_| "1.0".into())
            .parse()
            .unwrap_or(1.0);

        Ok(Self {
            stt_config,
            translator: Translator::new(translate_config),
            accum_first_words,
            accum_min_words,
            audio_source,
            voice,
            speed,
        })
    }

    pub async fn run(&self) -> Result<()> {
        tracing::info!(
            "Pipeline: STT (endpointing={}ms) → Translate → TTS (voice={}, speed={}x)",
            self.stt_config.endpointing_ms,
            self.voice,
            self.speed
        );
        tracing::info!(
            "Accumulator: first flush at {}w, then {}w",
            self.accum_first_words,
            self.accum_min_words
        );

        // Channels
        let (audio_tx, audio_rx) = mpsc::channel(64);
        let (stt_tx, mut stt_rx) = mpsc::channel(64);
        let (tts_tx, mut tts_rx) = mpsc::channel::<String>(32);

        // Audio capture
        let capture = AudioCapture::new(self.audio_source.clone());
        tokio::spawn(async move {
            if let Err(e) = capture.start(audio_tx).await {
                tracing::error!("Audio capture error: {e}");
            }
        });

        // STT
        let stt = SttClient::new(SttConfig::from_env()?);
        tokio::spawn(async move {
            if let Err(e) = stt.run(audio_rx, stt_tx).await {
                tracing::error!("STT error: {e}");
            }
        });

        // TTS playback (sequential, blocking on purpose)
        let voice = self.voice.clone();
        let speed = self.speed;
        std::thread::spawn(move || {
            let tts = match TtsEngine::new(&voice, speed) {
                Ok(t) => t,
                Err(e) => {
                    tracing::error!("Failed to init TTS: {e}");
                    return;
                }
            };

            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();

            rt.block_on(async {
                while let Some(text) = tts_rx.recv().await {
                    tracing::info!("🔊 TTS: {text}");
                    match tts.generate_stream(&text, |_chunk| {
                        // TODO: Write PCM to audio output (paplay or cpal)
                    }) {
                        Ok((fc_ms, total_ms)) => {
                            tracing::info!("  TTS done: first_chunk={fc_ms}ms total={total_ms}ms");
                        }
                        Err(e) => tracing::error!("TTS error: {e}"),
                    }
                }
            });
        });

        // Accumulator + translate loop
        let mut accum_words: Vec<String> = Vec::new();
        let mut first_flushed = false;

        while let Some(event) = stt_rx.recv().await {
            match event {
                SttEvent::Interim(text) => {
                    tracing::debug!("... {text}");
                }
                SttEvent::Final {
                    transcript,
                    words,
                    speech_final,
                } => {
                    tracing::info!("✓ {transcript}{}", if speech_final { " ◼" } else { "" });

                    let word_texts: Vec<String> = words.iter().map(|w| w.word.clone()).collect();
                    accum_words.extend(word_texts);

                    let threshold = if !first_flushed {
                        self.accum_first_words
                    } else {
                        self.accum_min_words
                    };

                    if accum_words.len() >= threshold || speech_final {
                        let text = accum_words.join(" ");
                        accum_words.clear();
                        first_flushed = true;

                        tracing::info!("→ flush: {text}");

                        // Translate and send to TTS
                        match self.translator.translate(&text).await {
                            Ok(translated) => {
                                tracing::info!("🇬🇧 {translated}");
                                let _ = tts_tx.send(translated).await;
                            }
                            Err(e) => tracing::error!("Translate error: {e}"),
                        }

                        if speech_final {
                            self.translator.clear_segment();
                            first_flushed = false;
                        }
                    }
                }
                SttEvent::UtteranceEnd => {
                    tracing::info!("── utterance end ──");
                    if !accum_words.is_empty() {
                        let text = accum_words.join(" ");
                        accum_words.clear();

                        match self.translator.translate(&text).await {
                            Ok(translated) => {
                                tracing::info!("🇬🇧 {translated}");
                                let _ = tts_tx.send(translated).await;
                            }
                            Err(e) => tracing::error!("Translate error: {e}"),
                        }
                    }
                    self.translator.clear_segment();
                    first_flushed = false;
                }
            }
        }

        Ok(())
    }
}
