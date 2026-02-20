//! Word accumulator — batches STT words into translation-sized chunks.
//!
//! Dual threshold: first flush at N words (fast response), subsequent at M words.
//! Timeout flush: 1.5s safety net for trailing words.
//! Immediate flush on speech_final / utterance_end.

/// Accumulator config.
pub struct AccumulatorConfig {
    pub first_words: usize,
    pub min_words: usize,
}

/// Batches words from STT finals into translation-ready text chunks.
pub struct Accumulator {
    words: Vec<String>,
    first_flushed: bool,
    first_words: usize,
    min_words: usize,
}

impl Accumulator {
    pub fn new(config: &AccumulatorConfig) -> Self {
        Self {
            words: Vec::new(),
            first_flushed: false,
            first_words: config.first_words,
            min_words: config.min_words,
        }
    }

    /// Add words from a Final event. Returns flush text if threshold met.
    pub fn add_words(&mut self, words: Vec<String>, speech_final: bool) -> Option<String> {
        self.words.extend(words);

        let threshold = if !self.first_flushed {
            self.first_words
        } else {
            self.min_words
        };

        tracing::info!(
            "[ACCUM] accum={} threshold={threshold} first_flushed={}",
            self.words.len(), self.first_flushed
        );

        if self.words.len() >= threshold || speech_final {
            let text = self.flush();
            if speech_final {
                self.first_flushed = false;
                tracing::info!("[ACCUM] speech_final → reset first_flushed");
            }
            Some(text)
        } else {
            tracing::info!("[ACCUM] buffering ({} < {threshold})", self.words.len());
            None
        }
    }

    /// Flush all buffered words. Returns text, resets buffer.
    pub fn flush(&mut self) -> String {
        let text = self.words.join(" ");
        self.words.clear();
        self.first_flushed = true;
        text
    }

    /// Force flush on utterance end. Returns text if any words buffered.
    pub fn utterance_end(&mut self) -> Option<String> {
        if self.words.is_empty() {
            self.first_flushed = false;
            return None;
        }
        let text = self.flush();
        self.first_flushed = false;
        Some(text)
    }

    /// Timeout flush — returns text if any words buffered.
    pub fn timeout_flush(&mut self) -> Option<String> {
        if self.words.is_empty() {
            return None;
        }
        Some(self.flush())
    }

    pub fn has_words(&self) -> bool {
        !self.words.is_empty()
    }

    pub fn word_count(&self) -> usize {
        self.words.len()
    }
}

/// Split text into clauses at natural boundaries for lower TTS latency.
/// Minimum 3 words per clause to avoid overhead from tiny fragments.
pub fn split_clauses(text: &str) -> Vec<String> {
    const MIN_WORDS: usize = 3;

    let parts: Vec<&str> = text.split(|c: char| matches!(c, ',' | ';' | ':' | '—' | '–')).collect();

    if parts.len() <= 1 {
        return vec![text.to_string()];
    }

    let mut clauses: Vec<String> = Vec::new();
    let mut current = String::new();

    for part in parts {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        if current.is_empty() {
            current = trimmed.to_string();
        } else if current.split_whitespace().count() < MIN_WORDS {
            current.push(' ');
            current.push_str(trimmed);
        } else {
            clauses.push(current);
            current = trimmed.to_string();
        }
    }
    if !current.is_empty() {
        if current.split_whitespace().count() < MIN_WORDS && !clauses.is_empty() {
            let last = clauses.last_mut().unwrap();
            last.push(' ');
            last.push_str(&current);
        } else {
            clauses.push(current);
        }
    }

    if clauses.is_empty() {
        vec![text.to_string()]
    } else {
        clauses
    }
}
