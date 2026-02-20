use anyhow::Result;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env from project root — uses compile-time path, works regardless of cwd
    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    dotenvy::from_path(project_root.join(".env")).ok();

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::from_default_env()
                .add_directive("ort=warn".parse().unwrap())
                .add_directive("hf_hub=warn".parse().unwrap())
        )
        .init();

    tracing::info!("Talkye Meet — starting translation engine");

    let config = talkye_core::Config::from_env()?;

    // CLI mode: create a simple event channel and log events
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(64);
    let running = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));

    // Log engine events in background
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            match &event {
                talkye_core::EngineEvent::Transcript { original, translated } => {
                    tracing::info!("[EVENT] 🎤 {original}");
                    tracing::info!("[EVENT] 🔊 {translated}");
                }
                talkye_core::EngineEvent::StatusChanged { status } => {
                    tracing::info!("[EVENT] status → {status:?}");
                }
                talkye_core::EngineEvent::Error { message } => {
                    tracing::warn!("[EVENT] error: {message}");
                }
            }
        }
    });

    let pipeline = talkye_core::Pipeline::new(config, event_tx, running);
    pipeline.run().await?;

    Ok(())
}
