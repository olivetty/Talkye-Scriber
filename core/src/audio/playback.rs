//! Audio playback via cpal — streaming.
//!
//! Supports streaming playback: start a stream, push chunks as they arrive,
//! finish when done. This eliminates the need to buffer all TTS audio.
//! Reference: prototype/test_deepgram.py speak_pocket() → paplay streaming.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

/// Plays PCM audio on the default output device with streaming support.
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

    /// Start a streaming playback session at the given sample rate.
    /// Push chunks with `push()`, then call `finish()` to drain and stop.
    pub fn stream(&self, sample_rate: u32) -> Result<PlaybackStream> {
        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let buffer = Arc::new(Mutex::new(VecDeque::<f32>::with_capacity(48000)));
        let done = Arc::new(AtomicBool::new(false));
        let drained = Arc::new(AtomicBool::new(false));

        let buf_read = buffer.clone();
        let done_read = done.clone();
        let drained_flag = drained.clone();

        let stream = self.device.build_output_stream(
            &config,
            move |output: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let mut buf = buf_read.lock().unwrap();
                for sample in output.iter_mut() {
                    if let Some(s) = buf.pop_front() {
                        *sample = s;
                    } else {
                        *sample = 0.0;
                        // If producer is done and buffer empty, signal drained
                        if done_read.load(Ordering::Relaxed) {
                            drained_flag.store(true, Ordering::Relaxed);
                        }
                    }
                }
            },
            |err| tracing::error!("Playback error: {err}"),
            None,
        ).context("Failed to build output stream")?;

        stream.play().context("Failed to start playback")?;

        Ok(PlaybackStream {
            _stream: stream,
            buffer,
            done,
            drained,
        })
    }
}

/// A live streaming playback session. Push audio chunks, then finish.
pub struct PlaybackStream {
    _stream: cpal::Stream,
    buffer: Arc<Mutex<VecDeque<f32>>>,
    done: Arc<AtomicBool>,
    drained: Arc<AtomicBool>,
}

impl PlaybackStream {
    /// Push a chunk of f32 PCM samples into the playback buffer.
    pub fn push(&self, samples: &[f32]) {
        let mut buf = self.buffer.lock().unwrap();
        buf.extend(samples);
    }

    /// Signal no more data, wait for buffer to drain, then stop.
    pub fn finish(self) {
        self.done.store(true, Ordering::Relaxed);
        while !self.drained.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // Small tail to let the last hardware buffer drain
        std::thread::sleep(std::time::Duration::from_millis(30));
    }
}
