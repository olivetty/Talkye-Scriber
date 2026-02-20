//! Audio I/O — capture, playback, and virtual device management.

pub mod capture;
pub mod playback;

/// Raw PCM audio chunk (16-bit, 16kHz, mono).
pub type AudioChunk = Vec<u8>;
