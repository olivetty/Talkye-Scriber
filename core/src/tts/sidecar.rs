//! Sidecar TTS backend — Chatterbox Multilingual via HTTP SSE.
//!
//! Calls the Python chatterbox_worker.py on port 8180.
//! Streams PCM float32 chunks via Server-Sent Events.
//! Supports 23 languages with voice cloning.

use anyhow::{Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::time::Instant;

use super::TtsBackend;
use crate::config::TtsConfig;

const WORKER_HOST: &str = "127.0.0.1";
const WORKER_PORT: u16 = 8180;
const SAMPLE_RATE: usize = 24000;

/// Map full language names (from translate config) to ISO 639-1 codes.
fn lang_to_iso(lang: &str) -> &str {
    match lang.to_lowercase().as_str() {
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
        // If already an ISO code, pass through
        s if s.len() == 2 => lang.to_lowercase().leak(),
        _ => "en", // fallback
    }
}

pub struct SidecarTts {
    voice_ref: String,
    speed: f32,
}

impl SidecarTts {
    pub fn new(config: &TtsConfig) -> Result<Self> {
        // Verify worker is reachable
        match TcpStream::connect_timeout(
            &format!("{WORKER_HOST}:{WORKER_PORT}").parse().unwrap(),
            std::time::Duration::from_secs(2),
        ) {
            Ok(_) => tracing::info!("[TTS-SIDECAR] worker reachable at {WORKER_HOST}:{WORKER_PORT}"),
            Err(e) => tracing::warn!("[TTS-SIDECAR] worker not reachable: {e} — will retry on generate"),
        }

        Ok(Self {
            voice_ref: config.voice.clone(),
            speed: config.speed,
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

        // Build JSON payload
        let voice_ref = if self.voice_ref.is_empty() || !std::path::Path::new(&self.voice_ref).exists() {
            "null".to_string()
        } else {
            format!("\"{}\"", self.voice_ref.replace('\\', "\\\\").replace('"', "\\\""))
        };

        let body = format!(
            r#"{{"text":"{}","language_id":"{}","voice_ref":{},"exaggeration":0.5,"cfg_weight":0.5,"temperature":0.8,"chunk_size":25,"context_window":50}}"#,
            text.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', " "),
            lang_id,
            voice_ref,
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

        for line_result in reader.lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(e) => {
                    // Read timeout or connection closed
                    if chunk_count > 0 { break; }
                    return Err(e.into());
                }
            };

            // Skip HTTP headers
            if !in_body {
                if line.is_empty() { in_body = true; }
                continue;
            }

            // Parse SSE data lines
            if !line.starts_with("data: ") { continue; }
            let json_str = &line[6..];

            // Parse JSON
            let evt: serde_json::Value = match serde_json::from_str(json_str) {
                Ok(v) => v,
                Err(_) => continue,
            };

            // Check for done/error
            if evt.get("done").and_then(|v| v.as_bool()).unwrap_or(false) {
                tracing::info!(
                    "[TTS-SIDECAR] stream done: {} chunks, {:.1}s audio",
                    evt.get("chunks").and_then(|v| v.as_u64()).unwrap_or(0),
                    evt.get("total_audio").and_then(|v| v.as_f64()).unwrap_or(0.0),
                );
                break;
            }
            if let Some(err) = evt.get("error").and_then(|v| v.as_str()) {
                return Err(anyhow::anyhow!("Chatterbox worker error: {err}"));
            }

            // Decode PCM chunk
            if let Some(pcm_b64) = evt.get("chunk").and_then(|v| v.as_str()) {
                let pcm_bytes = base64::Engine::decode(
                    &base64::engine::general_purpose::STANDARD,
                    pcm_b64,
                ).context("base64 decode failed")?;

                // Convert bytes to f32 samples (little-endian)
                let samples: Vec<f32> = pcm_bytes
                    .chunks_exact(4)
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect();

                if !samples.is_empty() {
                    chunk_count += 1;
                    if chunk_count == 1 {
                        first_chunk_ms = t0.elapsed().as_millis() as u64;
                    }
                    on_chunk(&samples);
                }
            }
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
