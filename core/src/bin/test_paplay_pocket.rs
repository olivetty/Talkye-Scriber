//! Quick test: Pocket TTS → paplay playback.
//! Usage: cargo run --release --bin test_paplay_pocket

use anyhow::Result;

fn main() -> Result<()> {
    let config = talkye_core::config::TtsConfig {
        voice: String::new(), // default voice
        speed: 1.0,
        output_device: None,
        language: "English".to_string(),
    };

    println!("Loading Pocket TTS...");
    let tts = talkye_core::tts::create_backend(&config)?;
    println!("Loaded (sr={})", tts.sample_rate());

    let text = "Hello, this is a test of Pocket TTS playing through paplay. The audio should sound clean and clear.";
    println!("Generating: \"{text}\"");

    let mut all_pcm: Vec<u8> = Vec::new();
    let mut total_samples = 0usize;

    let (fc, tot) = tts.generate_stream(text, "English", &mut |chunk| {
        total_samples += chunk.len();
        for &s in chunk {
            let val = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
            all_pcm.extend_from_slice(&val.to_le_bytes());
        }
    })?;

    let dur_ms = total_samples * 1000 / tts.playback_rate() as usize;
    println!("Generated: {total_samples} samples ({dur_ms}ms), fc={fc}ms tot={tot}ms");

    // Play via paplay
    println!("Playing via paplay...");
    let sr = tts.playback_rate().to_string();
    let mut child = std::process::Command::new("paplay")
        .args(["--format=s16le", &format!("--rate={sr}"), "--channels=1", "--raw"])
        .stdin(std::process::Stdio::piped())
        .spawn()?;

    if let Some(ref mut stdin) = child.stdin {
        use std::io::Write;
        stdin.write_all(&all_pcm)?;
    }
    child.stdin.take(); // EOF
    child.wait()?;
    println!("Done.");

    Ok(())
}
