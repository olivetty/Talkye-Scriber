//! Engine FFI API — Flutter ↔ Rust bridge for pipeline control.
//!
//! Runs the talkye-core pipeline directly (no Engine abstraction).
//! .env fallback for all config values (dev mode).

use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use talkye_core::engine;

// ── Global stop flag ──

static RUNNING: OnceLock<Arc<AtomicBool>> = OnceLock::new();

fn running_flag() -> Arc<AtomicBool> {
    RUNNING.get_or_init(|| Arc::new(AtomicBool::new(false))).clone()
}

// ── FRB-compatible types ──

#[derive(Clone)]
pub enum FfiEngineEvent {
    StatusChanged { status: String },
    Transcript { original: String, translated: String },
    Error { message: String },
    Log { level: String, message: String },
}

pub struct FfiAudioDevice {
    pub name: String,
    pub is_default: bool,
    pub is_input: bool,
}

pub struct FfiModelStatus {
    pub stt_ready: bool,
    pub stt_path: String,
    pub vad_ready: bool,
    pub vad_path: String,
    pub voice_ready: bool,
    pub voice_path: String,
}

pub struct FfiEngineConfig {
    pub stt_backend: String,
    pub stt_language: String,
    pub translate_from: String,
    pub translate_to: String,
    pub voice_path: String,
    pub tts_speed: f32,
    pub tts_backend: String,
    pub groq_api_key: String,
    pub deepgram_api_key: String,
    pub hf_token: String,
    pub parakeet_model_dir: String,
    pub vad_model_path: String,
    pub audio_output: String,
    // Chatterbox quality parameters
    pub cbx_exaggeration: f64,
    pub cbx_cfg_weight: f64,
    pub cbx_temperature: f64,
    pub cbx_context_window: i32,
}

// ── Helpers ──

/// Resolve relative path against project root.
fn resolve_path(path: &str) -> String {
    if path.is_empty() { return String::new(); }
    let p = std::path::Path::new(path);
    if p.is_absolute() { return path.to_string(); }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()   // app/
        .parent().unwrap();  // project root
    root.join(path).to_string_lossy().to_string()
}

/// Flutter value → .env fallback.
fn env_fb(flutter_val: &str, env_key: &str) -> String {
    if flutter_val.is_empty() {
        std::env::var(env_key).unwrap_or_default()
    } else {
        flutter_val.to_string()
    }
}

fn opt(s: String) -> Option<String> {
    if s.is_empty() { None } else { Some(s) }
}

// ── FFI functions ──

