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

#[derive(Clone)]
pub struct SttConfig {
    pub backend: String,
    pub api_key: Option<String>,
    pub language: String,
    pub endpointing_ms: u32,
    pub utterance_end_ms: u32,
    pub parakeet_model: Option<String>,
    pub vad_model: Option<String>,
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
    pub output_device: Option<String>,
    pub language: String,
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
        // Resolve voice path relative to project root (not cwd)
        let voice_raw = env_single("POCKET_VOICE", "alba");
        let voice = if voice_raw.contains('/') || voice_raw.contains('.') {
            let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
            let resolved = project_root.join(&voice_raw);
            if resolved.exists() {
                resolved.to_string_lossy().to_string()
            } else {
                voice_raw
            }
        } else {
            voice_raw // Built-in voice name like "alba"
        };

        Ok(Self {
            stt: SttConfig {
                backend: env_single("STT_BACKEND", "deepgram"),
                api_key: env_optional_single("DEEPGRAM_API_KEY"),
                language: env_or("STT_LANGUAGE", "DICTATE_LANGUAGE", "ro"),
                endpointing_ms: env_parse("DEEPGRAM_ENDPOINTING", 500),
                utterance_end_ms: env_parse("DEEPGRAM_UTTERANCE_END", 1500),
                parakeet_model: env_optional_single("PARAKEET_MODEL"),
                vad_model: env_optional_single("VAD_MODEL"),
            },
            translate: TranslateConfig {
                api_key: env_required("GROQ_API_KEY")?,
                model: env_single("TRANSLATE_MODEL", "llama-3.3-70b-versatile"),
                from_lang: env_single("TRANSLATE_FROM", "Romanian"),
                to_lang: env_single("TRANSLATE_TO", "English"),
            },
            tts: TtsConfig {
                voice,
                speed: env_parse("POCKET_SPEED", 1.0),
                output_device: env_optional_single("AUDIO_OUTPUT"),
                language: env_single("TRANSLATE_TO", "English"),
            },
            audio: AudioConfig {
                source: env_optional_single("AUDIO_SOURCE"),
                virtual_speaker: env_single("VIRTUAL_SPEAKER_NAME", "live_interp_out"),
                virtual_mic: env_single("VIRTUAL_MIC_NAME", "live_interp_in"),
            },
            accumulator: AccumulatorConfig {
                first_words: env_parse("ACCUM_FIRST_WORDS", 3),
                min_words: env_parse("ACCUM_MIN_WORDS", 5),
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

/// Single key, None if empty/missing/whitespace-only.
fn env_optional_single(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}
