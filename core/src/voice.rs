//! Voice management — list, precompute, preview voices.
//!
//! Used by Flutter FFI for the Voice Clone screen.

use anyhow::{Context, Result};
use std::path::Path;

/// Info about a voice file.
#[derive(Debug, Clone)]
pub struct VoiceInfo {
    pub name: String,
    pub path: String,
    pub is_precomputed: bool,
    pub size_bytes: u64,
}

/// List all voices in a directory (*.wav and *.safetensors).
pub fn list_voices(voices_dir: &str) -> Vec<VoiceInfo> {
    let dir = Path::new(voices_dir);
    if !dir.is_dir() {
        return vec![];
    }
    let mut voices = vec![];
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            // Skip builtin subdirectory
            if path.is_dir() { continue; }
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if ext != "wav" && ext != "safetensors" {
                continue;
            }
            let name = path.file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown")
                .to_string();
            // Skip preview WAVs and raw WAVs that have a precomputed version
            if name.ends_with("_preview") { continue; }
            if ext == "wav" && dir.join(format!("{name}.safetensors")).exists() {
                continue;
            }
            let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            voices.push(VoiceInfo {
                name,
                path: path.to_string_lossy().to_string(),
                is_precomputed: ext == "safetensors",
                size_bytes: size,
            });
        }
    }
    voices.sort_by(|a, b| a.name.cmp(&b.name));
    voices
}

/// Precompute voice: .wav → .safetensors (fast load).
/// Returns path to the generated .safetensors file.
pub fn precompute_voice(wav_path: &str) -> Result<String> {
    let wav = Path::new(wav_path);
    if !wav.exists() {
        anyhow::bail!("Voice file not found: {wav_path}");
    }
    if wav.extension().map(|e| e == "safetensors").unwrap_or(false) {
        return Ok(wav_path.to_string());
    }

    let out_path = wav.with_extension("safetensors");

    tracing::info!("[VOICE] Loading TTS model for precompute...");
    let model = pocket_tts::TTSModel::load("b6369a24")
        .context("Failed to load TTS model")?;

    tracing::info!("[VOICE] Encoding voice: {wav_path}");
    let (audio, sample_rate) = pocket_tts::audio::read_wav(wav)
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

    let (b, t, d) = latents.dims3()?;
    let latents_2d = latents.reshape((b * t, d))?;
    let conditioning_2d = latents_2d.matmul(&model.speaker_proj_weight.t()?)?;
    let audio_prompt = conditioning_2d.reshape((b, t, model.dim))?;

    candle_core::safetensors::save(
        &std::collections::HashMap::from([("audio_prompt".to_string(), audio_prompt)]),
        &out_path,
    )?;

    let out_str = out_path.to_string_lossy().to_string();
    tracing::info!("[VOICE] Saved: {out_str}");
    Ok(out_str)
}

/// Generate a preview for a voice — TTS a sample sentence, save as {name}_preview.wav, and play it.
/// Returns path to the saved preview WAV.
pub fn preview_voice(voice_path: &str) -> Result<String> {
    let model = pocket_tts::TTSModel::load("b6369a24")
        .context("Failed to load TTS model")?;

    let state = if voice_path.ends_with(".safetensors") {
        model.get_voice_state_from_prompt_file(voice_path)
            .context("Failed to load precomputed voice")?
    } else {
        model.get_voice_state(voice_path)
            .context("Failed to load voice")?
    };

    let text = "Hello, this is a preview of my cloned voice. How does it sound?";
    let mut samples = vec![];
    for chunk in model.generate_stream(text, &state) {
        let tensor = chunk.map_err(|e| anyhow::anyhow!("{e}"))?;
        let data: Vec<f32> = tensor.flatten_all()
            .map_err(|e| anyhow::anyhow!("{e}"))?
            .to_vec1()
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        samples.extend_from_slice(&data);
    }

    let sr = model.sample_rate as u32;

    // Save preview WAV next to the voice file
    let voice_p = Path::new(voice_path);
    let stem = voice_p.file_stem().and_then(|s| s.to_str()).unwrap_or("voice");
    let preview_path = voice_p.with_file_name(format!("{stem}_preview.wav"));
    let preview_str = preview_path.to_string_lossy().to_string();
    save_wav(&preview_str, &samples, sr)?;
    tracing::info!("[VOICE] Preview saved: {preview_str}");

    // Play it
    play_wav_samples(&samples, sr);

    Ok(preview_str)
}

