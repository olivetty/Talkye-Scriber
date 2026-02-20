//! Audio playback via cpal — streaming with pre-buffering.
//!
//! Pre-buffers ~150ms of audio before starting drain to prevent underruns.
//! Without pre-buffering, cpal callback writes silence (0.0) between TTS
//! chunks, causing audible clicks/choppiness.
//!
//! Virtual sink routing: when `output_sink` is set, uses `pactl move-sink-input`
//! to route audio to that PipeWire/PulseAudio sink.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

/// Pre-buffer duration before starting playback drain (seconds).
/// Gives TTS headroom to stay ahead of the cpal callback.
const PRE_BUFFER_SECS: f32 = 0.15;

/// Plays PCM audio on the default output device with streaming support.
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
        tracing::info!("Audio playback device: {name}");
        if let Some(sink) = output_sink {
            tracing::info!("Audio will be routed to PA sink: {sink}");
        }

        Ok(Self {
            device,
            output_sink: output_sink.map(|s| s.to_string()),
            routed: false,
        })
    }

    pub fn stream(&mut self, sample_rate: u32) -> Result<PlaybackStream> {
        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let pre_buffer_samples = (sample_rate as f32 * PRE_BUFFER_SECS) as usize;
        let buffer = Arc::new(Mutex::new(VecDeque::<f32>::with_capacity(sample_rate as usize)));
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
                    // Pre-buffering — output silence until enough data accumulated
                    for s in output.iter_mut() { *s = 0.0; }
                    return;
                }

                let mut buf = buf_cb.lock().unwrap();
                for sample in output.iter_mut() {
                    if let Some(s) = buf.pop_front() {
                        *sample = s;
                    } else {
                        *sample = 0.0;
                        if done_cb.load(Ordering::Relaxed) {
                            drained_cb.store(true, Ordering::Relaxed);
                        }
                    }
                }
            },
            |err| tracing::error!("Playback error: {err}"),
            None,
        ).context("Failed to build output stream")?;

        stream.play().context("Failed to start playback")?;

        // Route to virtual sink once — PipeWire remembers for subsequent streams
        if !self.routed {
            if let Some(ref sink) = self.output_sink {
                route_to_sink(sink);
                self.routed = true;
            }
        }

        Ok(PlaybackStream {
            _stream: stream,
            buffer,
            ready,
            done,
            drained,
            pre_buffer_samples,
        })
    }
}

/// Route the most recent sink-input to the named PA/PipeWire sink.
fn route_to_sink(sink_name: &str) {
    std::thread::sleep(std::time::Duration::from_millis(30));

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
                    tracing::info!("[PLAYBACK] ✅ routed sink-input {id} → {sink_name}");
                }
                Ok(o) => {
                    let err = String::from_utf8_lossy(&o.stderr);
                    tracing::warn!("[PLAYBACK] move-sink-input failed: {err}");
                }
                Err(e) => tracing::warn!("[PLAYBACK] pactl move failed: {e}"),
            }
        }
    }
}

/// A live streaming playback session with pre-buffering.
pub struct PlaybackStream {
    _stream: cpal::Stream,
    buffer: Arc<Mutex<VecDeque<f32>>>,
    ready: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
    drained: Arc<AtomicBool>,
    pre_buffer_samples: usize,
}

impl PlaybackStream {
    /// Push PCM f32 samples. Triggers playback once pre-buffer threshold is met.
    pub fn push(&self, samples: &[f32]) {
        let mut buf = self.buffer.lock().unwrap();
        buf.extend(samples);

        // Start draining once we have enough buffered
        if !self.ready.load(Ordering::Relaxed) && buf.len() >= self.pre_buffer_samples {
            self.ready.store(true, Ordering::Release);
            tracing::debug!("[PLAYBACK] pre-buffer filled ({}), starting drain", buf.len());
        }
    }

    /// Signal no more data, wait for buffer to drain, then stop.
    pub fn finish(self) {
        // If we never hit pre-buffer threshold, start draining what we have
        self.ready.store(true, Ordering::Release);
        self.done.store(true, Ordering::Relaxed);

        while !self.drained.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
    }
}
