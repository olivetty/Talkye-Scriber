---
inclusion: auto
---

# Coding Standards — Talkye Scriber

## Language & Project

- Flutter desktop app in `app/`, Python sidecar in `sidecar/`
- User communicates in Romanian, respond in Romanian
- User works exclusively with AI agents — code must be self-documenting

## File Rules

- Max 300 lines per file. Split if larger.
- One responsibility per file. If you can't describe it in one sentence, split it.
- File names: snake_case, descriptive

## Python Conventions (Sidecar)

- Logging: `logging` module, levels: info (normal flow), warning (recoverable), error (failures)
- Config: all settings in `config.py`. Other modules import from config.
- No crashes on missing API keys — log warning and degrade gracefully.

## Flutter UI Rules

- Dark mode only. No light theme support.
- Single-screen layout — no sidebar, no multi-page navigation.
- Accent color: purple/violet (`C.accent`). Green only for status indicators.
- Action buttons: `TextButton` with solid fill — no outlines, no borders, no icons. Text only, colored by intent (purple=action, red=destructive, muted=cancel).
- No outlines/borders on ANY element. Differentiate by elevation (background shade).
- Interactive containers must have hover state via `MouseRegion` + `AnimatedContainer`.
- Color system: use `C` class from `theme.dart`. Elevation: `C.level1` through `C.level4`.
- Glass effect via `BackdropFilter` for overlays.
