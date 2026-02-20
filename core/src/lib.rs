//! Talkye Core — real-time voice translation engine.
//!
//! Pipeline: Audio Capture → Deepgram STT → LLM Translate → Pocket TTS → Playback

pub mod audio;
pub mod config;
pub mod pipeline;
pub mod stt;
pub mod translate;
pub mod tts;

pub use config::Config;
pub use pipeline::Pipeline;
