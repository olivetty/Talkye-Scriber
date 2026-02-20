# Cost Analysis

What does it cost to run the Dictate pipeline? Here's a breakdown per component.

Sources: [Deepgram pricing](https://deepgram.com/pricing), [Groq pricing](https://groq.com/pricing), Pocket TTS is open-source (MIT, free).

## Per-Component Pricing

| Component | Service | Price | Notes |
|---|---|---|---|
| STT (streaming) | Deepgram Nova-3 Mono | $0.0077/min | Pay-as-you-go. Growth plan: $0.0065/min |
| STT (streaming) | Deepgram Nova-3 Multi | $0.0092/min | Multilingual mode |
| Translation LLM | Groq Llama 3.3 70B | $0.59/M input + $0.79/M output tokens | ~150-300ms per request |
| TTS | Pocket TTS (local) | **$0.00** | Open-source, CPU-only, runs locally |
| STT (desktop) | Groq Whisper Large v3 Turbo | $0.04/hour | Used by desktop.py |

## Scenario: Live Translation (test_deepgram.py)

One person speaking continuously for 1 hour:

| Component | Calculation | Cost/hour |
|---|---|---|
| Deepgram STT | 60 min × $0.0077 | $0.46 |
| Groq Translation | ~600 requests × ~100 input tokens × ~50 output tokens | ~$0.06 |
| Pocket TTS | Local | $0.00 |
| **Total** | | **~$0.52/hour** |

Assumptions: ~10 translation requests/min (one every 6 seconds), average 100 input tokens (prompt + context + text), 50 output tokens per translation.

## Scenario: Desktop Dictation (desktop.py)

Occasional dictation, ~5 minutes of actual speech per hour:

| Component | Calculation | Cost/hour |
|---|---|---|
| Groq Whisper | 5 min = 0.083 hr × $0.04 | $0.003 |
| LLM Cleanup (optional) | ~50 requests × ~200 tokens | ~$0.01 |
| **Total** | | **~$0.01/hour** |

Desktop dictation is essentially free on Groq's free tier ($200 credit = ~5000 hours of dictation).

## Scenario: Video Call Translation (future product)

4-person meeting, 1 hour, everyone speaks ~25% of the time:

| Component | Calculation | Cost/hour |
|---|---|---|
| Deepgram STT × 4 | 4 × 60 min × $0.0077 | $1.85 |
| Groq Translation × 4 | 4 × ~600 req × ~150 tokens | ~$0.24 |
| Pocket TTS × 4 | Local per client | $0.00 |
| **Total** | | **~$2.09/meeting** |

At scale with Growth plan pricing: ~$1.75/meeting.

## Free Tiers & Credits

| Service | Free Tier |
|---|---|
| Deepgram | $200 credit (no expiration) ≈ 26,000 min of Nova-3 ≈ **433 hours** |
| Groq | Free tier with rate limits (30 req/min for Llama 3.3 70B) |
| Pocket TTS | Unlimited (local, open-source) |

## Cost Optimization Tips

- Deepgram is the main cost driver (~90% of total)
- Groq translation is cheap because requests are small (short phrases)
- Pocket TTS is free forever — no API costs, no rate limits
- For desktop dictation, Groq Whisper free tier covers most personal use
- Growth plan ($4k/year) gives ~20% discount on Deepgram if scaling up
- Consider Deepgram Nova-3 Monolingual ($0.0077) vs Multilingual ($0.0092) — we use Mono since source language is fixed (Romanian)

## Monthly Cost Estimates

| Usage Pattern | Hours/month | Cost/month |
|---|---|---|
| Light (personal, 1h/day) | 30 | ~$16 |
| Medium (work, 4h/day) | 120 | ~$62 |
| Heavy (all day, 8h/day) | 240 | ~$125 |
| Team of 4 (meetings, 2h/day) | 60 meetings | ~$125 |

Content was rephrased for compliance with licensing restrictions.
