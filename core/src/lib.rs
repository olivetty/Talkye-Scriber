//! Talkye Core — real-time voice translation engine.
//!
//! Pipeline: Audio Capture → Deepgram STT → LLM Translate → Pocket TTS → Playback

pub mod accumulator;
pub mod audio;
pub mod config;
pub mod engine;
pub mod pipeline;
pub mod stt;
pub mod translate;
pub mod tts;
pub mod vad;

pub use config::Config;
pub use engine::{Engine, EngineEvent, EngineStatus, AudioDevice, ModelStatus};
pub use pipeline::Pipeline;
