//! Microphone capture via cpal.
//!
//! Opens the system mic (or a named source), streams 16kHz mono PCM chunks.
//! Reference: prototype/test_deepgram.py find_source() + parecord setup.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use tokio::sync::mpsc;

use super::AudioChunk;
use crate::config::AudioConfig;

/// Captures audio from the microphone and sends chunks via channel.
pub struct AudioCapture {
    device: cpal::Device,
}

impl AudioCapture {
    /// Find and open the audio input device.
    pub fn new(config: &AudioConfig) -> Result<Self> {
        let host = cpal::default_host();

        let device = if let Some(ref name) = config.source {
            host.input_devices()
                .context("Failed to list input devices")?
                .find(|d| {
                    d.name()
                        .map(|n| n.to_lowercase().contains(&name.to_lowercase()))
                        .unwrap_or(false)
                })
                .context(format!("Audio source '{}' not found", name))?
        } else {
            host.default_input_device()
                .context("No default input device")?
        };

        let name = device.name().unwrap_or_else(|_| "unknown".into());
        tracing::info!("Audio capture device: {name}");

        Ok(Self { device })
    }

    /// Start capturing. Sends ~100ms chunks of 16-bit PCM at 16kHz mono.
    /// This blocks — run in a dedicated tokio::task::spawn_blocking.
    pub fn start(&self, tx: mpsc::Sender<AudioChunk>) -> Result<()> {
        let stream_config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(16000),
            buffer_size: cpal::BufferSize::Default,
        };

        let tx_clone = tx.clone();
        let stream = self.device.build_input_stream(
            &stream_config,
            move |data: &[i16], _: &cpal::InputCallbackInfo| {
                // Convert i16 samples to bytes (little-endian)
                let bytes: Vec<u8> = data
                    .iter()
                    .flat_map(|s| s.to_le_bytes())
                    .collect();
                // Non-blocking send — drop chunk if pipeline is behind
                let _ = tx_clone.try_send(bytes);
            },
            |err| tracing::error!("Audio capture error: {err}"),
            None,
        ).context("Failed to build input stream")?;

        stream.play().context("Failed to start audio capture")?;
        tracing::info!("Audio capture started (16kHz mono)");

        // Keep stream alive until channel closes
        loop {
            std::thread::sleep(std::time::Duration::from_millis(100));
            if tx.is_closed() {
                break;
            }
        }

        Ok(())
    }
}
