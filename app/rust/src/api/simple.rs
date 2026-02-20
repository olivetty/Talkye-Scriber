//! FFI API for Flutter — bridge between Dart UI and Talkye Core engine.

use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;

/// Ping — verifies FFI bridge works.
#[frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello from Talkye Core, {name}!")
}

/// Returns the engine version.
#[frb(sync)]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Test async function — simulates a slow operation.
pub async fn test_async(delay_ms: u32) -> String {
    tokio::time::sleep(std::time::Duration::from_millis(delay_ms as u64)).await;
    format!("Async completed after {delay_ms}ms")
}

/// Test streaming — sends events to Dart at intervals.
pub fn test_stream(
    count: u32,
    interval_ms: u32,
    sink: StreamSink<String>,
) {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        rt.block_on(async {
            for i in 0..count {
                sink.add(format!("Event {}/{count}", i + 1)).unwrap();
                tokio::time::sleep(std::time::Duration::from_millis(interval_ms as u64)).await;
            }
        });
    });
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
