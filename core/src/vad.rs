//! Silero VAD — neural voice activity detection via ONNX Runtime.
//!
//! Replaces crude RMS energy-based VAD with Silero V5 neural model.
//! Returns speech probability (0.0–1.0) per 32ms chunk (512 samples @ 16kHz).
//! Model: ~2.3MB ONNX, inference ~1ms per chunk on CPU.

use anyhow::{Context, Result};
use ndarray::{Array2, Array3};
use ort::session::Session;
use std::path::Path;

/// 512 samples = 32ms at 16kHz (Silero V5 fixed window).
pub const VAD_CHUNK_SAMPLES: usize = 512;

/// Silero VAD V5 model wrapper with internal state.
pub struct SileroVad {
    session: Session,
    /// Hidden state: shape [2, 1, 128]
    state: Array3<f32>,
}

impl SileroVad {
    /// Load Silero VAD ONNX model from path.
    pub fn new(model_path: &Path) -> Result<Self> {
        let session = Session::builder()
            .context("Failed to create ONNX session builder")?
            .with_intra_threads(1)
            .context("Failed to set intra threads")?
            .commit_from_file(model_path)
            .context(format!("Failed to load Silero VAD from {}", model_path.display()))?;

        let state = Array3::<f32>::zeros((2, 1, 128));

        tracing::info!("[VAD] Silero VAD loaded from {}", model_path.display());
        Ok(Self { session, state })
    }

    /// Run VAD on a 512-sample chunk. Returns speech probability 0.0–1.0.
    pub fn predict(&mut self, samples: &[f32]) -> Result<f32> {
        // Pad or truncate to exactly 512 samples
        let mut input_data = vec![0.0f32; VAD_CHUNK_SAMPLES];
        let len = samples.len().min(VAD_CHUNK_SAMPLES);
        input_data[..len].copy_from_slice(&samples[..len]);

        // Shape: [1, 512]
        let input_array = Array2::from_shape_vec((1, VAD_CHUNK_SAMPLES), input_data)
            .context("Failed to create input array")?;
        let sr_array = ndarray::arr0(16000i64);

        let input_value = ort::value::Value::from_array(input_array)
            .context("Failed to create input value")?;
        let state_value = ort::value::Value::from_array(self.state.clone())
            .context("Failed to create state value")?;
        let sr_value = ort::value::Value::from_array(sr_array)
            .context("Failed to create sr value")?;

        let outputs = self.session.run(ort::inputs![
            "input" => input_value,
            "state" => state_value,
            "sr" => sr_value,
        ]).context("Silero VAD inference failed")?;

        // Extract probability — shape [1, 1]
        let (_, output_data) = outputs["output"]
            .try_extract_tensor::<f32>()
            .context("Failed to extract VAD output")?;
        let prob = output_data[0];

        // Update state — shape [2, 1, 128]
        let (state_shape, state_data) = outputs["stateN"]
            .try_extract_tensor::<f32>()
            .context("Failed to extract VAD state")?;
        let dims = state_shape.as_ref();
        self.state = Array3::from_shape_vec(
            (dims[0] as usize, dims[1] as usize, dims[2] as usize),
            state_data.to_vec(),
        ).context("Failed to reshape VAD state")?;

        Ok(prob)
    }

    /// Reset internal state (call between utterances).
    pub fn reset(&mut self) {
        self.state.fill(0.0);
    }

    /// Process a longer audio buffer and return average speech probability.
    pub fn avg_probability(&mut self, samples: &[f32]) -> Result<f32> {
        if samples.is_empty() {
            return Ok(0.0);
        }
        let mut sum = 0.0f32;
        let mut count = 0u32;
        for chunk in samples.chunks(VAD_CHUNK_SAMPLES) {
            if chunk.len() >= VAD_CHUNK_SAMPLES / 2 {
                sum += self.predict(chunk)?;
                count += 1;
            }
        }
        Ok(if count > 0 { sum / count as f32 } else { 0.0 })
    }
}
