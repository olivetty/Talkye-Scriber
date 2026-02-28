---
inclusion: auto
---

# Design System — Talkye Meet

## Theme

Dark mode only. No light theme.

## Accent Color

Green — brand color throughout the entire app.
- Primary: `#4ADE80` (green-400)
- Light: `#86EFAC` (green-300) — hover, active indicators
- Dark: `#22C55E` (green-500) — pressed states

Purple is no longer used as accent.

## Elevation System

Differentiate layers by background shade, NOT by borders/outlines.
No `Border.all()` on cards, containers, or interactive elements.

```
Base (0dp):    #1E1F22  — scaffold background
Level 1 (1dp): #252629  — sidebar, base cards
Level 2 (3dp): #2C2D32  — elevated cards, hover states
Level 3 (6dp): #323438  — active states, dialogs, modals
Level 4 (8dp): #393C41  — tooltips, popovers, dropdowns
```

## No Outlines

Zero outlines, zero thin borders on ANY element:
- Cards: elevation only (background color difference)
- Buttons: solid fill only
- Inputs: solid fill, focus indicated by accent glow or background change
- Containers: no border, differentiate by elevation

## Buttons

All buttons are solid fill, no outline, no icons on primary actions.
- Primary action: purple fill (`accent.withAlpha(30)`), purple text
- Destructive: red fill, red text
- Secondary/Cancel: level2 fill, textSub color
- Rounded corners: 10-12px
- No `ElevatedButton` with borders. Use `TextButton` with solid background.

## Glass Effect

Use `BackdropFilter` + `ImageFilter.blur(sigmaX: 20, sigmaY: 20)` for:
- Sidebar background
- Dialog overlays
- Any floating/overlay element

Glass container pattern:
```dart
ClipRRect(
  borderRadius: BorderRadius.circular(r),
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
    child: Container(
      color: C.glass, // base color at 60-70% opacity
      child: content,
    ),
  ),
)
```

## Text

- Primary: `#E8E8ED` — headings, body text
- Secondary: `#9898A8` — descriptions, labels
- Muted: `#5A5A6E` — disabled, hints, timestamps

## Status Colors

- Listening/Active: `#4ADE80` (green) — status only, not accent
- Translating/Warning: `#F59E0B` (amber)
- Speaking/Info: `#60A5FA` (blue)
- Error: `#EF4444` (red)
- Loading: `#F97316` (orange)

## Interactive Elements

- All clickable containers must have hover state via `MouseRegion`
- Hover: background shifts one elevation level up
- Active/Selected: accent color at low opacity + accent indicator
- Transitions: 150ms for hover, 200ms for state changes

## Spacing

- Screen padding: 24px
- Card padding: 16px
- Between sections: 24px
- Between items: 8-12px
