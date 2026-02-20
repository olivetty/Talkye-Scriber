//! Benchmark — measures each pipeline stage in isolation.
//!
//! Usage: cargo run --release --bin bench
//!
//! Measures: voice load, TTS (short/medium/long), translation, end-to-end.

use anyhow::Result;
use std::time::Instant;

fn main() -> Result<()> {
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    dotenvy::from_path(project_root.join(".env")).ok();

    println!("╔══════════════════════════════════════════════════════╗");
    println!("║  Talkye Meet — Benchmark                            ║");
    println!("╚══════════════════════════════════════════════════════╝\n");

    // ── Voice load ──
    let config = talkye_core::Config::from_env()?;
    println!("Voice: {}", config.tts.voice);
    println!();

    let t0 = Instant::now();
    let tts = talkye_core::tts::TtsEngine::new(&config.tts)?;
    let load_ms = t0.elapsed().as_millis();
    println!("Voice load: {load_ms}ms\n");

    // ── TTS benchmark ──
    let texts = [
        ("short (3w)", "Hello, how are you?"),
        ("medium (8w)", "The weather is beautiful today, let's go outside"),
        ("long (18w)", "I've been thinking about this problem for a while and I believe we should \
         consider a completely different approach to solving it"),
    ];

    println!("┌────────────┬────────────┬────────────┬────────────┐");
    println!("│ TTS        │ first_chunk│ total      │ RTF        │");
    println!("├────────────┼────────────┼────────────┼────────────┤");

    for (label, text) in &texts {
        let mut samples_total = 0usize;
        let (fc_ms, total_ms) = tts.generate_stream(text, |chunk| {
            samples_total += chunk.len();
        })?;
        let audio_sec = samples_total as f64 / tts.sample_rate() as f64;
        let rtf = if audio_sec > 0.0 { (total_ms as f64 / 1000.0) / audio_sec } else { 0.0 };
        println!("│ {:<10} │ {:>7}ms  │ {:>7}ms  │ {:>8.2}x  │", label, fc_ms, total_ms, rtf);
    }
    println!("└────────────┴────────────┴────────────┴────────────┘");
    println!("  RTF < 1.0 = faster than real-time\n");

    // ── Translation benchmark ──
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build()?;

    let translator = talkye_core::translate::Translator::new(&config.translate);
    let ro_texts = [
        ("short", "Bună, ce faci?"),
        ("medium", "Vremea este frumoasă astăzi, hai să mergem afară în parc"),
        ("long", "Am stat și m-am gândit la problema asta destul de mult timp și cred că ar \
         trebui să luăm în considerare o abordare complet diferită pentru a o rezolva"),
    ];

    println!("┌────────────┬────────────┬──────────────────────────────────────┐");
    println!("│ Translate   │ latency    │ result                               │");
    println!("├────────────┼────────────┼──────────────────────────────────────┤");

    for (label, text) in &ro_texts {
        let t = Instant::now();
        let result = rt.block_on(translator.translate(text))?;
        let ms = t.elapsed().as_millis();
        let display: String = if result.len() > 36 {
            format!("{}...", &result[..33])
        } else {
            result.clone()
        };
        println!("│ {:<10} │ {:>7}ms  │ {:<36} │", label, ms, display);
    }
    println!("└────────────┴────────────┴──────────────────────────────────────┘\n");

    // ── End-to-end (translate + TTS) ──
    println!("┌────────────┬────────────┬────────────┬────────────┐");
    println!("│ E2E        │ translate  │ tts_first  │ total      │");
    println!("├────────────┼────────────┼────────────┼────────────┤");

    // Fresh translator to avoid context influence
    let translator2 = talkye_core::translate::Translator::new(&config.translate);
    for (label, text) in &ro_texts {
        let t_all = Instant::now();
        let translated = rt.block_on(translator2.translate(text))?;
        let translate_ms = t_all.elapsed().as_millis();

        let (fc_ms, _tts_total) = tts.generate_stream(&translated, |_| {})?;
        let total_ms = t_all.elapsed().as_millis();

        println!("│ {:<10} │ {:>7}ms  │ {:>7}ms  │ {:>7}ms  │",
            label, translate_ms, fc_ms, total_ms);
    }
    println!("└────────────┴────────────┴────────────┴────────────┘");
    println!("  E2E = translate + TTS (no STT, no audio capture)\n");

    // ── Clause splitting comparison ──
    println!("┌──────────────────────────────────────────────────────┐");
    println!("│ Clause Splitting — whole vs split                    │");
    println!("├────────────┬────────────┬────────────┬──────────────┤");
    println!("│ mode       │ first_chunk│ total      │ clauses      │");
    println!("├────────────┼────────────┼────────────┼──────────────┤");

    let long_en = "The weather is beautiful today, let's go outside and enjoy the sunshine, \
                   maybe we could visit the park near the river";

    // Whole
    let t = Instant::now();
    let mut first_ms = 0u64;
    let mut first = true;
    let _ = tts.generate_stream(long_en, |_| {
        if first { first_ms = t.elapsed().as_millis() as u64; first = false; }
    })?;
    let total = t.elapsed().as_millis();
    println!("│ whole      │ {:>7}ms  │ {:>7}ms  │ 1            │", first_ms, total);

    // Split at clauses
    let clauses = talkye_core::accumulator::split_clauses(long_en);
    let n = clauses.len();
    let t = Instant::now();
    let mut first_ms = 0u64;
    let mut first = true;
    for clause in &clauses {
        let _ = tts.generate_stream(clause, |_| {
            if first { first_ms = t.elapsed().as_millis() as u64; first = false; }
        })?;
    }
    let total = t.elapsed().as_millis();
    println!("│ split      │ {:>7}ms  │ {:>7}ms  │ {:<12} │", first_ms, total, n);

    println!("└────────────┴────────────┴────────────┴──────────────┘");
    println!("  Split clauses: {:?}", clauses);
    println!();

    Ok(())
}
