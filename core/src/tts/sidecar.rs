//! Sidecar TTS backend — Chatterbox Multilingual via HTTP SSE.
//!
//! Calls the Python chatterbox_worker.py on port 8180.
//! Streams PCM float32 chunks via Server-Sent Events.
//! Supports 23 languages with voice cloning.

use anyhow::{Context, Result};
use serde::Serialize;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::time::Instant;

use super::TtsBackend;
use crate::config::TtsConfig;

const WORKER_HOST: &str = "127.0.0.1";
const WORKER_PORT: u16 = 8180;
const SAMPLE_RATE: usize = 24000;

/// Map full language names (from translate config) to ISO 639-1 codes.
/// Returns an owned String to avoid lifetime issues with dynamic codes.
fn lang_to_iso(lang: &str) -> String {
    let lower = lang.to_lowercase();
    match lower.as_str() {
        "arabic" => "ar",
        "danish" => "da",
        "german" | "deutsch" => "de",
        "greek" => "el",
        "english" => "en",
        "spanish" | "español" => "es",
        "finnish" => "fi",
        "french" | "français" => "fr",
        "hebrew" => "he",
        "hindi" => "hi",
        "italian" | "italiano" => "it",
        "japanese" => "ja",
        "korean" => "ko",
        "malay" => "ms",
        "dutch" | "nederlands" => "nl",
        "norwegian" => "no",
        "polish" | "polski" => "pl",
        "portuguese" | "português" => "pt",
        "russian" | "русский" => "ru",
        "swedish" | "svenska" => "sv",
        "swahili" => "sw",
        "turkish" | "türkçe" => "tr",
        "chinese" | "mandarin" => "zh",
        // If already a 2-char ISO code, pass through (no leak!)
        s if s.len() == 2 => return lower,
        _ => "en", // fallback
    }.to_string()
}

/// Resolve voice path to a .wav file for Chatterbox.
/// Pocket TTS uses .safetensors, but Chatterbox needs the original .wav.
/// Prefers optimized `_cbx.wav` (normalized, trimmed) over raw `.wav`.
fn resolve_voice_wav(voice_path: &str) -> Option<String> {
    if voice_path.is_empty() {
        return None;
    }
    let path = std::path::Path::new(voice_path);
    let dir = path.parent()?;
    let stem = path.file_stem()?.to_str()?;

    // 1. Check for Chatterbox-optimized WAV first
    let cbx_wav = dir.join(format!("{stem}_cbx.wav"));
    if cbx_wav.exists() {
        let s = cbx_wav.to_string_lossy().to_string();
        tracing::info!("[TTS-SIDECAR] using optimized voice: {s}");
        return Some(s);
    }

    // 2. Already a .wav file (non-cbx)
    if voice_path.ends_with(".wav") && path.exists() {
        return Some(voice_path.to_string());
    }

    // 3. For .safetensors, look for _cbx.wav or .wav in same directory
    if dir.exists() {
        // Try stem.wav
        let raw_wav = dir.join(format!("{stem}.wav"));
        if raw_wav.exists() {
            let s = raw_wav.to_string_lossy().to_string();
            tracing::info!("[TTS-SIDECAR] using raw voice: {s}");
            return Some(s);
        }
        // Fallback: any .wav in directory
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if let Some(ext) = p.extension().and_then(|e| e.to_str()) {
                    if ext == "wav" && !p.to_string_lossy().ends_with("_preview.wav") {
                        let s = p.to_string_lossy().to_string();
                        tracing::info!("[TTS-SIDECAR] resolved voice fallback: {voice_path} → {s}");
                        return Some(s);
                    }
                }
            }
        }
    }

    tracing::warn!("[TTS-SIDECAR] no .wav found for voice: {voice_path}");
    None
}

pub struct SidecarTts {
    voice_ref: Option<String>,
    speed: f32,
    exaggeration: f64,
    cfg_weight: f64,
    temperature: f64,
    context_window: i32,
}

/// JSON payload for Chatterbox streaming TTS.
#[derive(Serialize)]
struct StreamRequest<'a> {
    text: &'a str,
    language_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    voice_ref: Option<&'a str>,
    exaggeration: f64,
    cfg_weight: f64,
    temperature: f64,
    chunk_size: i32,
    context_window: i32,
}

impl SidecarTts {
    pub fn new(config: &TtsConfig) -> Result<Self> {
        let voice_ref = resolve_voice_wav(&config.voice);
        tracing::info!(
            "[TTS-SIDECAR] init: voice_ref={:?} exag={} cfg={} temp={} ctx_win={}",
            voice_ref.as_deref().unwrap_or("none"),
            config.cbx_exaggeration, config.cbx_cfg_weight,
            config.cbx_temperature, config.cbx_context_window,
        );

        // Verify worker is reachable
        match TcpStream::connect_timeout(
            &format!("{WORKER_HOST}:{WORKER_PORT}").parse().unwrap(),
            std::time::Duration::from_secs(2),
        ) {
            Ok(_) => tracing::info!("[TTS-SIDECAR] worker reachable at {WORKER_HOST}:{WORKER_PORT}"),
            Err(e) => tracing::warn!("[TTS-SIDECAR] worker not reachable: {e} — will retry on generate"),
        }

        Ok(Self {
            voice_ref,
            speed: config.speed,
            exaggeration: config.cbx_exaggeration,
            cfg_weight: config.cbx_cfg_weight,
            temperature: config.cbx_temperature,
            context_window: config.cbx_context_window,
        })
    }
}

