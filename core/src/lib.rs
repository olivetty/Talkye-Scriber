//! Talkye Core — real-time voice translation engine
//!
//! Pipeline: Audio Capture → Deepgram STT → LLM Translate → Pocket TTS → Audio Output

pub mod audio;
pub mod pipeline;
pub mod stt;
pub mod translate;
pub mod tts;

pub use pipeline::Pipeline;
