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
    let pipeline = talkye_core::Pipeline::new(config);
    pipeline.run().await?;

    Ok(())
}
