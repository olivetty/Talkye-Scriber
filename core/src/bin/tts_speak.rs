//! Minimal TTS CLI — text → WAV file via pocket-tts.
//!
//! Used by the Python sidecar for voice chat TTS output.
//!
//! Usage:
//!   tts_speak "Hello world" /tmp/output.wav [voice_path] [speed]
//!
//! If voice_path is omitted, uses POCKET_VOICE from .env.
//! Writes 24kHz mono 16-bit WAV.

use anyhow::{Context, Result};
use std::path::Path;

fn main() -> Result<()> {
    let project_root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    dotenvy::from_path(project_root.join(".env")).ok();

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: tts_speak <text> <output.wav> [voice_path] [speed]");
        std::process::exit(1);
    }

    let text = &args[1];
    let output_path = &args[2];
    let voice_path = if args.len() > 3 {
        args[3].clone()
    } else {
        std::env::var("POCKET_VOICE").unwrap_or_else(|_| "voices/builtin/cosette.safetensors".into())
    };
    let speed: f32 = if args.len() > 4 {
        args[4].parse().unwrap_or(1.0)
    } else {
        std::env::var("POCKET_SPEED").ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1.0)
    };

    // Resolve voice path relative to project root
    let voice = if Path::new(&voice_path).is_absolute() {
        voice_path.clone()
    } else {
        let p = project_root.join(&voice_path);
        if p.exists() { p.to_string_lossy().to_string() } else { voice_path.clone() }
    };

    // Load model
    let model = pocket_tts::TTSModel::load("b6369a24")
        .context("Failed to load TTS model")?;

    // Load voice state
    let state = if voice.ends_with(".safetensors") {
        model.get_voice_state_from_prompt_file(&voice)
            .context("Failed to load precomputed voice")?
    } else if voice.contains('.') {
        model.get_voice_state(&voice)
            .context("Failed to load voice")?
    } else {
        // Built-in voice name
        model.get_voice_state(&voice)
            .context("Failed to load built-in voice")?
    };

    // Generate audio
    let mut samples: Vec<f32> = Vec::new();
    for chunk in model.generate_stream(text, &state) {
        let tensor = chunk.map_err(|e| anyhow::anyhow!("{e}"))?;
        let data: Vec<f32> = tensor.flatten_all()
            .map_err(|e| anyhow::anyhow!("{e}"))?
            .to_vec1()
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        samples.extend_from_slice(&data);
    }

    // Write WAV
    let sr = (model.sample_rate as f32 * speed) as u32;
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: sr,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(output_path, spec)
        .context("Failed to create output WAV")?;
    for &s in &samples {
        let val = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer.write_sample(val)?;
    }
    writer.finalize()?;

    // Print metadata as JSON for the sidecar to parse
    let duration_ms = (samples.len() as f64 / model.sample_rate as f64 * 1000.0) as u64;
    println!("{{\"ok\":true,\"samples\":{},\"duration_ms\":{},\"sample_rate\":{}}}", 
             samples.len(), duration_ms, sr);

    Ok(())
}
