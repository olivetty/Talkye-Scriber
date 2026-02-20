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

/// Start the translation engine. Events stream to `sink`.
pub fn start_engine(config: FfiEngineConfig, sink: StreamSink<FfiEngineEvent>) {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async {
            // Convert FfiEngineConfig → talkye_core::Config
            let core_config = talkye_core::Config {
                stt: talkye_core::config::SttConfig {
                    backend: config.stt_backend,
                    api_key: if config.deepgram_api_key.is_empty() {
                        None
                    } else {
                        Some(config.deepgram_api_key)
                    },
                    language: config.stt_language,
                    endpointing_ms: 500,
                    utterance_end_ms: 1500,
                    parakeet_model: if config.parakeet_model_dir.is_empty() {
                        None
                    } else {
                        Some(config.parakeet_model_dir)
                    },
                    vad_model: if config.vad_model_path.is_empty() {
                        None
                    } else {
                        Some(config.vad_model_path)
                    },
                },
                translate: talkye_core::config::TranslateConfig {
                    api_key: config.groq_api_key,
                    model: "llama-3.3-70b-versatile".to_string(),
                    from_lang: config.translate_from,
                    to_lang: config.translate_to,
                },
                tts: talkye_core::config::TtsConfig {
                    voice: config.voice_path,
                    speed: config.tts_speed,
                    output_device: if config.audio_output.is_empty() {
                        None
                    } else {
                        Some(config.audio_output)
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
            if !config.hf_token.is_empty() {
                std::env::set_var("HF_TOKEN", &config.hf_token);
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
