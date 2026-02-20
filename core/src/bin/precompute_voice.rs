//! Pre-compute voice state from .wav → .safetensors.
//!
//! Eliminates the ~15s startup cost of encoding voice through Mimi every time.
//! The output .safetensors contains the audio_prompt tensor that can be loaded
//! instantly with `TTSModel::get_voice_state_from_prompt_file()`.
//!
//! Usage: cargo run --release --bin precompute_voice

use anyhow::{Context, Result};
use std::path::Path;

fn main() -> Result<()> {
    let project_root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    dotenvy::from_path(project_root.join(".env")).ok();

    let voice_raw = std::env::var("POCKET_VOICE").unwrap_or_else(|_| "voices/oliver.wav".into());
    let wav_path = if voice_raw.contains('/') || voice_raw.contains('.') {
        let p = project_root.join(&voice_raw);
        if p.exists() { p } else { std::path::PathBuf::from(&voice_raw) }
    } else {
        eprintln!("POCKET_VOICE='{voice_raw}' is a built-in name, not a .wav file.");
        eprintln!("Pre-compute is only needed for custom .wav voices.");
        std::process::exit(0);
    };

    if !wav_path.exists() {
        anyhow::bail!("Voice file not found: {}", wav_path.display());
    }

    if wav_path.extension().map(|e| e == "safetensors").unwrap_or(false) {
        println!("Already a .safetensors file, nothing to do.");
        return Ok(());
    }

    let out_path = wav_path.with_extension("safetensors");

    println!("Loading TTS model...");
    let t0 = std::time::Instant::now();
    let model = pocket_tts::TTSModel::load("b6369a24")
        .context("Failed to load TTS model")?;
    println!("  Model loaded in {:.0}ms", t0.elapsed().as_millis());

    println!("Encoding voice: {}", wav_path.display());
    let t1 = std::time::Instant::now();

    // Use the model's own voice encoding (goes through Mimi + projection)
    // We need the intermediate audio_prompt tensor, not the full state.
    // get_voice_state_from_tensor returns ModelState but we need the prompt.
    // Instead, replicate the encoding steps to capture the prompt tensor.
    let (audio, sample_rate) = pocket_tts::audio::read_wav(&wav_path)
        .context("Failed to read wav")?;
    let audio = if sample_rate != model.sample_rate as u32 {
        pocket_tts::audio::resample(&audio, sample_rate, model.sample_rate as u32)?
    } else {
        audio
    };
    let audio = audio.unsqueeze(0)?;

    // Encode through Mimi
    let frame_size = model.mimi.frame_size();
    let (b, c, t) = audio.dims3()?;
    let pad_len = if t % frame_size != 0 { frame_size - (t % frame_size) } else { 0 };
    let audio = if pad_len > 0 {
        let pad = candle_core::Tensor::zeros((b, c, pad_len), audio.dtype(), &model.device)?;
        candle_core::Tensor::cat(&[&audio, &pad], 2)?
    } else {
        audio
    };

    let mut mimi_state = pocket_tts::voice_state::init_states(1, 1000);
    let encoded = model.mimi.encode_to_latent(&audio, &mut mimi_state, 0)?;
    let latents = encoded.transpose(1, 2)?.to_dtype(candle_core::DType::F32)?;

    // Project to flow model space
    let (b, t, d) = latents.dims3()?;
    let latents_2d = latents.reshape((b * t, d))?;
    let conditioning_2d = latents_2d.matmul(&model.speaker_proj_weight.t()?)?;
    let audio_prompt = conditioning_2d.reshape((b, t, model.dim))?;

    println!("  Encoded in {:.0}ms (shape: {:?})", t1.elapsed().as_millis(), audio_prompt.dims());

    // Save as safetensors using candle
    candle_core::safetensors::save(
        &std::collections::HashMap::from([("audio_prompt".to_string(), audio_prompt)]),
        &out_path,
    )?;

    let size = std::fs::metadata(&out_path)?.len();
    println!("\nSaved: {} ({:.1} KB)", out_path.display(), size as f64 / 1024.0);
    let rel = out_path.strip_prefix(project_root).unwrap_or(&out_path);
    println!("\nUpdate .env:\n  POCKET_VOICE={}", rel.display());

    Ok(())
}
