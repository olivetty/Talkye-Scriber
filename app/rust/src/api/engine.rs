//! Engine FFI API — Flutter ↔ Rust bridge for pipeline control.
//!
//! Thin wrapper over talkye_core::Engine. All heavy logic lives in core.

use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;
use std::sync::{Mutex, OnceLock};
use talkye_core::engine;

// ── Global engine state ──

static ENGINE: OnceLock<Mutex<engine::Engine>> = OnceLock::new();

fn get_engine() -> &'static Mutex<engine::Engine> {
    ENGINE.get_or_init(|| Mutex::new(engine::Engine::new()))
}

// ── FRB-compatible types (mirrored from core, needed for codegen) ──

/// Engine event sent from Rust to Flutter via stream.
#[derive(Clone)]
pub enum FfiEngineEvent {
    StatusChanged { status: String },
    Transcript { original: String, translated: String },
    Error { message: String },
}

/// Audio device info.
pub struct FfiAudioDevice {
    pub name: String,
    pub is_default: bool,
    pub is_input: bool,
}

/// Model readiness status.
pub struct FfiModelStatus {
    pub stt_ready: bool,
    pub stt_path: String,
    pub vad_ready: bool,
    pub vad_path: String,
    pub voice_ready: bool,
    pub voice_path: String,
}

// ── Engine config from Flutter ──

pub struct FfiEngineConfig {
    pub stt_backend: String,
    pub stt_language: String,
    pub translate_from: String,
    pub translate_to: String,
    pub voice_path: String,
    pub tts_speed: f32,
    pub groq_api_key: String,
    pub deepgram_api_key: String,
    pub hf_token: String,
    pub parakeet_model_dir: String,
    pub vad_model_path: String,
    pub audio_output: String,
}

// ── FFI functions ──

/// Resolve a relative path against the project root (2 levels up from app/rust/).
fn resolve_path(path: &str) -> String {
    if path.is_empty() { return String::new(); }
    let p = std::path::Path::new(path);
    if p.is_absolute() { return path.to_string(); }
    // Project root = app/rust/../../ = project root
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()   // app/
        .parent().unwrap();  // project root
    let resolved = root.join(path);
    resolved.to_string_lossy().to_string()
}

/// If Flutter sends empty string, fall back to env var (loaded from .env).
fn env_fallback(flutter_val: &str, env_key: &str) -> String {
    if flutter_val.is_empty() {
        std::env::var(env_key).unwrap_or_default()
    } else {
        flutter_val.to_string()
    }
}

