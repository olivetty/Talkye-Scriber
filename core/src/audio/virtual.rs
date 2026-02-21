//! Virtual audio device management — PulseAudio/PipeWire module lifecycle.
//!
//! Creates and manages ephemeral PA modules for Google Meet integration:
//! - `talkye_out`: null-sink (TTS output target)
//! - `talkye_combined`: combine-sink (you hear + Meet reads)
//! - `talkye_mic`: virtual-source (Meet sees as microphone)
//!
//! The combine-sink is always recreated to pick up the current default speaker,
//! which fixes the Bluetooth reconnect problem.

use anyhow::{Context, Result};
use std::process::Command;

/// Ensure all virtual audio modules exist and are correctly wired.
/// Safe to call multiple times — idempotent for null-sink and virtual-source,
/// always recreates combine-sink to pick up current speaker.
pub fn ensure_virtual_audio(output_sink: &str) -> Result<()> {
    // 1. Ensure talkye_out (null-sink)
    if !sink_exists("talkye_out") {
        tracing::info!("[VIRTUAL] creating talkye_out null-sink");
        pactl(&[
            "load-module", "module-null-sink",
            "sink_name=talkye_out",
            "sink_properties=device.description=Talkye_Output",
        ])?;
    } else {
        tracing::info!("[VIRTUAL] talkye_out already exists");
    }

    // 2. Always recreate combine-sink (fixes Bluetooth reconnect)
    if output_sink == "talkye_combined" {
        let default_speaker = find_default_speaker();
        tracing::info!("[VIRTUAL] default speaker: {default_speaker}");

        // Remove old combine-sink if it exists
        if let Some(module_id) = find_module_id("module-combine-sink", "talkye_combined") {
            tracing::info!("[VIRTUAL] removing old talkye_combined (module {module_id})");
            let _ = pactl(&["unload-module", &module_id]);
            // Small delay for PipeWire to clean up
            std::thread::sleep(std::time::Duration::from_millis(200));
        }

        let slaves = format!("{default_speaker},talkye_out");
        tracing::info!("[VIRTUAL] creating talkye_combined with slaves={slaves}");
        pactl(&[
            "load-module", "module-combine-sink",
            "sink_name=talkye_combined",
            &format!("slaves={slaves}"),
        ])?;
    }

    // 3. Ensure talkye_mic (virtual-source)
    if !source_exists("talkye_mic") {
        tracing::info!("[VIRTUAL] creating talkye_mic virtual-source");
        pactl(&[
            "load-module", "module-virtual-source",
            "source_name=talkye_mic",
            "master=talkye_out.monitor",
            "source_properties=device.description=Talkye_Mic",
        ])?;
    } else {
        tracing::info!("[VIRTUAL] talkye_mic already exists");
    }

    tracing::info!("[VIRTUAL] ✅ virtual audio ready (speaker={})", find_default_speaker());
    Ok(())
}

/// Find the default/primary speaker sink name (for combine-sink slaves).
pub fn find_default_speaker() -> String {
    // Try to get the default sink from PipeWire/PulseAudio
    if let Ok(output) = Command::new("pactl").args(["get-default-sink"]).output() {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        // Don't use our own sinks as the "default speaker"
        if !name.is_empty() && !name.starts_with("talkye_") {
            return name;
        }
    }

    // Fallback: find first non-talkye, non-HDMI sink
    if let Ok(output) = Command::new("pactl").args(["list", "short", "sinks"]).output() {
        let out = String::from_utf8_lossy(&output.stdout);
        for line in out.lines() {
            let name = line.split_whitespace().nth(1).unwrap_or("");
            if !name.starts_with("talkye_") && !name.contains("hdmi") {
                return name.to_string();
            }
        }
    }

    // Last resort
    "alsa_output.default".to_string()
}

fn sink_exists(name: &str) -> bool {
    Command::new("pactl")
        .args(["list", "short", "sinks"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().any(|l| l.contains(name)))
        .unwrap_or(false)
}

fn source_exists(name: &str) -> bool {
    Command::new("pactl")
        .args(["list", "short", "sources"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().any(|l| l.contains(name)))
        .unwrap_or(false)
}

/// Find the PA module ID for a given module type + sink name.
fn find_module_id(module_type: &str, sink_name: &str) -> Option<String> {
    let output = Command::new("pactl")
        .args(["list", "short", "modules"])
        .output()
        .ok()?;
    let out = String::from_utf8_lossy(&output.stdout);
    for line in out.lines() {
        if line.contains(module_type) && line.contains(sink_name) {
            return line.split_whitespace().next().map(|s| s.to_string());
        }
    }
    None
}

fn pactl(args: &[&str]) -> Result<()> {
    let output = Command::new("pactl")
        .args(args)
        .output()
        .context("pactl not found — is PulseAudio/PipeWire installed?")?;

    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("pactl {} failed: {}", args.join(" "), err.trim());
    }
    Ok(())
}
/// Audio health watchdog — monitors default speaker changes mid-session.
///
/// Runs in a loop every 5s. If the default speaker changes (e.g. Bluetooth
/// reconnect), recreates the combine-sink automatically. Exits when `running`
/// becomes false.
///
/// Call from a `spawn_blocking` task in the pipeline.
pub fn watch_audio_health(
    output_sink: &str,
    running: &std::sync::atomic::AtomicBool,
) {
    use std::sync::atomic::Ordering;

    if output_sink != "talkye_combined" {
        tracing::info!("[VIRTUAL] watchdog skipped (output is not talkye_combined)");
        return;
    }

    let mut last_speaker = find_default_speaker();
    tracing::info!("[VIRTUAL] 👁️ watchdog started (tracking speaker: {last_speaker})");

    loop {
        std::thread::sleep(std::time::Duration::from_secs(5));

        if !running.load(Ordering::Relaxed) {
            tracing::info!("[VIRTUAL] 👁️ watchdog exiting (engine stopped)");
            break;
        }

        let current = find_default_speaker();

        // Speaker changed — Bluetooth reconnected or user switched output
        if current != last_speaker {
            tracing::warn!(
                "[VIRTUAL] 👁️ speaker changed: {last_speaker} → {current} — recreating combine-sink"
            );

            // Destroy old combine-sink
            if let Some(module_id) = find_module_id("module-combine-sink", "talkye_combined") {
                let _ = pactl(&["unload-module", &module_id]);
                std::thread::sleep(std::time::Duration::from_millis(200));
            }

            // Create new one with updated slave
            let slaves = format!("{current},talkye_out");
            match pactl(&[
                "load-module", "module-combine-sink",
                "sink_name=talkye_combined",
                &format!("slaves={slaves}"),
            ]) {
                Ok(()) => {
                    tracing::info!("[VIRTUAL] 👁️ ✅ combine-sink recreated (slaves={slaves})");
                    last_speaker = current;
                }
                Err(e) => {
                    tracing::error!("[VIRTUAL] 👁️ ❌ combine-sink recreation failed: {e:#}");
                }
            }
        }

        // Also check if combine-sink disappeared entirely (PipeWire restart, etc.)
        if !sink_exists("talkye_combined") {
            tracing::warn!("[VIRTUAL] 👁️ talkye_combined disappeared — full rebuild");
            if let Err(e) = ensure_virtual_audio("talkye_combined") {
                tracing::error!("[VIRTUAL] 👁️ rebuild failed: {e:#}");
            }
            last_speaker = find_default_speaker();
        }
    }
}