/// Play a cached preview WAV file (instant, no TTS).
pub fn play_preview(preview_wav_path: &str) -> Result<()> {
    let p = Path::new(preview_wav_path);
    if !p.exists() {
        anyhow::bail!("Preview file not found: {preview_wav_path}");
    }
    let (audio, sample_rate) = pocket_tts::audio::read_wav(p)
        .context("Failed to read preview wav")?;
    let samples: Vec<f32> = audio.flatten_all()
        .map_err(|e| anyhow::anyhow!("{e}"))?
        .to_vec1()
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    play_wav_samples(&samples, sample_rate);
    Ok(())
}

/// Play PCM f32 samples through default output device.
fn play_wav_samples(samples: &[f32], sr: u32) {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    let host = cpal::default_host();
    if let Some(device) = host.default_output_device() {
        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(sr),
            buffer_size: cpal::BufferSize::Default,
        };
        let samples_play = samples.to_vec();
        let pos = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let pos_clone = pos.clone();
        let len = samples_play.len();

        let stream = device.build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let mut p = pos_clone.load(std::sync::atomic::Ordering::Relaxed);
                for sample in data.iter_mut() {
                    *sample = if p < len { samples_play[p] } else { 0.0 };
                    p += 1;
                }
                pos_clone.store(p, std::sync::atomic::Ordering::Relaxed);
            },
            |e| tracing::error!("[VOICE] Playback error: {e}"),
            None,
        ).ok();

        if let Some(s) = stream {
            s.play().ok();
            let duration_ms = (samples.len() as f64 / sr as f64 * 1000.0) as u64 + 200;
            std::thread::sleep(std::time::Duration::from_millis(duration_ms));
        }
    }
}

/// Record audio from default mic for `duration_secs` and save as .wav.
/// Returns path to the saved .wav file.
pub fn record_voice(output_path: &str, duration_secs: f32) -> Result<String> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    let host = cpal::default_host();
    let device = host.default_input_device()
        .context("No input device found")?;

    let config = cpal::StreamConfig {
        channels: 1,
        sample_rate: cpal::SampleRate(24000),
        buffer_size: cpal::BufferSize::Default,
    };

    let total_samples = (24000.0 * duration_secs) as usize;
    let samples = std::sync::Arc::new(std::sync::Mutex::new(Vec::with_capacity(total_samples)));
    let samples_clone = samples.clone();
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let done_clone = done.clone();

    let stream = device.build_input_stream(
        &config,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            let mut buf = samples_clone.lock().unwrap();
            if buf.len() < total_samples {
                let remaining = total_samples - buf.len();
                let take = data.len().min(remaining);
                buf.extend_from_slice(&data[..take]);
                if buf.len() >= total_samples {
                    done_clone.store(true, std::sync::atomic::Ordering::SeqCst);
                }
            }
        },
        |e| tracing::error!("[VOICE] Record error: {e}"),
        None,
    ).context("Failed to build input stream")?;

    stream.play().context("Failed to start recording")?;
    tracing::info!("[VOICE] Recording {duration_secs}s to {output_path}...");

    // Wait for recording to complete
    while !done.load(std::sync::atomic::Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    drop(stream);

    let buf = samples.lock().unwrap();
    save_wav(output_path, &buf, 24000)?;
    tracing::info!("[VOICE] Saved recording: {output_path} ({} samples)", buf.len());
    Ok(output_path.to_string())
}

/// Save PCM f32 samples as 16-bit WAV.
fn save_wav(path: &str, samples: &[f32], sample_rate: u32) -> Result<()> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec)
        .context("Failed to create wav file")?;
    for &s in samples {
        let val = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer.write_sample(val)?;
    }
    writer.finalize()?;
    Ok(())
}

