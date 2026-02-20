//! Audio playback via cpal.
//!
//! Receives PCM f32 chunks from TTS and plays them on the output device.
//! Reference: prototype/test_deepgram.py speak_pocket() → paplay.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};

/// Plays PCM audio on the default output device.
pub struct AudioPlayback {
    device: cpal::Device,
}

impl AudioPlayback {
    pub fn new() -> Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .context("No default output device")?;

        let name = device.name().unwrap_or_else(|_| "unknown".into());
        tracing::info!("Audio playback device: {name}");

        Ok(Self { device })
    }

    /// Play a buffer of f32 PCM samples at the given sample rate.
    /// Blocks until playback completes.
    pub fn play(&self, samples: &[f32], sample_rate: u32) -> Result<()> {
        if samples.is_empty() {
            return Ok(());
        }

        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let data = Arc::new(Mutex::new(PlaybackState {
            samples: samples.to_vec(),
            position: 0,
        }));

        let data_clone = data.clone();
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let finished_clone = finished.clone();

        let stream = self.device.build_output_stream(
            &config,
            move |output: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let mut state = data_clone.lock().unwrap();
                for sample in output.iter_mut() {
                    if state.position < state.samples.len() {
                        *sample = state.samples[state.position];
                        state.position += 1;
                    } else {
                        *sample = 0.0;
                        finished_clone.store(true, std::sync::atomic::Ordering::Relaxed);
                    }
                }
            },
            |err| tracing::error!("Playback error: {err}"),
            None,
        ).context("Failed to build output stream")?;

        stream.play().context("Failed to start playback")?;

        // Wait for playback to finish
        while !finished.load(std::sync::atomic::Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        // Small tail to let the last buffer drain
        std::thread::sleep(std::time::Duration::from_millis(50));

        Ok(())
    }
}

struct PlaybackState {
    samples: Vec<f32>,
    position: usize,
}
