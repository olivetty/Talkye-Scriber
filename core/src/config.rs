//! Centralized configuration — single source of truth.
//!
//! All .env reads happen here. Other modules receive config via constructor.

use anyhow::{Context, Result};

/// Top-level config for the entire engine.
pub struct Config {
    pub stt: SttConfig,
    pub translate: TranslateConfig,
    pub tts: TtsConfig,
    pub audio: AudioConfig,
    pub accumulator: AccumulatorConfig,
}

pub struct SttConfig {
    pub api_key: String,
    pub language: String,
    pub endpointing_ms: u32,
    pub utterance_end_ms: u32,
}

pub struct TranslateConfig {
    pub api_key: String,
    pub model: String,
    pub from_lang: String,
    pub to_lang: String,
}

pub struct TtsConfig {
    pub voice: String,
    pub speed: f32,
}

pub struct AudioConfig {
    pub source: Option<String>,
    pub virtual_speaker: String,
    pub virtual_mic: String,
}

pub struct AccumulatorConfig {
    pub first_words: usize,
    pub min_words: usize,
}

impl Config {
    /// Load all config from environment variables (.env).
    pub fn from_env() -> Result<Self> {
        Ok(Self {
            stt: SttConfig {
                api_key: env_required("DEEPGRAM_API_KEY")?,
                language: env_or("STT_LANGUAGE", "DICTATE_LANGUAGE", "ro"),
                endpointing_ms: env_parse("DEEPGRAM_ENDPOINTING", 500),
                utterance_end_ms: env_parse("DEEPGRAM_UTTERANCE_END", 1500),
            },
            translate: TranslateConfig {
                api_key: env_required("GROQ_API_KEY")?,
                model: env_single("TRANSLATE_MODEL", "llama-3.3-70b-versatile"),
                from_lang: env_single("TRANSLATE_FROM", "Romanian"),
                to_lang: env_single("TRANSLATE_TO", "English"),
            },
            tts: TtsConfig {
                voice: env_single("POCKET_VOICE", "alba"),
                speed: env_parse("POCKET_SPEED", 1.0),
            },
            audio: AudioConfig {
                source: env_optional("AUDIO_SOURCE", "DICTATE_SOURCE_NAME"),
                virtual_speaker: env_single("VIRTUAL_SPEAKER_NAME", "live_interp_out"),
                virtual_mic: env_single("VIRTUAL_MIC_NAME", "live_interp_in"),
            },
            accumulator: AccumulatorConfig {
                first_words: env_parse("ACCUM_FIRST_WORDS", 4),
                min_words: env_parse("ACCUM_MIN_WORDS", 8),
            },
        })
    }
}

// ── Env helpers ──

fn env_required(key: &str) -> Result<String> {
    std::env::var(key).context(format!("{key} not set in .env"))
}

fn env_single(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.into())
}

/// Try primary key, then fallback key, then default.
fn env_or(primary: &str, fallback: &str, default: &str) -> String {
    std::env::var(primary)
        .or_else(|_| std::env::var(fallback))
        .unwrap_or_else(|_| default.into())
}

/// Try primary key, then fallback. None if both empty/missing.
fn env_optional(primary: &str, fallback: &str) -> Option<String> {
    std::env::var(primary)
        .or_else(|_| std::env::var(fallback))
        .ok()
        .filter(|s| !s.is_empty())
}

fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}