/// Start the translation engine. Events stream to `sink`.
pub fn start_engine(config: FfiEngineConfig, sink: StreamSink<FfiEngineEvent>) {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async {
            // Load .env as fallback for empty config values (dev mode)
            let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent().unwrap().parent().unwrap();
            dotenvy::from_path(project_root.join(".env")).ok();

            // Resolve keys: Flutter value → .env fallback
            let groq_key = env_fallback(&config.groq_api_key, "GROQ_API_KEY");
            let deepgram_key = env_fallback(&config.deepgram_api_key, "DEEPGRAM_API_KEY");
            let hf_token = env_fallback(&config.hf_token, "HF_TOKEN");
            let voice = env_fallback(&config.voice_path, "POCKET_VOICE");
            let parakeet_dir = env_fallback(&config.parakeet_model_dir, "PARAKEET_MODEL");
            let vad_path = env_fallback(&config.vad_model_path, "VAD_MODEL");
            let audio_output = env_fallback(&config.audio_output, "AUDIO_OUTPUT");

            let core_config = talkye_core::Config {
                stt: talkye_core::config::SttConfig {
                    backend: if config.stt_backend.is_empty() {
                        env_fallback("", "STT_BACKEND")
                    } else {
                        config.stt_backend
                    },
                    api_key: if deepgram_key.is_empty() { None } else { Some(deepgram_key) },
                    language: if config.stt_language.is_empty() {
                        env_fallback("", "STT_LANGUAGE")
                    } else {
                        config.stt_language
                    },
                    endpointing_ms: 500,
                    utterance_end_ms: 1500,
                    parakeet_model: if parakeet_dir.is_empty() {
                        None
                    } else {
                        Some(resolve_path(&parakeet_dir))
                    },
                    vad_model: if vad_path.is_empty() {
                        None
                    } else {
                        Some(resolve_path(&vad_path))
                    },
                },
                translate: talkye_core::config::TranslateConfig {
                    api_key: groq_key,
                    model: "llama-3.3-70b-versatile".to_string(),
                    from_lang: if config.translate_from.is_empty() {
                        env_fallback("", "TRANSLATE_FROM")
                    } else {
                        config.translate_from
                    },
                    to_lang: if config.translate_to.is_empty() {
                        env_fallback("", "TRANSLATE_TO")
                    } else {
                        config.translate_to
                    },
                },
                tts: talkye_core::config::TtsConfig {
                    voice: resolve_path(&voice),
                    speed: if config.tts_speed == 0.0 { 1.0 } else { config.tts_speed },
                    output_device: if audio_output.is_empty() {
                        None
                    } else {
                        Some(audio_output)
                    },
                },
                audio: talkye_core::config::AudioConfig {
                    source: None,
                    virtual_speaker: "talkye_out".to_string(),
                    virtual_mic: "talkye_mic".to_string(),
                },
                accumulator: talkye_core::config::AccumulatorConfig {
                    first_words: 3,
                    min_words: 5,
                },
            };

            // Set HF_TOKEN for pocket-tts model download
            if !hf_token.is_empty() {
                std::env::set_var("HF_TOKEN", &hf_token);
            }

            let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(64);

            // Forward core events → FRB StreamSink
            let sink_clone = sink.clone();
            tokio::spawn(async move {
                while let Some(event) = event_rx.recv().await {
                    let ffi_event = match event {
                        engine::EngineEvent::StatusChanged { status } => {
                            FfiEngineEvent::StatusChanged {
                                status: format!("{status:?}"),
                            }
                        }
                        engine::EngineEvent::Transcript { original, translated } => {
                            FfiEngineEvent::Transcript { original, translated }
                        }
                        engine::EngineEvent::Error { message } => {
                            FfiEngineEvent::Error { message }
                        }
                    };
                    if sink_clone.add(ffi_event).is_err() {
                        break;
                    }
                }
            });

            let mut eng = get_engine().lock().unwrap();
            if let Err(e) = eng.start(core_config, event_tx).await {
                let _ = sink.add(FfiEngineEvent::Error {
                    message: format!("{e:#}"),
                });
            }
        });
    });
}

/// Stop the translation engine.
#[frb(sync)]
pub fn stop_engine() {
    if let Ok(mut eng) = get_engine().lock() {
        eng.stop();
    }
}

/// Check if engine is currently running.
#[frb(sync)]
pub fn is_engine_running() -> bool {
    get_engine().lock().map(|e| e.is_running()).unwrap_or(false)
}

/// List audio input devices.
#[frb(sync)]
pub fn list_input_devices() -> Vec<FfiAudioDevice> {
    engine::Engine::list_input_devices()
        .into_iter()
        .map(|d| FfiAudioDevice {
            name: d.name,
            is_default: d.is_default,
            is_input: d.is_input,
        })
        .collect()
}

/// List audio output devices.
#[frb(sync)]
pub fn list_output_devices() -> Vec<FfiAudioDevice> {
    engine::Engine::list_output_devices()
        .into_iter()
        .map(|d| FfiAudioDevice {
            name: d.name,
            is_default: d.is_default,
            is_input: d.is_input,
        })
        .collect()
}

/// Check model readiness.
#[frb(sync)]
pub fn check_models(
    stt_model_dir: String,
    vad_model_path: String,
    voice_path: String,
) -> FfiModelStatus {
    let status = engine::Engine::check_models(&stt_model_dir, &vad_model_path, &voice_path);
    FfiModelStatus {
        stt_ready: status.stt_ready,
        stt_path: status.stt_path,
        vad_ready: status.vad_ready,
        vad_path: status.vad_path,
        voice_ready: status.voice_ready,
        voice_path: status.voice_path,
    }
}
