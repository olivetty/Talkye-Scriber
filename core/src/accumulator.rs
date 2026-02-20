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


#[cfg(test)]
mod tests {
    use super::*;

    fn words(s: &str) -> Vec<String> {
        s.split_whitespace().map(|w| w.to_string()).collect()
    }

    #[test]
    fn first_flush_at_threshold() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 4, min_words: 6 });
        // 3 words — below first threshold
        assert!(acc.add_words(words("one two three"), false).is_none());
        assert_eq!(acc.word_count(), 3);
        // 2 more — now 5, above first threshold of 4
        let result = acc.add_words(words("four five"), false);
        assert!(result.is_some());
        assert_eq!(result.unwrap(), "one two three four five");
        assert_eq!(acc.word_count(), 0);
    }

    #[test]
    fn subsequent_flush_uses_min_words() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 2, min_words: 5 });
        // First flush at 2
        let r = acc.add_words(words("hello world"), false);
        assert!(r.is_some());
        // Now subsequent threshold is 5
        assert!(acc.add_words(words("a b c"), false).is_none());
        assert_eq!(acc.word_count(), 3);
        let r = acc.add_words(words("d e"), false);
        assert!(r.is_some());
        assert_eq!(r.unwrap(), "a b c d e");
    }

    #[test]
    fn speech_final_forces_flush() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 10, min_words: 10 });
        let r = acc.add_words(words("just two"), true);
        assert!(r.is_some());
        assert_eq!(r.unwrap(), "just two");
    }

    #[test]
    fn speech_final_resets_first_flushed() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 2, min_words: 8 });
        // First flush
        acc.add_words(words("hello world"), false);
        // Now min_words=8 applies
        assert!(acc.add_words(words("a b c"), false).is_none());
        // speech_final resets
        acc.add_words(words("d"), true);
        // Next flush should use first_words=2 again
        let r = acc.add_words(words("new sentence"), false);
        assert!(r.is_some());
    }

    #[test]
    fn utterance_end_flushes_and_resets() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 10, min_words: 10 });
        acc.add_words(words("partial"), false);
        let r = acc.utterance_end();
        assert_eq!(r.unwrap(), "partial");
        assert_eq!(acc.word_count(), 0);
        // first_flushed should be reset — next uses first_words
        let r = acc.add_words(words("new start here yes"), false);
        // first_words=10, so 4 words shouldn't flush
        assert!(r.is_none());
    }

    #[test]
    fn utterance_end_empty_returns_none() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 4, min_words: 6 });
        assert!(acc.utterance_end().is_none());
    }

    #[test]
    fn timeout_flush() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 10, min_words: 10 });
        acc.add_words(words("trailing words"), false);
        let r = acc.timeout_flush();
        assert_eq!(r.unwrap(), "trailing words");
        assert_eq!(acc.word_count(), 0);
    }

    #[test]
    fn timeout_flush_empty_returns_none() {
        let mut acc = Accumulator::new(&AccumulatorConfig { first_words: 4, min_words: 6 });
        assert!(acc.timeout_flush().is_none());
    }

    // ── split_clauses tests ──

    #[test]
    fn split_no_delimiters() {
        assert_eq!(split_clauses("hello world"), vec!["hello world"]);
    }

    #[test]
    fn split_at_comma() {
        let r = split_clauses("hello world, how are you, I am fine");
        assert_eq!(r.len(), 2); // "hello world" merged with "how are you" (3w min), then "I am fine"
    }

    #[test]
    fn split_merges_short_clauses() {
        // "a, b, c d e f" — "a" is too short, merges with "b", still short, merges with "c d e f"
        let r = split_clauses("a, b, c d e f");
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn split_semicolon_and_colon() {
        let r = split_clauses("first part here; second part here: third part here");
        assert!(r.len() >= 2);
    }

    #[test]
    fn split_empty_string() {
        let r = split_clauses("");
        assert_eq!(r, vec![""]);
    }

    #[test]
    fn split_preserves_all_words() {
        let input = "the weather is beautiful today, let's go outside and enjoy, maybe visit the park";
        let clauses = split_clauses(input);
        let rejoined: String = clauses.join(" ");
        // All words should be present
        for word in input.split_whitespace() {
            let clean = word.trim_matches(',');
            assert!(rejoined.contains(clean), "missing word: {clean}");
        }
    }
}
