//! Audio capture and virtual device management.
//!
//! Responsibilities:
//! - Capture PCM from real microphone (cpal)
//! - Create/destroy PulseAudio virtual devices (Linux)
//! - Route TTS output to virtual mic sink
//! - Read incoming audio from virtual speaker monitor

use anyhow::Result;
use tokio::sync::mpsc;

/// Raw PCM audio chunk (16-bit, 16kHz, mono)
pub type AudioChunk = Vec<u8>;

/// Audio capture from the real microphone.
///
/// Sends 16-bit PCM chunks at 16kHz mono via the provided channel.
pub struct AudioCapture {
    source_name: Option<String>,
}

impl AudioCapture {
    pub fn new(source_name: Option<String>) -> Self {
        Self { source_name }
    }

    /// Start capturing audio, sending chunks to `tx`.
    /// Blocks the calling thread — run in a dedicated task.
    pub async fn start(&self, tx: mpsc::Sender<AudioChunk>) -> Result<()> {
        // TODO: Implement with cpal
        // 1. Open input device (default or source_name)
        // 2. Configure stream: 16kHz, mono, i16
        // 3. In callback: collect samples into ~100ms chunks, send via tx
        let _ = tx;
        tracing::warn!("AudioCapture::start() — not yet implemented");
        Ok(())
    }
}

/// Manages PulseAudio virtual devices on Linux.
///
/// Creates:
/// - "Interpreter Speaker" (null-sink) — call app outputs here
/// - "Interpreter Mic" (null-sink + remap-source) — TTS writes here, call app reads
pub struct VirtualDevices {
    speaker_sink: String,
    mic_sink: String,
}

impl VirtualDevices {
    pub fn new(speaker_name: &str, mic_name: &str) -> Self {
        Self {
            speaker_sink: speaker_name.to_string(),
            mic_sink: mic_name.to_string(),
        }
    }

    /// Create virtual devices via `pactl`. Idempotent.
    pub async fn create(&self) -> Result<()> {
        // TODO: pactl load-module module-null-sink for speaker + mic
        // See prototype/docs/product-live-interpreter.md for exact commands
        tracing::warn!("VirtualDevices::create() — not yet implemented");
        Ok(())
    }

    /// Remove virtual devices on shutdown.
    pub async fn destroy(&self) -> Result<()> {
        // TODO: pactl unload-module
        tracing::warn!("VirtualDevices::destroy() — not yet implemented");
        Ok(())
    }

    /// Monitor name for reading incoming audio from call app.
    pub fn speaker_monitor(&self) -> String {
        format!("{}.monitor", self.speaker_sink)
    }

    /// Sink name for writing outgoing TTS audio.
    pub fn mic_sink(&self) -> String {
        self.mic_sink.clone()
    }
}