impl TtsBackend for SidecarTts {
    fn generate_stream(
        &self,
        text: &str,
        language: &str,
        on_chunk: &mut dyn FnMut(&[f32]),
    ) -> Result<(u64, u64)> {
        let t0 = Instant::now();
        let lang_id = lang_to_iso(language);

        // Build JSON payload (serde handles escaping correctly)
        let req = StreamRequest {
            text,
            language_id: &lang_id,
            voice_ref: self.voice_ref.as_deref(),
            exaggeration: self.exaggeration,
            cfg_weight: self.cfg_weight,
            temperature: self.temperature,
            chunk_size: 25,
            context_window: self.context_window,
        };
        let body = serde_json::to_string(&req).context("Failed to serialize TTS request")?;

        tracing::info!(
            "[TTS-SIDECAR] requesting: lang={lang_id} text=\"{}\" voice={:?}",
            if text.len() > 60 { &text[..60] } else { text },
            self.voice_ref.as_deref().unwrap_or("none"),
        );

        // Raw HTTP POST (avoids reqwest::blocking panic inside tokio runtime)
        let addr = format!("{WORKER_HOST}:{WORKER_PORT}");
        let mut stream = TcpStream::connect_timeout(
            &addr.parse().unwrap(),
            std::time::Duration::from_secs(5),
        ).context("Cannot connect to Chatterbox worker (port 8180)")?;

        stream.set_read_timeout(Some(std::time::Duration::from_secs(120)))?;

        let request = format!(
            "POST /generate-stream HTTP/1.1\r\n\
             Host: {WORKER_HOST}:{WORKER_PORT}\r\n\
             Content-Type: application/json\r\n\
             Accept: text/event-stream\r\n\
             Content-Length: {}\r\n\
             Connection: close\r\n\
             \r\n\
             {}",
            body.len(),
            body,
        );
        stream.write_all(request.as_bytes())?;

        let reader = BufReader::new(stream);
        let mut first_chunk_ms = 0u64;
        let mut chunk_count = 0u32;
        let mut in_body = false;
        let mut http_status = 0u16;
        let mut body_lines: Vec<String> = Vec::new();

        for line_result in reader.lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(e) => {
                    if chunk_count > 0 { break; }
                    return Err(anyhow::anyhow!("Read error from worker: {e}"));
                }
            };

            // Parse HTTP status line
            if http_status == 0 && line.starts_with("HTTP/") {
                if let Some(code_str) = line.split_whitespace().nth(1) {
                    http_status = code_str.parse().unwrap_or(0);
                }
                if http_status != 200 {
                    tracing::error!("[TTS-SIDECAR] HTTP {http_status}: {line}");
                }
                continue;
            }

            // Skip HTTP headers, detect body start
            if !in_body {
                if line.is_empty() { in_body = true; }
                continue;
            }

            // Non-200: collect body for error message
            if http_status != 200 {
                body_lines.push(line);
                continue;
            }

            // Parse SSE data lines
            if !line.starts_with("data: ") { continue; }
            let json_str = &line[6..];

            let evt: serde_json::Value = match serde_json::from_str(json_str) {
                Ok(v) => v,
                Err(e) => {
                    tracing::warn!("[TTS-SIDECAR] JSON parse error: {e} — line: {json_str}");
                    continue;
                }
            };

            // Check for done
            if evt.get("done").and_then(|v| v.as_bool()).unwrap_or(false) {
                tracing::info!(
                    "[TTS-SIDECAR] stream done: {} chunks, {:.1}s audio, RTF={:.3}",
                    evt.get("chunks").and_then(|v| v.as_u64()).unwrap_or(0),
                    evt.get("total_audio").and_then(|v| v.as_f64()).unwrap_or(0.0),
                    evt.get("rtf").and_then(|v| v.as_f64()).unwrap_or(0.0),
                );
                break;
            }

            // Check for error event
            if let Some(err) = evt.get("error").and_then(|v| v.as_str()) {
                return Err(anyhow::anyhow!("Chatterbox worker error: {err}"));
            }

            // Decode PCM chunk
            if let Some(pcm_b64) = evt.get("chunk").and_then(|v| v.as_str()) {
                let pcm_bytes = base64::Engine::decode(
                    &base64::engine::general_purpose::STANDARD,
                    pcm_b64,
                ).context("base64 decode failed")?;

                let samples: Vec<f32> = pcm_bytes
                    .chunks_exact(4)
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect();

                if !samples.is_empty() {
                    chunk_count += 1;
                    if chunk_count == 1 {
                        first_chunk_ms = t0.elapsed().as_millis() as u64;
                        tracing::info!("[TTS-SIDECAR] first chunk: {first_chunk_ms}ms, {} samples", samples.len());
                    }
                    on_chunk(&samples);
                }
            }
        }

        // Report errors
        if http_status != 200 && http_status != 0 {
            let err_body = body_lines.join("\n");
            return Err(anyhow::anyhow!(
                "Chatterbox worker HTTP {http_status}: {}",
                if err_body.len() > 300 { &err_body[..300] } else { &err_body }
            ));
        }

        if chunk_count == 0 {
            tracing::error!("[TTS-SIDECAR] no audio chunks received for: \"{text}\"");
        }

        let total_ms = t0.elapsed().as_millis() as u64;
        tracing::info!(
            "[TTS-SIDECAR] lang={lang_id} first_chunk={first_chunk_ms}ms total={total_ms}ms chunks={chunk_count}",
        );
        Ok((first_chunk_ms, total_ms))
    }

    fn sample_rate(&self) -> usize {
        SAMPLE_RATE
    }

    fn playback_rate(&self) -> u32 {
        (SAMPLE_RATE as f32 * self.speed) as u32
    }
}
