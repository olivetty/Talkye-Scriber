//! Deepgram STT streaming client.
//!
//! Connects via WebSocket, sends raw PCM audio, receives transcription events.
//! Reference: prototype/test_deepgram.py on_message() + WebSocket setup.

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::audio::AudioChunk;
use crate::config::SttConfig;
use super::{SttEvent, SttWord};

/// Streaming STT client for Deepgram.
pub struct DeepgramStt {
    api_key: String,
    language: String,
    endpointing_ms: u32,
    utterance_end_ms: u32,
}

impl DeepgramStt {
    pub fn new(config: &SttConfig) -> Self {
        Self {
            api_key: config.api_key.clone().unwrap_or_default(),
            language: config.language.clone(),
            endpointing_ms: config.endpointing_ms,
            utterance_end_ms: config.utterance_end_ms,
        }
    }

    /// Connect to Deepgram and stream audio ↔ events.
    pub async fn run(
        &self,
        mut audio_rx: mpsc::Receiver<AudioChunk>,
        event_tx: mpsc::Sender<SttEvent>,
    ) -> Result<()> {
        let url = format!(
            "wss://api.deepgram.com/v1/listen\
             ?model=nova-3&language={}&encoding=linear16\
             &sample_rate=16000&channels=1&interim_results=true\
             &smart_format=true&endpointing={}\
             &utterance_end_ms={}&vad_events=true",
            self.language, self.endpointing_ms, self.utterance_end_ms
        );

        let request = http::Request::builder()
            .uri(&url)
            .header("Authorization", format!("Token {}", self.api_key))
            .header("Host", "api.deepgram.com")
            .header("Connection", "Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header(
                "Sec-WebSocket-Key",
                tokio_tungstenite::tungstenite::handshake::client::generate_key(),
            )
            .body(())?;

        let (ws_stream, _) =
            tokio_tungstenite::connect_async_tls_with_config(request, None, false, None)
                .await
                .context("Failed to connect to Deepgram")?;

        tracing::info!("Connected to Deepgram STT");
        let (mut ws_tx, mut ws_rx) = ws_stream.split();

        // Send audio chunks to Deepgram
        let send_handle = tokio::spawn(async move {
            while let Some(chunk) = audio_rx.recv().await {
                if ws_tx.send(Message::Binary(chunk.into())).await.is_err() {
                    break;
                }
            }
            let close = serde_json::json!({"type": "CloseStream"});
            let _ = ws_tx.send(Message::Text(close.to_string().into())).await;
        });

        // Receive and parse Deepgram events
        while let Some(msg) = ws_rx.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(e) => {
                    tracing::error!("WebSocket error: {e}");
                    break;
                }
            };

            let text = match msg {
                Message::Text(t) => t,
                Message::Close(_) => break,
                _ => continue,
            };

            if let Some(event) = Self::parse_event(&text) {
                if event_tx.send(event).await.is_err() {
                    break;
                }
            }
        }

        send_handle.abort();
        Ok(())
    }

    fn parse_event(json: &str) -> Option<SttEvent> {
        let data: DgResponse = serde_json::from_str(json).ok()?;

        match data.msg_type.as_deref() {
            Some("UtteranceEnd") => Some(SttEvent::UtteranceEnd),
            Some("Results") => {
                let channel = data.channel?;
                let alt = channel.alternatives.first()?;
                if alt.transcript.is_empty() {
                    return None;
                }
                if data.is_final.unwrap_or(false) {
                    Some(SttEvent::Final {
                        transcript: alt.transcript.clone(),
                        words: alt.words.clone().unwrap_or_default(),
                        speech_final: data.speech_final.unwrap_or(false),
                    })
                } else {
                    Some(SttEvent::Interim(alt.transcript.clone()))
                }
            }
            _ => None,
        }
    }
}

// ── Deepgram response types ──

#[derive(Deserialize)]
struct DgResponse {
    #[serde(rename = "type")]
    msg_type: Option<String>,
    channel: Option<DgChannel>,
    is_final: Option<bool>,
    speech_final: Option<bool>,
}

#[derive(Deserialize)]
struct DgChannel {
    alternatives: Vec<DgAlternative>,
}

#[derive(Deserialize)]
struct DgAlternative {
    transcript: String,
    words: Option<Vec<SttWord>>,
}
