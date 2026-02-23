//! Persistent TTS server — keeps model in memory, accepts commands on stdin.
//!
//! Protocol: JSON lines on stdin/stdout.
//!
//! Startup: prints {"ready":true,"sample_rate":24000} when model is loaded.
//!
//! Commands:
//!   {"cmd":"load_voice","path":"/path/to/voice.safetensors"}
//!   {"cmd":"synthesize","text":"Hello","output":"/tmp/out.wav"}
//!   {"cmd":"ping"}
//!   {"cmd":"quit"}
//!
//! Responses:
//!   {"ok":true,...}
//!   {"ok":false,"error":"message"}

use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::Path;

fn main() -> Result<()> {
    let project_root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    dotenvy::from_path(project_root.join(".env")).ok();

    // Load model once
    let model = pocket_tts::TTSModel::load("b6369a24")
        .context("Failed to load TTS model")?;

    let sample_rate = model.sample_rate;

    // Start with zero-shot voice (no cloning)
    let mut voice_state = pocket_tts::voice_state::init_states(1, 1000);
    let mut current_voice = String::new();

    // Signal ready
    let stdout = io::stdout();
    let mut out = stdout.lock();
    writeln!(out, "{}", json!({"ready": true, "sample_rate": sample_rate}))?;
    out.flush()?;
    drop(out);

    // Command loop
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let cmd: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                respond(&json!({"ok": false, "error": format!("Invalid JSON: {e}")}));
                continue;
            }
        };

        match cmd["cmd"].as_str().unwrap_or("") {
            "ping" => {
                respond(&json!({"ok": true, "pong": true}));
            }
            "quit" => {
                respond(&json!({"ok": true, "bye": true}));
                break;
            }
            "load_voice" => {
                let path_str = cmd["path"].as_str().unwrap_or("");
                match load_voice(&model, path_str, project_root) {
                    Ok((state, resolved_path)) => {
                        voice_state = state;
                        current_voice = resolved_path.clone();
                        respond(&json!({
                            "ok": true,
                            "voice": resolved_path,
                        }));
                    }
                    Err(e) => {
                        respond(&json!({"ok": false, "error": format!("{e}")}));
                    }
                }
            }
            "synthesize" => {
                let text = cmd["text"].as_str().unwrap_or("");
                let output = cmd["output"].as_str().unwrap_or("");
                if text.is_empty() || output.is_empty() {
                    respond(&json!({"ok": false, "error": "text and output required"}));
                    continue;
                }
                let speed: f32 = cmd["speed"].as_f64().unwrap_or(1.0) as f32;
                match synthesize(&model, &voice_state, text, output, speed) {
                    Ok(meta) => respond(&meta),
                    Err(e) => {
                        respond(&json!({"ok": false, "error": format!("{e}")}));
                    }
                }
            }
            other => {
                respond(&json!({"ok": false, "error": format!("Unknown command: {other}")}));
            }
        }
    }

    Ok(())
}

fn respond(value: &Value) {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn load_voice(
    model: &pocket_tts::TTSModel,
    path_str: &str,
    project_root: &Path,
) -> Result<(pocket_tts::ModelState, String)> {
    if path_str.is_empty() {
        // Zero-shot (generic voice)
        let state = pocket_tts::voice_state::init_states(1, 1000);
        return Ok((state, String::new()));
    }

    // Resolve path
    let voice_path = if Path::new(path_str).is_absolute() {
        std::path::PathBuf::from(path_str)
    } else {
        let p = project_root.join(path_str);
        if p.exists() { p } else { std::path::PathBuf::from(path_str) }
    };

    if !voice_path.exists() {
        anyhow::bail!("Voice file not found: {}", voice_path.display());
    }

    // Auto-precompute: if .wav, check for .safetensors sibling
    let effective_path = if voice_path.extension().map(|e| e == "wav").unwrap_or(false) {
        let st_path = voice_path.with_extension("safetensors");
        if st_path.exists() {
            // Use pre-computed version
            st_path
        } else {
            // Auto-precompute: encode through Mimi and save
            eprintln!("[tts_server] Auto-precomputing voice: {} → {}", 
                      voice_path.display(), st_path.display());
            match precompute_voice(model, &voice_path, &st_path) {
                Ok(()) => {
                    eprintln!("[tts_server] Precompute done: {}", st_path.display());
                    st_path
                }
                Err(e) => {
                    eprintln!("[tts_server] Precompute failed, using raw wav: {e}");
                    voice_path.clone()
                }
            }
        }
    } else {
        voice_path.clone()
    };

    // Load voice state
    let state = if effective_path.extension().map(|e| e == "safetensors").unwrap_or(false) {
        model.get_voice_state_from_prompt_file(effective_path.to_str().unwrap())
            .context("Failed to load precomputed voice")?
    } else {
        model.get_voice_state(effective_path.to_str().unwrap())
            .context("Failed to load voice")?
    };

    Ok((state, effective_path.to_string_lossy().to_string()))
}

fn precompute_voice(
    model: &pocket_tts::TTSModel,
    wav_path: &Path,
    st_path: &Path,
) -> Result<()> {
    let (audio, sample_rate) = pocket_tts::audio::read_wav(wav_path)
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
        st_path,
    )?;

    Ok(())
}

fn synthesize(
    model: &pocket_tts::TTSModel,
    voice_state: &pocket_tts::ModelState,
    text: &str,
    output_path: &str,
    speed: f32,
) -> Result<Value> {
    let mut samples: Vec<f32> = Vec::new();
    for chunk in model.generate_stream(text, voice_state) {
        let tensor = chunk.map_err(|e| anyhow::anyhow!("{e}"))?;
        let data: Vec<f32> = tensor
            .flatten_all().map_err(|e| anyhow::anyhow!("{e}"))?
            .to_vec1().map_err(|e| anyhow::anyhow!("{e}"))?;
        samples.extend_from_slice(&data);
    }

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

    let duration_ms = (samples.len() as f64 / model.sample_rate as f64 * 1000.0) as u64;
    Ok(json!({
        "ok": true,
        "path": output_path,
        "samples": samples.len(),
        "duration_ms": duration_ms,
        "sample_rate": sr,
    }))
}
