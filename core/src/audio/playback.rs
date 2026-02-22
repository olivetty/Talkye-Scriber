//! Audio playback via cpal — stream-per-utterance design.
//!
//! A single cpal stream is reused across multiple TTS messages within the same
//! utterance. The stream is only destroyed after an idle timeout (no new audio
//! for 2s). This eliminates inter-message gaps entirely.
//!
//! Virtual sink routing: done once per session, cached to avoid redundant pactl calls.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

/// Pre-buffer duration before starting playback drain (seconds).
/// Only applies when creating a NEW session.
const PRE_BUFFER_SECS: f32 = 0.12;

/// Gap between stream drop and next stream creation (ms).
const INTER_STREAM_GAP_MS: u64 = 5;

pub struct AudioPlayback {
    device: cpal::Device,
    output_sink: Option<String>,
    routed: bool,
}

impl AudioPlayback {
    pub fn new(output_sink: Option<&str>) -> Result<Self> {
        let host = cpal::default_host();
        let device = host.default_output_device()
            .context("No default output device")?;

        let name = device.name().unwrap_or_else(|_| "unknown".into());
        tracing::info!("[PLAYBACK] device: {name}");

        let validated_sink = match output_sink {
            Some(sink) if sink_exists(sink) => {
                tracing::info!("[PLAYBACK] will route to PA sink: {sink}");
                Some(sink.to_string())
            }
            Some(sink) => {
                tracing::warn!("[PLAYBACK] sink '{sink}' not found — using default");
                None
            }
            None => {
                tracing::info!("[PLAYBACK] no virtual sink — direct to default device");
                None
            }
        };

        Ok(Self { device, output_sink: validated_sink, routed: false })
    }

    /// Create a new playback session (one cpal stream).
    /// Reuse this session across multiple TTS messages for gapless playback.
    pub fn stream(&mut self, sample_rate: u32) -> Result<PlaybackSession> {
        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let pre_buffer_samples = (sample_rate as f32 * PRE_BUFFER_SECS) as usize;
        let buffer = Arc::new(Mutex::new(VecDeque::<f32>::with_capacity(
            sample_rate as usize * 2,
        )));
        let ready = Arc::new(AtomicBool::new(false));
        let done = Arc::new(AtomicBool::new(false));
        let drained = Arc::new(AtomicBool::new(false));

        let buf_cb = buffer.clone();
        let ready_cb = ready.clone();
        let done_cb = done.clone();
        let drained_cb = drained.clone();

        let stream = self.device.build_output_stream(
            &config,
            move |output: &mut [f32], _: &cpal::OutputCallbackInfo| {
                if !ready_cb.load(Ordering::Acquire) {
                    output.fill(0.0);
                    return;
                }
                let Ok(mut buf) = buf_cb.lock() else {
                    output.fill(0.0);
                    return;
                };
                for sample in output.iter_mut() {
                    if let Some(s) = buf.pop_front() {
                        *sample = s;
                    } else {
                        *sample = 0.0;
                        if done_cb.load(Ordering::Relaxed) {
                            drained_cb.store(true, Ordering::Release);
                        }
                    }
                }
            },
            |err| tracing::error!("[PLAYBACK] stream error: {err}"),
            None,
        ).context("Failed to build output stream")?;

        stream.play().context("Failed to start playback")?;

        // Route to virtual sink if configured
        if let Some(ref sink) = self.output_sink {
            route_to_sink(sink);
            self.routed = true;
        }

        Ok(PlaybackSession {
            stream: Some(stream),
            buffer,
            ready,
            done,
            drained,
            pre_buffer_samples,
            sample_rate,
        })
    }
}

/// A playback session tied to one cpal stream.
/// Can be reused across multiple TTS messages for gapless playback.
/// When dropped, the cpal stream is destroyed — clean hardware flush.
pub struct PlaybackSession {
    stream: Option<cpal::Stream>,
    buffer: Arc<Mutex<VecDeque<f32>>>,
    ready: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
    drained: Arc<AtomicBool>,
    pre_buffer_samples: usize,
    sample_rate: u32,
}