/// Start the translation engine. Events stream to `sink`.
/// Pipeline runs in a dedicated thread with its own tokio runtime.
/// Blocks until pipeline exits (via stop or error).
pub fn start_engine(config: FfiEngineConfig, sink: StreamSink<FfiEngineEvent>) {
    let flag = running_flag();

    // Prevent double-start
    if flag.load(Ordering::Relaxed) {
        let _ = sink.add(FfiEngineEvent::Error {
            message: "Engine already running".to_string(),
        });
        return;
    }

    flag.store(true, Ordering::SeqCst);

    std::thread::spawn(move || {
        // Init tracing (once, idempotent)
        use tracing_subscriber::EnvFilter;
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                EnvFilter::from_default_env()
                    .add_directive("ort=warn".parse().unwrap())
                    .add_directive("hf_hub=warn".parse().unwrap())
            )
            .try_init();

        // Load .env from project root
        let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent().unwrap().parent().unwrap();
        dotenvy::from_path(project_root.join(".env")).ok();

        tracing::info!("[FFI] Engine starting...");

        let _ = sink.add(FfiEngineEvent::StatusChanged {
            status: "Loading".to_string(),
        });

        // Build config: Flutter values → .env fallback
        let groq_key = env_fb(&config.groq_api_key, "GROQ_API_KEY");
        let deepgram_key = env_fb(&config.deepgram_api_key, "DEEPGRAM_API_KEY");
        let hf_token = env_fb(&config.hf_token, "HF_TOKEN");
        let voice = env_fb(&config.voice_path, "POCKET_VOICE");
        let tts_backend = env_fb(&config.tts_backend, "TTS_BACKEND");
        let parakeet_dir = env_fb(&config.parakeet_model_dir, "PARAKEET_MODEL");
        let vad_path = env_fb(&config.vad_model_path, "VAD_MODEL");
        let audio_output = env_fb(&config.audio_output, "AUDIO_OUTPUT");
        let stt_backend = env_fb(&config.stt_backend, "STT_BACKEND");
        let stt_lang = env_fb(&config.stt_language, "STT_LANGUAGE");
        let from_lang = env_fb(&config.translate_from, "TRANSLATE_FROM");
        let to_lang = env_fb(&config.translate_to, "TRANSLATE_TO");
        let speed = if config.tts_speed > 0.0 { config.tts_speed } else {
            std::env::var("POCKET_SPEED").ok()
                .and_then(|v| v.parse().ok()).unwrap_or(1.0)
        };

        if !hf_token.is_empty() {
            std::env::set_var("HF_TOKEN", &hf_token);
        }

        let voice_resolved = resolve_path(&voice);

        let core_config = talkye_core::Config {
            stt: talkye_core::config::SttConfig {
                backend: if stt_backend.is_empty() { "parakeet".into() } else { stt_backend },
                api_key: opt(deepgram_key),
                language: if stt_lang.is_empty() { "ro".into() } else { stt_lang },
                endpointing_ms: 500,
                utterance_end_ms: 1500,
                parakeet_model: opt(resolve_path(&parakeet_dir)),
                vad_model: opt(resolve_path(&vad_path)),
            },
            translate: talkye_core::config::TranslateConfig {
                api_key: groq_key.clone(),
                model: "llama-3.3-70b-versatile".to_string(),
                from_lang: if from_lang.is_empty() { "Romanian".into() } else { from_lang },
                to_lang: if to_lang.is_empty() { "English".into() } else { to_lang.clone() },
            },
            tts: talkye_core::config::TtsConfig {
                voice: voice_resolved,
                speed,
                output_device: opt(audio_output),
                language: if to_lang.is_empty() { "English".into() } else { to_lang },
                backend: if tts_backend.is_empty() { "pocket".into() } else { tts_backend },
                cbx_exaggeration: if config.cbx_exaggeration > 0.0 { config.cbx_exaggeration } else { 0.5 },
                cbx_cfg_weight: if config.cbx_cfg_weight >= 0.0 { config.cbx_cfg_weight } else { 0.5 },
                cbx_temperature: if config.cbx_temperature > 0.0 { config.cbx_temperature } else { 0.8 },
                cbx_context_window: if config.cbx_context_window > 0 { config.cbx_context_window } else { 50 },
            },
            audio: talkye_core::config::AudioConfig {
                source: None,
                virtual_speaker: "talkye_out".to_string(),
                virtual_mic: "talkye_mic".to_string(),
            },
            accumulator: talkye_core::config::AccumulatorConfig {
                first_words: std::env::var("ACCUM_FIRST_WORDS").ok()
                    .and_then(|v| v.parse().ok()).unwrap_or(3),
                min_words: std::env::var("ACCUM_MIN_WORDS").ok()
                    .and_then(|v| v.parse().ok()).unwrap_or(5),
            },
        };

        if groq_key.is_empty() {
            tracing::error!("[FFI] GROQ_API_KEY is empty — translation will fail");
            let _ = sink.add(FfiEngineEvent::Error {
                message: "GROQ_API_KEY not set in .env".to_string(),
            });
        }

        // Create event channel
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(64);

        // Build runtime — stays alive for entire pipeline lifetime
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();

        let flag_clone = running_flag();

        rt.block_on(async {
            // Forward core events → FRB StreamSink (background task)
            let sink_fwd = sink.clone();
            tokio::spawn(async move {
                while let Some(event) = event_rx.recv().await {
                    let ffi = match event {
                        talkye_core::EngineEvent::StatusChanged { status } => {
                            FfiEngineEvent::StatusChanged {
                                status: format!("{status:?}"),
                            }
                        }
                        talkye_core::EngineEvent::Transcript { original, translated } => {
                            FfiEngineEvent::Transcript { original, translated }
                        }
                        talkye_core::EngineEvent::Error { message } => {
                            FfiEngineEvent::Error { message }
                        }
                        talkye_core::EngineEvent::Log { level, message } => {
                            FfiEngineEvent::Log { level, message }
                        }
                    };
                    if sink_fwd.add(ffi).is_err() { break; }
                }
            });

            let _ = sink.add(FfiEngineEvent::StatusChanged {
                status: "Listening".to_string(),
            });

            // Run pipeline DIRECTLY — blocks until it exits
            let pipeline = talkye_core::Pipeline::new(
                core_config, event_tx, flag_clone.clone(),
            );

            tracing::info!("[FFI] Pipeline starting...");
            if let Err(e) = pipeline.run().await {
                tracing::error!("[FFI] Pipeline error: {e:#}");
                let _ = sink.add(FfiEngineEvent::Error {
                    message: format!("{e:#}"),
                });
            }

            tracing::info!("[FFI] Pipeline stopped");
            flag_clone.store(false, Ordering::SeqCst);
            let _ = sink.add(FfiEngineEvent::StatusChanged {
                status: "Stopped".to_string(),
            });
        });
        // Runtime drops here — all tasks cleaned up
    });
}

