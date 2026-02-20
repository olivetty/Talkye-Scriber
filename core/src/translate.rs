//! LLM translation via Groq API.
//!
//! Mirrors the Python prototype's approach:
//! - System prompt for real-time interpreter behavior
//! - Context window of recent translations for coherence
//! - Segment fragments for mid-sentence continuity

use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

pub struct TranslateConfig {
    pub api_key: String,
    pub model: String,
    pub from_lang: String,
    pub to_lang: String,
}

impl TranslateConfig {
    pub fn from_env() -> Result<Self> {
        Ok(Self {
            api_key: std::env::var("GROQ_API_KEY").context("GROQ_API_KEY not set")?,
            model: std::env::var("TRANSLATE_MODEL")
                .unwrap_or_else(|_| "llama-3.3-70b-versatile".into()),
            from_lang: std::env::var("TRANSLATE_FROM").unwrap_or_else(|_| "Romanian".into()),
            to_lang: std::env::var("TRANSLATE_TO").unwrap_or_else(|_| "English".into()),
        })
    }
}

/// Recent translation pair for context.
#[derive(Clone)]
struct TranslationPair {
    source: String,
    target: String,
}

/// Translator with context tracking.
pub struct Translator {
    config: TranslateConfig,
    client: Client,
    /// Recent translations for context (last N pairs).
    context: Mutex<Vec<TranslationPair>>,
    /// Fragments within the current segment (for mid-sentence continuity).
    segment_fragments: Mutex<Vec<TranslationPair>>,
}

const CONTEXT_SIZE: usize = 4;

impl Translator {
    pub fn new(config: TranslateConfig) -> Self {
        Self {
            config,
            client: Client::new(),
            context: Mutex::new(Vec::new()),
            segment_fragments: Mutex::new(Vec::new()),
        }
    }

    /// Translate a text fragment. Returns the translated text.
    pub async fn translate(&self, text: &str) -> Result<String> {
        let context_prompt = self.build_context();

        let system = format!(
            "You are a real-time {} to {} interpreter in a live conversation. \
             Translate naturally. Output ONLY the {} translation, nothing else. \
             If given previous parts of the same sentence, ensure your translation \
             flows naturally as a continuation.",
            self.config.from_lang, self.config.to_lang, self.config.to_lang
        );

        let user_msg = format!("{context_prompt}Translate: {text}");

        let body = GroqRequest {
            model: &self.config.model,
            messages: vec![
                GroqMessage { role: "system", content: &system },
                GroqMessage { role: "user", content: &user_msg },
            ],
            max_tokens: 200,
            temperature: 0.1,
        };

        let resp = self
            .client
            .post("https://api.groq.com/openai/v1/chat/completions")
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .json(&body)
            .send()
            .await
            .context("Groq API request failed")?;

        let data: GroqResponse = resp.json().await.context("Failed to parse Groq response")?;

        let translated = data
            .choices
            .first()
            .map(|c| c.message.content.trim().to_string())
            .unwrap_or_default();

        // Update context
        self.add_pair(text, &translated);

        Ok(translated)
    }

    /// Clear segment fragments (call on utterance end).
    pub fn clear_segment(&self) {
        if let Ok(mut frags) = self.segment_fragments.lock() {
            frags.clear();
        }
    }

    fn build_context(&self) -> String {
        // Prefer segment fragments (mid-sentence), fall back to recent context
        if let Ok(frags) = self.segment_fragments.lock() {
            if !frags.is_empty() {
                let prev: Vec<String> = frags
                    .iter()
                    .rev()
                    .take(3)
                    .rev()
                    .map(|p| format!("'{}' = '{}'", p.source, p.target))
                    .collect();
                return format!(
                    "Previous parts of same sentence: {}\nContinue translating naturally.\n\n",
                    prev.join(" → ")
                );
            }
        }

        if let Ok(ctx) = self.context.lock() {
            if !ctx.is_empty() {
                let pairs: Vec<String> = ctx
                    .iter()
                    .rev()
                    .take(CONTEXT_SIZE)
                    .rev()
                    .map(|p| format!("{} → {}", p.source, p.target))
                    .collect();
                return format!("Recent:\n{}\n\n", pairs.join("\n"));
            }
        }

        String::new()
    }

    fn add_pair(&self, source: &str, target: &str) {
        let pair = TranslationPair {
            source: source.to_string(),
            target: target.to_string(),
        };

        if let Ok(mut frags) = self.segment_fragments.lock() {
            frags.push(pair.clone());
        }

        if let Ok(mut ctx) = self.context.lock() {
            ctx.push(pair);
            if ctx.len() > CONTEXT_SIZE * 2 {
                let drain_to = ctx.len() - CONTEXT_SIZE;
                ctx.drain(..drain_to);
            }
        }
    }
}

// ── Groq API types ──

#[derive(Serialize)]
struct GroqRequest<'a> {
    model: &'a str,
    messages: Vec<GroqMessage<'a>>,
    max_tokens: u32,
    temperature: f32,
}

#[derive(Serialize)]
struct GroqMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Deserialize)]
struct GroqResponse {
    choices: Vec<GroqChoice>,
}

#[derive(Deserialize)]
struct GroqChoice {
    message: GroqMessageResp,
}

#[derive(Deserialize)]
struct GroqMessageResp {
    content: String,
}
