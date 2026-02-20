//! Deepgram STT streaming client.
//!
//! Connects via WebSocket, sends raw PCM audio, receives transcription events.
//! Handles interim results, is_final, speech_final, and utterance_end.

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::audio::AudioChunk;

/// Configuration for the Deepgram STT connection.
pub struct SttConfig {
    pub api_key: String,
    pub language: String,
    pub endpointing_ms: u32,
    pub utterance_end_ms: u32,
}

impl SttConfig {
    pub fn from_env() -> Result<Self> {
        Ok(Self {
            api_key: std::env::var("DEEPGRAM_API_KEY")
                .context("DEEPGRAM_API_KEY not set")?,
            language: std::env::var("STT_LANGUAGE")
                .or_else(|_| std::env::var("DICTATE_LANGUAGE"))
                .unwrap_or_else(|_| "ro".into()),
            endpointing_ms: std::env::var("DEEPGRAM_ENDPOINTING")
                .unwrap_or_else(|_| "500".into())
                .parse()
                .unwrap_or(500),
            utterance_end_ms: std::env::var("DEEPGRAM_UTTERANCE_END")
                .unwrap_or_else(|_| "1500".into())
                .parse()
                .unwrap_or(1500),
        })
    }

    fn ws_url(&self) -> String {
        format!(
            "wss://api.deepgram.com/v1/listen\
             ?model=nova-3&language={}&encoding=linear16\
             &sample_rate=16000&channels=1&interim_results=true\
             &smart_format=true&endpointing={}\
             &utterance_end_ms={}&vad_events=true",
            self.language, self.endpointing_ms, self.utterance_end_ms
        )
    }
}

/// Events emitted by the STT client.
#[derive(Debug, Clone)]
pub enum SttEvent {
    /// Interim (partial) transcript — may change.
    Interim(String),
    /// Final transcript for a phrase. Contains words and timing.
    Final {
        transcript: String,
        words: Vec<SttWord>,
        speech_final: bool,
    },
    /// Utterance ended (long silence).
    UtteranceEnd,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SttWord {
    pub word: String,
    pub start: f64,
    pub end: f64,
}

/// Deepgram response structures (subset).
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

/// Streaming STT client.
pub struct SttClient {
    config: SttConfig,
}

impl SttClient {
    pub fn new(config: SttConfig) -> Self {
        Self { config }
    }

    /// Connect to Deepgram and start streaming.
    ///
    /// - `audio_rx`: receives PCM chunks to send
    /// - `event_tx`: sends parsed STT events
    pub async fn run(
        &self,
        mut audio_rx: mpsc::Receiver<AudioChunk>,
        event_tx: mpsc::Sender<SttEvent>,
    ) -> Result<()> {
        let url = self.config.ws_url();
        let request = http::Request::builder()
            .uri(&url)
            .header("Authorization", format!("Token {}", self.config.api_key))
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

        // Send audio task
        let send_handle = tokio::spawn(async move {
            while let Some(chunk) = audio_rx.recv().await {
                if ws_tx.send(Message::Binary(chunk.into())).await.is_err() {
                    break;
                }
            }
            // Send close
            let close_msg = serde_json::json!({"type": "CloseStream"});
            let _ = ws_tx
                .send(Message::Text(close_msg.to_string().into()))
                .await;
        });

        // Receive events
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

            let data: DgResponse = match serde_json::from_str(&text) {
                Ok(d) => d,
                Err(_) => continue,
            };

            let event = match data.msg_type.as_deref() {
                Some("UtteranceEnd") => Some(SttEvent::UtteranceEnd),
                Some("Results") => {
                    if let Some(channel) = data.channel {
                        if let Some(alt) = channel.alternatives.first() {
                            if alt.transcript.is_empty() {
                                None
                            } else if data.is_final.unwrap_or(false) {
                                Some(SttEvent::Final {
                                    transcript: alt.transcript.clone(),
                                    words: alt.words.clone().unwrap_or_default(),
                                    speech_final: data.speech_final.unwrap_or(false),
                                })
                            } else {
                                Some(SttEvent::Interim(alt.transcript.clone()))
                            }
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                }
                _ => None,
            };

            if let Some(evt) = event {
                if event_tx.send(evt).await.is_err() {
                    break;
                }
            }
        }

        send_handle.abort();
        Ok(())
    }
}