/// Stop the translation engine.
#[frb(sync)]
pub fn stop_engine() {
    let flag = running_flag();
    if flag.load(Ordering::Relaxed) {
        tracing::info!("[FFI] Stop requested");
        flag.store(false, Ordering::SeqCst);
    }
}

/// Check if engine is currently running.
#[frb(sync)]
pub fn is_engine_running() -> bool {
    running_flag().load(Ordering::Relaxed)
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
    let s = engine::Engine::check_models(&stt_model_dir, &vad_model_path, &voice_path);
    FfiModelStatus {
        stt_ready: s.stt_ready, stt_path: s.stt_path,
        vad_ready: s.vad_ready, vad_path: s.vad_path,
        voice_ready: s.voice_ready, voice_path: s.voice_path,
    }
}

// ── Voice management FFI ──

pub struct FfiVoiceInfo {
    pub name: String,
    pub path: String,
    pub is_precomputed: bool,
    pub size_bytes: u64,
}

/// List available voices in the voices/ directory.
#[frb(sync)]
pub fn list_voices() -> Vec<FfiVoiceInfo> {
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap().parent().unwrap();
    let voices_dir = project_root.join("voices");
    talkye_core::voice::list_voices(&voices_dir.to_string_lossy())
        .into_iter()
        .map(|v| FfiVoiceInfo {
            name: v.name, path: v.path,
            is_precomputed: v.is_precomputed, size_bytes: v.size_bytes,
        })
        .collect()
}

/// Record voice from mic for given duration. Blocking — runs in isolate.
pub fn record_voice(name: String, duration_secs: f32) -> String {
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap().parent().unwrap();
    let out_path = project_root.join("voices").join(format!("{name}.wav"));
    // Ensure voices dir exists
    std::fs::create_dir_all(project_root.join("voices")).ok();
    talkye_core::voice::record_voice(&out_path.to_string_lossy(), duration_secs)
        .unwrap_or_else(|e| format!("ERROR: {e:#}"))
}

/// Precompute voice (.wav → .safetensors). Blocking — runs in isolate.
pub fn precompute_voice(wav_path: String) -> String {
    match talkye_core::voice::precompute_voice(&wav_path) {
        Ok(path) => path,
        Err(e) => format!("ERROR: {e:#}"),
    }
}

pub fn prepare_cbx_voice(wav_path: String) -> String {
    match talkye_core::voice::prepare_cbx_voice(&wav_path) {
        Ok(path) => path,
        Err(e) => format!("ERROR: {e:#}"),
    }
}


/// Preview a voice — generates TTS, saves preview WAV, plays it. Returns preview path.
pub fn preview_voice(voice_path: String) -> String {
    match talkye_core::voice::preview_voice(&voice_path) {
        Ok(path) => path,
        Err(e) => {
            tracing::error!("[FFI] Preview failed: {e:#}");
            format!("ERROR: {e:#}")
        }
    }
}

/// Play a cached preview WAV (instant, no TTS). Blocking.
pub fn play_preview(preview_wav_path: String) -> bool {
    talkye_core::voice::play_preview(&preview_wav_path).is_ok()
}

/// Delete a voice and its files.
pub fn delete_voice(voice_path: String) -> bool {
    talkye_core::voice::delete_voice(&voice_path).is_ok()
}

/// Get the project voices directory path.
#[frb(sync)]
pub fn voices_dir() -> String {
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap().parent().unwrap();
    project_root.join("voices").to_string_lossy().to_string()
}
