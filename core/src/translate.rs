//! LLM translation via Groq API.
//!
//! Translates text with context window for coherent output.
//! Reference: prototype/test_deepgram.py translate_worker() + do_translate().

use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

use crate::config::TranslateConfig;

const CONTEXT_SIZE: usize = 4;

/// Translator with context tracking for coherent translations.
pub struct Translator {
    from_lang: String,
    to_lang: String,
    model: String,
    api_key: String,
    client: Client,
    /// Recent translations (sliding window).
    context: Mutex<Vec<LangPair>>,
    /// Fragments within current segment (mid-sentence continuity).
    segment: Mutex<Vec<LangPair>>,
}

#[derive(Clone)]
struct LangPair {
    source: String,
    target: String,
}

impl Translator {
    pub fn new(config: &TranslateConfig) -> Self {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .connect_timeout(std::time::Duration::from_secs(5))
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            from_lang: config.from_lang.clone(),
            to_lang: config.to_lang.clone(),
            model: config.model.clone(),
            api_key: config.api_key.clone(),
            client,
            context: Mutex::new(Vec::new()),
            segment: Mutex::new(Vec::new()),
        }
    }

    /// Translate a text fragment. Returns translated text.
    pub async fn translate(&self, text: &str) -> Result<String> {
        // Skip empty/punctuation-only input
        let clean = text.chars().filter(|c| c.is_alphanumeric()).count();
        if clean == 0 {
            return Ok(String::new());
        }

        let ctx_prompt = self.build_context();

        let system = format!(
            "You are a real-time speech-to-speech interpreter. \
             Translate from {from} to {to}.\n\
             STRICT RULES:\n\
             - Output ONLY the {to} translation, nothing else\n\
             - NEVER apologize, NEVER say you don't understand\n\
             - NEVER ask the user to repeat or clarify\n\
             - NEVER add explanations, comments, or notes\n\
             - NEVER expand or elaborate — output must be similar length to input\n\
             - The input comes from automatic speech recognition and MAY contain errors or wrong language. Translate the INTENT, not literal words\n\
             - If input is garbled or nonsensical, translate your best guess into {to}\n\
             - If input is already in {to}, output it unchanged\n\
             - Keep it natural and conversational\n\
             - Maximum 1-2 sentences, similar word count to input",
            from = self.from_lang, to = self.to_lang
        );

        let user_msg = format!("{ctx_prompt}Translate: {text}");

        let body = GroqRequest {
            model: &self.model,
            messages: vec![
                GroqMsg { role: "system", content: &system },
                GroqMsg { role: "user", content: &user_msg },
            ],
            max_tokens: 200,
            temperature: 0.1,
        };

        let resp = self.client
            .post("https://api.groq.com/openai/v1/chat/completions")
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&body)
            .send()
            .await
            .context("Groq API request failed")?;

        // Check HTTP status before parsing
        let status = resp.status();
        if !status.is_success() {
            let err_body = resp.text().await.unwrap_or_default();
            let snippet = if err_body.len() > 200 { &err_body[..200] } else { &err_body };
            anyhow::bail!("Groq API HTTP {status}: {snippet}");
        }

        let data: GroqResponse = resp.json().await.context("Failed to parse Groq response")?;
        let translated = data.choices.first()
            .map(|c| c.message.content.trim().to_string())
            .unwrap_or_default();

        self.add_pair(text, &translated);
        Ok(translated)
    }

    /// Clear segment fragments (call on utterance end).
    pub fn clear_segment(&self) {
        if let Ok(mut s) = self.segment.lock() {
            s.clear();
        }
    }

    fn build_context(&self) -> String {
        // Prefer segment fragments (mid-sentence)
        if let Ok(frags) = self.segment.lock() {
            if !frags.is_empty() {
                let prev: Vec<String> = frags.iter().rev().take(3).rev()
                    .map(|p| format!("'{}' = '{}'", p.source, p.target))
                    .collect();
                return format!(
                    "Previous parts of same sentence: {}\nContinue translating naturally.\n\n",
                    prev.join(" → ")
                );
            }
        }
        // Fall back to recent context
        if let Ok(ctx) = self.context.lock() {
            if !ctx.is_empty() {
                let pairs: Vec<String> = ctx.iter().rev().take(CONTEXT_SIZE).rev()
                    .map(|p| format!("{} → {}", p.source, p.target))
                    .collect();
                return format!("Recent:\n{}\n\n", pairs.join("\n"));
            }
        }
        String::new()
    }

    fn add_pair(&self, source: &str, target: &str) {
        let pair = LangPair {
            source: source.to_string(),
            target: target.to_string(),
        };
        if let Ok(mut s) = self.segment.lock() {
            s.push(pair.clone());
            // Cap segment to prevent unbounded growth during long continuous speech
            if s.len() > 20 {
                let drain_to = s.len() - 10;
                s.drain(..drain_to);
            }
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
    messages: Vec<GroqMsg<'a>>,
    max_tokens: u32,
    temperature: f32,
}

#[derive(Serialize)]
struct GroqMsg<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Deserialize)]
struct GroqResponse {
    choices: Vec<GroqChoice>,
}

#[derive(Deserialize)]
struct GroqChoice {
    message: GroqMsgResp,
}

#[derive(Deserialize)]
struct GroqMsgResp {
    content: String,
}
