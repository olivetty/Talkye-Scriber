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
        Self {
            from_lang: config.from_lang.clone(),
            to_lang: config.to_lang.clone(),
            model: config.model.clone(),
            api_key: config.api_key.clone(),
            client: Client::new(),
            context: Mutex::new(Vec::new()),
            segment: Mutex::new(Vec::new()),
        }
    }

    /// Translate a text fragment. Returns translated text.
    pub async fn translate(&self, text: &str) -> Result<String> {
        let ctx_prompt = self.build_context();

        let system = format!(
            "You are a real-time {} to {} interpreter in a live conversation. \
             Translate naturally. Output ONLY the {} translation, nothing else. \
             If given previous parts of the same sentence, ensure your translation \
             flows naturally as a continuation.",
            self.from_lang, self.to_lang, self.to_lang
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
