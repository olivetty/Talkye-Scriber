# Cost Analysis — Talkye Meet

## Product Model

Talkye Meet = downloadable app (Mac + Linux), $20/month subscription.
Pipeline: local STT → cloud Translation → local TTS.

## Architecture Cost Breakdown

| Component | Where | Cost per user |
|---|---|---|
| STT | Local (whisper/parakeet) | $0 |
| Translation | Cloud (Groq via proxy) | ~$0.02/hour |
| TTS | Local (pocket-tts) | $0 |
| Auth + proxy | Our server | minimal |

## Per-User Cost (our cost to serve)

| Usage | Hours/month | Groq cost | Revenue | Margin |
|---|---|---|---|---|
| Light (1h/day) | 30 | $0.60 | $20 | 97% |
| Medium (2h/day) | 40 | $0.80 | $20 | 96% |
| Heavy (4h/day) | 80 | $1.60 | $20 | 92% |
| Power (8h/day) | 160 | $3.20 | $20 | 84% |

Groq Llama 3.3 70B: $0.59/M input + $0.79/M output tokens.
~240 requests/hour × ~100 input tokens + ~20 output tokens = ~$0.02/hour.

## Comparison: Cloud STT vs Local STT

| | Deepgram (cloud) | Local (whisper/parakeet) |
|---|---|---|
| Cost | $0.26/hour | $0 |
| Latency | ~300-500ms | ~1-3s (chunk-based) |
| Internet | Required | Not required |
| Privacy | Audio goes to cloud | Audio stays on device |
| Quality (RO) | Excellent (Nova-3) | Excellent (Whisper large-v3) |
| Streaming | Native word-by-word | Chunk-based (2-3s windows) |
| User setup | None (we proxy) | None (bundled in app) |

Decision: local STT for the product (zero recurring cost, privacy, offline).
Deepgram kept as dev/testing backend via `STT_BACKEND=deepgram|whisper`.

## Why Local STT Wins for a Downloadable App

1. No per-user STT cost — Deepgram at scale would be $0.26/hour × users = unsustainable
2. Privacy — audio never leaves the device (strong selling point)
3. Offline — works without internet (except translation)
4. No API key management for users
5. 2-3s extra latency is acceptable (human interpreters: 3-5s delay)

## Translation Cost at Scale

| Users | Avg hours/month | Monthly Groq cost | Monthly revenue |
|---|---|---|---|
| 100 | 40 | $80 | $2,000 |
| 1,000 | 40 | $800 | $20,000 |
| 10,000 | 40 | $8,000 | $200,000 |

Groq cost stays under 5% of revenue at any scale.

## Free Tiers (Development)

| Service | Free Tier |
|---|---|
| Deepgram | $200 credit ≈ 433 hours (dev/testing) |
| Groq | Free tier with rate limits |
| Pocket TTS | Unlimited (local, open-source) |
| Whisper/Parakeet | Unlimited (local, open-source) |

Content was rephrased for compliance with licensing restrictions.
Sources: [Deepgram pricing](https://deepgram.com/pricing), [Groq pricing](https://groq.com/pricing)