/// Prepare a Chatterbox-optimized voice reference from a raw recording.
/// Trims silence, peak-normalizes to -1dB, saves as `{stem}_cbx.wav` at 24kHz mono.
/// Returns the path to the optimized file.
pub fn prepare_cbx_voice(wav_path: &str) -> Result<String> {
    let p = Path::new(wav_path);
    if !p.exists() {
        anyhow::bail!("WAV not found: {wav_path}");
    }

    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("voice");
    let dir = p.parent().unwrap_or(Path::new("."));
    let out_path = dir.join(format!("{stem}_cbx.wav"));

    // Read WAV
    let mut reader = hound::WavReader::open(wav_path)
        .context("Failed to read WAV")?;
    let spec = reader.spec();
    let samples: Vec<f32> = if spec.sample_format == hound::SampleFormat::Float {
        reader.samples::<f32>().filter_map(|s| s.ok()).collect()
    } else {
        reader.samples::<i16>().filter_map(|s| s.ok())
            .map(|s| s as f32 / 32768.0).collect()
    };

    if samples.is_empty() {
        anyhow::bail!("Empty WAV file: {wav_path}");
    }

    // Convert to mono if stereo
    let mono: Vec<f32> = if spec.channels > 1 {
        samples.chunks(spec.channels as usize)
            .map(|ch| ch.iter().sum::<f32>() / ch.len() as f32)
            .collect()
    } else {
        samples
    };

    // Trim silence (threshold: -40dB = 0.01 amplitude)
    let threshold = 0.01f32;
    let start = mono.iter().position(|&s| s.abs() > threshold).unwrap_or(0);
    let end = mono.iter().rposition(|&s| s.abs() > threshold).unwrap_or(mono.len() - 1) + 1;
    let trimmed = &mono[start..end.min(mono.len())];

    if trimmed.len() < 24000 {
        // Less than 1 second of audio after trimming — use original
        tracing::warn!("[VOICE] Very short audio after trim, using original");
    }

    let audio = if trimmed.len() >= 24000 { trimmed } else { &mono };

    // Peak normalize to -1dB (0.891)
    let peak = audio.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
    let target = 0.891f32; // -1dB
    let gain = if peak > 0.001 { target / peak } else { 1.0 };

    let normalized: Vec<f32> = audio.iter().map(|&s| (s * gain).clamp(-1.0, 1.0)).collect();

    // Resample to 24kHz if needed
    let final_samples = if spec.sample_rate != 24000 {
        // Simple linear interpolation resample
        let ratio = 24000.0 / spec.sample_rate as f64;
        let new_len = (normalized.len() as f64 * ratio) as usize;
        let mut resampled = Vec::with_capacity(new_len);
        for i in 0..new_len {
            let src_pos = i as f64 / ratio;
            let idx = src_pos as usize;
            let frac = src_pos - idx as f64;
            let s0 = normalized.get(idx).copied().unwrap_or(0.0);
            let s1 = normalized.get(idx + 1).copied().unwrap_or(s0);
            resampled.push(s0 + (s1 - s0) * frac as f32);
        }
        resampled
    } else {
        normalized
    };

    save_wav(&out_path.to_string_lossy(), &final_samples, 24000)?;

    let duration = final_samples.len() as f32 / 24000.0;
    tracing::info!(
        "[VOICE] Chatterbox voice prepared: {} ({:.1}s, peak normalized, gain={:.2})",
        out_path.display(), duration, gain,
    );

    Ok(out_path.to_string_lossy().to_string())
}


/// Delete a voice (wav, safetensors, and preview).
pub fn delete_voice(voice_path: &str) -> Result<()> {
    let p = Path::new(voice_path);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let dir = p.parent().unwrap_or(Path::new("."));

    // Remove main file
    if p.exists() { std::fs::remove_file(p)?; }
    // Remove counterpart
    if voice_path.ends_with(".safetensors") {
        let wav = dir.join(format!("{stem}.wav"));
        if wav.exists() { std::fs::remove_file(wav)?; }
    } else if voice_path.ends_with(".wav") {
        let st = dir.join(format!("{stem}.safetensors"));
        if st.exists() { std::fs::remove_file(st)?; }
    }
    // Remove Chatterbox-optimized WAV
    let cbx = dir.join(format!("{stem}_cbx.wav"));
    if cbx.exists() { std::fs::remove_file(cbx)?; }
    // Remove preview
    let preview = dir.join(format!("{stem}_preview.wav"));
    if preview.exists() { std::fs::remove_file(preview)?; }
    Ok(())
}
