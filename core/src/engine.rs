//! High-level Engine API — the public interface for Flutter (and CLI).
//!
//! Wraps Pipeline with start/stop control, event streaming, device enumeration,
//! and model management. All state lives here; Pipeline is stateless.

use anyhow::Result;
use cpal::traits::{DeviceTrait, HostTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;

use crate::config::Config;

// ── Public types ──

/// Events emitted by the engine to the UI layer.
#[derive(Debug, Clone)]
pub enum EngineEvent {
    /// Pipeline status changed.
    StatusChanged { status: EngineStatus },
    /// A transcript pair (original + translated).
    Transcript { original: String, translated: String },
    /// Non-fatal error.
    Error { message: String },
    /// Debug log for UI dev panel.
    Log { level: String, message: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineStatus {
    Idle,
    Loading,
    Listening,
    Translating,
    Speaking,
    Stopped,
}

/// Audio device info for UI dropdowns.
#[derive(Debug, Clone)]
pub struct AudioDevice {
    pub name: String,
    pub is_default: bool,
    pub is_input: bool,
}

/// Model readiness check.
#[derive(Debug, Clone)]
pub struct ModelStatus {
    pub stt_ready: bool,
    pub stt_path: String,
    pub vad_ready: bool,
    pub vad_path: String,
    pub voice_ready: bool,
    pub voice_path: String,
}

// ── Engine ──

/// The main engine — owns pipeline lifecycle and emits events.
pub struct Engine {
    running: Arc<AtomicBool>,
    event_tx: Option<mpsc::Sender<EngineEvent>>,
}

impl Engine {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            event_tx: None,
        }
    }

    /// Is the pipeline currently running?
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }

    /// Start the translation pipeline. Events stream to `event_tx`.
    /// Returns immediately — pipeline runs in background tasks.
    pub async fn start(
        &mut self,
        config: Config,
        event_tx: mpsc::Sender<EngineEvent>,
    ) -> Result<()> {
        if self.is_running() {
            anyhow::bail!("Engine already running");
        }

        self.running.store(true, Ordering::SeqCst);
        self.event_tx = Some(event_tx.clone());

        let _ = event_tx.send(EngineEvent::StatusChanged {
            status: EngineStatus::Loading,
        }).await;

        let running = self.running.clone();
        let pipeline = crate::pipeline::Pipeline::new(config, event_tx.clone(), running.clone());

        tokio::spawn(async move {
            let _ = event_tx.send(EngineEvent::StatusChanged {
                status: EngineStatus::Listening,
            }).await;

            if let Err(e) = pipeline.run().await {
                let _ = event_tx.send(EngineEvent::Error {
                    message: format!("{e:#}"),
                }).await;
            }

            running.store(false, Ordering::SeqCst);
            let _ = event_tx.send(EngineEvent::StatusChanged {
                status: EngineStatus::Stopped,
            }).await;
        });

        Ok(())
    }

    /// Stop the pipeline gracefully.
    pub fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        self.event_tx = None;
    }

    // ── Static helpers (no engine instance needed) ──

    /// List audio input devices.
    pub fn list_input_devices() -> Vec<AudioDevice> {
        let host = cpal::default_host();
        let default_name = host.default_input_device()
            .and_then(|d| d.name().ok())
            .unwrap_or_default();

        host.input_devices()
            .map(|devices| {
                devices.filter_map(|d| {
                    let name = d.name().ok()?;
                    Some(AudioDevice {
                        is_default: name == default_name,
                        name,
                        is_input: true,
                    })
                }).collect()
            })
            .unwrap_or_default()
    }

    /// List audio output devices.
    pub fn list_output_devices() -> Vec<AudioDevice> {
        let host = cpal::default_host();
        let default_name = host.default_output_device()
            .and_then(|d| d.name().ok())
            .unwrap_or_default();

        host.output_devices()
            .map(|devices| {
                devices.filter_map(|d| {
                    let name = d.name().ok()?;
                    Some(AudioDevice {
                        is_default: name == default_name,
                        name,
                        is_input: false,
                    })
                }).collect()
            })
            .unwrap_or_default()
    }

    /// Check if required models exist on disk.
    pub fn check_models(
        stt_model_dir: &str,
        vad_model_path: &str,
        voice_path: &str,
    ) -> ModelStatus {
        let stt_encoder = std::path::Path::new(stt_model_dir).join("encoder-model.onnx");
        let vad = std::path::Path::new(vad_model_path);
        let voice = std::path::Path::new(voice_path);

        ModelStatus {
            stt_ready: stt_encoder.exists(),
            stt_path: stt_model_dir.to_string(),
            vad_ready: vad.exists(),
            vad_path: vad_model_path.to_string(),
            voice_ready: voice.exists(),
            voice_path: voice_path.to_string(),
        }
    }
}