impl PlaybackSession {
    /// Push PCM f32 samples. Starts drain once pre-buffer threshold is met.
    pub fn push(&self, samples: &[f32]) {
        // Reset done/drained flags if we're pushing new data
        // (session reuse across multiple TTS messages)
        if self.done.load(Ordering::Relaxed) {
            self.done.store(false, Ordering::Release);
            self.drained.store(false, Ordering::Release);
        }

        let Ok(mut buf) = self.buffer.lock() else { return };
        buf.extend(samples);
        if !self.ready.load(Ordering::Relaxed) && buf.len() >= self.pre_buffer_samples {
            self.ready.store(true, Ordering::Release);
        }
    }

    /// Signal no more data for THIS message. Does NOT destroy the stream.
    /// The stream keeps running (outputting silence) so the next message
    /// can push directly without creating a new stream.
    ///
    /// Call `finish()` only when the utterance is truly over.
    pub fn end_message(&self) {
        // Ensure playback starts even if pre-buffer wasn't reached
        self.ready.store(true, Ordering::Release);
    }

    /// Final shutdown: wait for drain, then destroy stream.
    /// Call this when the utterance is over (idle timeout or explicit end).
    pub fn finish(mut self) {
        self.ready.store(true, Ordering::Release);
        self.done.store(true, Ordering::Release);

        // Dynamic timeout based on actual buffer size
        let remaining = self.buffer.lock().map(|b| b.len()).unwrap_or(0);
        let drain_ms = if remaining > 0 && self.sample_rate > 0 {
            (remaining as u64 * 1000 / self.sample_rate as u64) + 300
        } else {
            200
        };
        let timeout_ms = drain_ms.min(2000);

        let t0 = std::time::Instant::now();
        while !self.drained.load(Ordering::Acquire) {
            if t0.elapsed().as_millis() as u64 > timeout_ms {
                let left = self.buffer.lock().map(|b| b.len()).unwrap_or(0);
                if left > 0 {
                    tracing::warn!(
                        "[PLAYBACK] drain timeout ({timeout_ms}ms), {left} samples left — dropping"
                    );
                }
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }

        // Drop the stream — triggers clean PipeWire/ALSA flush
        if let Some(s) = self.stream.take() {
            drop(s);
        }

        // Minimal gap for PipeWire cleanup
        std::thread::sleep(std::time::Duration::from_millis(INTER_STREAM_GAP_MS));
    }
}

impl Drop for PlaybackSession {
    fn drop(&mut self) {
        if let Some(s) = self.stream.take() {
            drop(s);
        }
    }
}

fn sink_exists(sink_name: &str) -> bool {
    std::process::Command::new("pactl")
        .args(["list", "short", "sinks"])
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .any(|l| l.contains(sink_name))
        })
        .unwrap_or(false)
}

fn route_to_sink(sink_name: &str) {
    std::thread::sleep(std::time::Duration::from_millis(50));
    let output = match std::process::Command::new("pactl")
        .args(["list", "short", "sink-inputs"])
        .output()
    {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(e) => {
            tracing::warn!("[PLAYBACK] pactl not available: {e}");
            return;
        }
    };
    if let Some(last_line) = output.lines().last() {
        if let Some(id) = last_line.split_whitespace().next() {
            match std::process::Command::new("pactl")
                .args(["move-sink-input", id, sink_name])
                .output()
            {
                Ok(o) if o.status.success() => {
                    tracing::info!("[PLAYBACK] routed sink-input {id} -> {sink_name}");
                }
                Ok(o) => {
                    let err = String::from_utf8_lossy(&o.stderr);
                    tracing::warn!("[PLAYBACK] route failed: {err}");
                }
                Err(e) => tracing::warn!("[PLAYBACK] pactl error: {e}"),
            }
        }
    }
}
