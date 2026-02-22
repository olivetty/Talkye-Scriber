//! Rustpotter-based wake word detection binary for Talkye.
//!
//! Modes:
//!   spot <rpw_path> [threshold]  — Live detection, outputs JSON lines to stdout
//!   build <name> <samples_dir> <output_rpw> [mfcc_size]  — Build .rpw from wav samples
//!   record-sample <output_wav> [duration_secs]  — Record a single wav sample via parecord
//!
//! The `spot` mode is designed to be spawned by the Python sidecar.
//! Each detection is printed as a JSON line:
//!   {"event":"detected","name":"hey_mira","score":0.612,"avg_score":0.0,"counter":22}

use rustpotter::{
    Rustpotter, RustpotterConfig, SampleFormat,
    WakewordRef, WakewordRefBuildFromFiles, WakewordSave,
};
use std::env;
use std::io::{Read, Write};
use std::process::{Command, Stdio};

fn get_default_source() -> Option<String> {
    let output = Command::new("pactl")
        .args(["get-default-source"])
        .output()
        .ok()?;
    if output.status.success() {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !name.is_empty() { return Some(name); }
    }
    None
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage:");
        eprintln!("  wakeword spot <rpw> [threshold]");
        eprintln!("  wakeword build <name> <samples_dir> <output.rpw> [mfcc]");
        eprintln!("  wakeword record-sample <output.wav> [duration_secs]");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "spot" => cmd_spot(&args[2..]),
        "build" => cmd_build(&args[2..]),
        "record-sample" => cmd_record_sample(&args[2..]),
        other => { eprintln!("Unknown: {}", other); std::process::exit(1); }
    }
}

fn cmd_spot(args: &[String]) {
    let rpw_path = args.first().unwrap_or_else(|| {
        eprintln!("Usage: wakeword spot <rpw_path> [threshold]");
        std::process::exit(1);
    });
    let threshold: f32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0.58);

    if !std::path::Path::new(rpw_path).exists() {
        eprintln!("File not found: {}", rpw_path);
        std::process::exit(1);
    }

    let source = get_default_source();

    let mut config = RustpotterConfig::default();
    config.fmt.sample_rate = 16000;
    config.fmt.sample_format = SampleFormat::I16;
    config.fmt.channels = 1;
    config.detector.threshold = threshold;
    config.detector.avg_threshold = 0.0;
    config.detector.min_scores = 2;
    config.detector.score_mode = rustpotter::ScoreMode::Max;
    config.filters.gain_normalizer.enabled = true;
    config.filters.gain_normalizer.min_gain = 0.1;
    config.filters.gain_normalizer.max_gain = 1.0;

    let mut detector = Rustpotter::new(&config).unwrap();
    detector
        .add_wakeword_from_file("wakeword", rpw_path)
        .expect("Failed to load wakeword");

    let bytes_per_frame = detector.get_bytes_per_frame();

    // Signal ready to parent process
    println!("{{\"event\":\"ready\",\"frame_bytes\":{},\"threshold\":{}}}", bytes_per_frame, threshold);
    let _ = std::io::stdout().flush();

    // Start parecord with stdout pipe for lowest latency
    let mut parec_args = vec![
        "--format=s16le", "--rate=16000", "--channels=1", "--raw",
        "--latency-msec=10",
    ];
    let source_str;
    if let Some(ref src) = source {
        parec_args.push("-d");
        source_str = src.clone();
        parec_args.push(&source_str);
    }
    parec_args.push("/dev/stdout");

    let mut mic = Command::new("parecord")
        .args(&parec_args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("Failed to start parecord");

    let mut reader = std::io::BufReader::with_capacity(bytes_per_frame * 2, mic.stdout.take().unwrap());
    let mut buf = vec![0u8; bytes_per_frame];

    loop {
        if mic.try_wait().ok().flatten().is_some() { break; }
        match reader.read_exact(&mut buf) {
            Ok(()) => {
                if let Some(det) = detector.process_bytes(&buf) {
                    println!(
                        "{{\"event\":\"detected\",\"name\":\"{}\",\"score\":{:.3},\"avg_score\":{:.3},\"counter\":{}}}",
                        det.name, det.score, det.avg_score, det.counter
                    );
                    let _ = std::io::stdout().flush();
                }
            }
            Err(_) => break,
        }
    }

    let _ = mic.kill();
}

fn cmd_build(args: &[String]) {
    if args.len() < 3 {
        eprintln!("Usage: wakeword build <name> <samples_dir> <output.rpw> [mfcc_size]");
        std::process::exit(1);
    }
    let name = &args[0];
    let samples_dir = &args[1];
    let output = &args[2];
    let mfcc_size: u16 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(10);

    let mut samples: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(samples_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map(|e| e == "wav").unwrap_or(false) {
                samples.push(path.to_string_lossy().to_string());
            }
        }
    }
    samples.sort();

    if samples.is_empty() {
        eprintln!("{{\"event\":\"error\",\"message\":\"No .wav samples in {}\"}}", samples_dir);
        std::process::exit(1);
    }

    let wakeword = WakewordRef::new_from_sample_files(
        name.to_string(), None, None, samples.clone(), mfcc_size,
    ).unwrap_or_else(|e| {
        eprintln!("{{\"event\":\"error\",\"message\":\"{}\"}}", e);
        std::process::exit(1);
    });

    wakeword.save_to_file(output).unwrap_or_else(|e| {
        eprintln!("{{\"event\":\"error\",\"message\":\"{}\"}}", e);
        std::process::exit(1);
    });

    println!(
        "{{\"event\":\"built\",\"name\":\"{}\",\"samples\":{},\"output\":\"{}\"}}",
        name, samples.len(), output
    );
}

fn cmd_record_sample(args: &[String]) {
    let output = args.first().unwrap_or_else(|| {
        eprintln!("Usage: wakeword record-sample <output.wav> [duration_secs]");
        std::process::exit(1);
    });
    let duration: u32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(3);

    let raw_path = format!("{}.raw", output);
    // Use same audio source as spot command for consistent training/detection audio
    let source = get_default_source();
    let mut rec_args = vec![
        format!("{}s", duration),
        "parecord".to_string(),
        "--format=s16le".to_string(),
        "--rate=16000".to_string(),
        "--channels=1".to_string(),
        "--raw".to_string(),
    ];
    if let Some(ref src) = source {
        rec_args.push("-d".to_string());
        rec_args.push(src.clone());
    }
    rec_args.push(raw_path.clone());
    let status = Command::new("timeout")
        .args(&rec_args)
        .status()
        .expect("parecord failed");

    if !status.success() && !status.code().map_or(false, |c| c == 124) {
        eprintln!("{{\"event\":\"error\",\"message\":\"parecord failed\"}}");
        std::process::exit(1);
    }

    let sox = Command::new("sox")
        .args(["-r", "16000", "-e", "signed", "-b", "16", "-c", "1",
               "-t", "raw", &raw_path, output.as_str()])
        .status()
        .expect("sox failed");

    let _ = std::fs::remove_file(&raw_path);

    if !sox.success() {
        eprintln!("{{\"event\":\"error\",\"message\":\"sox conversion failed\"}}");
        std::process::exit(1);
    }

    println!("{{\"event\":\"recorded\",\"path\":\"{}\",\"duration\":{}}}", output, duration);
}
