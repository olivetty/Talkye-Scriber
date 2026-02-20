use anyhow::Result;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env from project root (one level up from core/)
    dotenvy::from_filename("../.env").ok();
    dotenvy::dotenv().ok();

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    tracing::info!("Talkye Meet — starting translation engine");

    let pipeline = talkye_core::Pipeline::new()?;
    pipeline.run().await?;

    Ok(())
}
