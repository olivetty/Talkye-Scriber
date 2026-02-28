import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

/// evdev name → human label for allowed trigger keys
final _allowedEvdev = <String, String>{
  'KEY_RIGHTCTRL': 'Right Ctrl',
  'KEY_RIGHTALT': 'Right Alt',
  'KEY_RIGHTSHIFT': 'Right Shift',
  'KEY_INSERT': 'Insert',
  'KEY_SCROLLLOCK': 'Scroll Lock',
  'KEY_PAUSE': 'Pause',
  'KEY_NUMLOCK': 'Num Lock',
  for (var i = 1; i <= 24; i++) 'KEY_F$i': 'F$i',
};

String labelForEvdev(String evdev) =>
    _allowedEvdev[evdev] ?? evdev.replaceAll('KEY_', '').replaceAll('_', ' ');

/// Physical key → evdev name mapping (for keyboard capture)
final _physicalToEvdev = <PhysicalKeyboardKey, String>{
  PhysicalKeyboardKey.controlRight: 'KEY_RIGHTCTRL',
  PhysicalKeyboardKey.altRight: 'KEY_RIGHTALT',
  PhysicalKeyboardKey.shiftRight: 'KEY_RIGHTSHIFT',
  PhysicalKeyboardKey.insert: 'KEY_INSERT',
  PhysicalKeyboardKey.scrollLock: 'KEY_SCROLLLOCK',
  PhysicalKeyboardKey.pause: 'KEY_PAUSE',
  PhysicalKeyboardKey.numLock: 'KEY_NUMLOCK',
  PhysicalKeyboardKey.f1: 'KEY_F1',
  PhysicalKeyboardKey.f2: 'KEY_F2',
  PhysicalKeyboardKey.f3: 'KEY_F3',
  PhysicalKeyboardKey.f4: 'KEY_F4',
  PhysicalKeyboardKey.f5: 'KEY_F5',
  PhysicalKeyboardKey.f6: 'KEY_F6',
  PhysicalKeyboardKey.f7: 'KEY_F7',
  PhysicalKeyboardKey.f8: 'KEY_F8',
  PhysicalKeyboardKey.f9: 'KEY_F9',
  PhysicalKeyboardKey.f10: 'KEY_F10',
  PhysicalKeyboardKey.f11: 'KEY_F11',
  PhysicalKeyboardKey.f12: 'KEY_F12',
  PhysicalKeyboardKey.f13: 'KEY_F13',
  PhysicalKeyboardKey.f14: 'KEY_F14',
  PhysicalKeyboardKey.f15: 'KEY_F15',
  PhysicalKeyboardKey.f16: 'KEY_F16',
  PhysicalKeyboardKey.f17: 'KEY_F17',
  PhysicalKeyboardKey.f18: 'KEY_F18',
  PhysicalKeyboardKey.f19: 'KEY_F19',
  PhysicalKeyboardKey.f20: 'KEY_F20',
  PhysicalKeyboardKey.f21: 'KEY_F21',
  PhysicalKeyboardKey.f22: 'KEY_F22',
  PhysicalKeyboardKey.f23: 'KEY_F23',
  PhysicalKeyboardKey.f24: 'KEY_F24',
};

// ── Keyboard layout definition ──
// Each key: (label, evdev name or '' for disabled, width multiplier)
typedef _K = (String label, String evdev, double w);

const _rowFn = <_K>[
  ('Esc', '', 1),
  ('', '', 0.5),
  ('F1', 'KEY_F1', 1),
  ('F2', 'KEY_F2', 1),
  ('F3', 'KEY_F3', 1),
  ('F4', 'KEY_F4', 1),
  ('', '', 0.25),
  ('F5', 'KEY_F5', 1),
  ('F6', 'KEY_F6', 1),
  ('F7', 'KEY_F7', 1),
  ('F8', 'KEY_F8', 1),
  ('', '', 0.25),
  ('F9', 'KEY_F9', 1),
  ('F10', 'KEY_F10', 1),
  ('F11', 'KEY_F11', 1),
  ('F12', 'KEY_F12', 1),
  ('', '', 0.25),
  ('PrtSc', '', 1),
  ('ScrLk', 'KEY_SCROLLLOCK', 1),
  ('Pause', 'KEY_PAUSE', 1),
];

const _rowNum = <_K>[
  ('`', '', 1),
  ('1', '', 1),
  ('2', '', 1),
  ('3', '', 1),
  ('4', '', 1),
  ('5', '', 1),
  ('6', '', 1),
  ('7', '', 1),
  ('8', '', 1),
  ('9', '', 1),
  ('0', '', 1),
  ('-', '', 1),
  ('=', '', 1),
  ('Bksp', '', 2),
  ('', '', 0.25),
  ('Ins', 'KEY_INSERT', 1),
  ('Home', '', 1),
  ('PgUp', '', 1),
];

const _rowQ = <_K>[
  ('Tab', '', 1.5),
  ('Q', '', 1),
  ('W', '', 1),
  ('E', '', 1),
  ('R', '', 1),
  ('T', '', 1),
  ('Y', '', 1),
  ('U', '', 1),
  ('I', '', 1),
  ('O', '', 1),
  ('P', '', 1),
  ('[', '', 1),
  (']', '', 1),
  ('\\', '', 1.5),
  ('', '', 0.25),
  ('Del', '', 1),
  ('End', '', 1),
  ('PgDn', '', 1),
];

const _rowA = <_K>[
  ('Caps', '', 1.75),
  ('A', '', 1),
  ('S', '', 1),
  ('D', '', 1),
  ('F', '', 1),
  ('G', '', 1),
  ('H', '', 1),
  ('J', '', 1),
  ('K', '', 1),
  ('L', '', 1),
  (';', '', 1),
  ("'", '', 1),
  ('Enter', '', 2.25),
];

const _rowZ = <_K>[
  ('L Shift', '', 2.25),
  ('Z', '', 1),
  ('X', '', 1),
  ('C', '', 1),
  ('V', '', 1),
  ('B', '', 1),
  ('N', '', 1),
  ('M', '', 1),
  (',', '', 1),
  ('.', '', 1),
  ('/', '', 1),
  ('R Shift', 'KEY_RIGHTSHIFT', 2.75),
  ('', '', 1.25),
  ('↑', '', 1),
];

const _rowBot = <_K>[
  ('L Ctrl', '', 1.25),
  ('Super', '', 1.25),
  ('L Alt', '', 1.25),
  ('Space', '', 6.25),
  ('R Alt', 'KEY_RIGHTALT', 1.25),
  ('Super', '', 1.25),
  ('Menu', '', 1.25),
  ('R Ctrl', 'KEY_RIGHTCTRL', 1.25),
  ('', '', 0.25),
  ('←', '', 1),
  ('↓', '', 1),
  ('→', '', 1),
];

const _allRows = [_rowFn, _rowNum, _rowQ, _rowA, _rowZ, _rowBot];

/// Full-screen dialog with a visual desktop keyboard for picking a trigger key.
class KeyPickerDialog extends StatefulWidget {
  final String currentKey;
  final ValueChanged<String> onKeySelected;
  const KeyPickerDialog({
    super.key,
    required this.currentKey,
    required this.onKeySelected,
  });
  @override
  State<KeyPickerDialog> createState() => _KeyPickerDialogState();
}

class _KeyPickerDialogState extends State<KeyPickerDialog>
    with SingleTickerProviderStateMixin {
  String? _selected;
  String? _pressed; // physically pressed key (momentary highlight)
  String? _rejected; // rejected key label for error message
  final _focus = FocusNode();
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _glow.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onPhysicalKey(KeyEvent event) {
    if (event is! KeyDownEvent) {
      // On key up, clear the pressed highlight
      if (event is KeyUpEvent) setState(() => _pressed = null);
      return;
    }
    final evdev = _physicalToEvdev[event.physicalKey];
    if (evdev != null) {
      setState(() {
        _selected = evdev;
        _pressed = evdev;
        _rejected = null;
      });
    } else {
      final name = event.logicalKey.keyLabel.isNotEmpty
          ? event.logicalKey.keyLabel
          : event.physicalKey.debugName ?? '?';
      setState(() {
        _pressed = null;
        _rejected = name;
      });
    }
  }

  void _onKeyTap(String evdev) {
    setState(() {
      _selected = evdev;
      _rejected = null;
    });
  }

  void _confirm() {
    if (_selected != null) {
      widget.onKeySelected(_selected!);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: KeyboardListener(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onPhysicalKey,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          color: C.bg.withAlpha(230),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // absorb taps on keyboard area
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  const Text(
                    'Choose trigger key',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: C.text,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _rejected != null
                        ? '"$_rejected" can\'t be used as trigger'
                        : _selected != null
                        ? '${labelForEvdev(_selected!)} selected'
                        : 'Press a key or click on it',
                    style: TextStyle(
                      fontSize: 12,
                      color: _rejected != null
                          ? C.error
                          : (_selected != null ? C.accent : C.textSub),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Keyboard
                  _buildKeyboard(),

                  const SizedBox(height: 10),
                  Text(
                    'Only highlighted keys can be used as trigger',
                    style: TextStyle(
                      fontSize: 10,
                      color: C.textMuted.withAlpha(120),
                    ),
                  ),

                  const SizedBox(height: 24),
                  // Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _btn(
                        'Cancel',
                        C.level3,
                        C.textSub,
                        () => Navigator.of(context).pop(),
                      ),
                      if (_selected != null) ...[
                        const SizedBox(width: 12),
                        _btn(
                          'Confirm',
                          C.accent.withAlpha(30),
                          C.accent,
                          _confirm,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _btn(String text, Color bg, Color fg, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyboard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _allRows.length; i++) ...[
          if (i == 1) const SizedBox(height: 8), // gap after F-row
          _buildRow(_allRows[i]),
          const SizedBox(height: 3),
        ],
      ],
    );
  }

  Widget _buildRow(List<_K> keys) {
    const keySize = 38.0;
    const gap = 3.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0 && keys[i].$3 > 0) const SizedBox(width: gap),
          _buildKey(keys[i], keySize),
        ],
      ],
    );
  }

  Widget _buildKey(_K k, double unit) {
    final label = k.$1;
    final evdev = k.$2;
    final w = k.$3;

    if (w == 0) return const SizedBox.shrink();

    // Spacer (empty label, no evdev)
    if (label.isEmpty && evdev.isEmpty) {
      return SizedBox(width: unit * w);
    }

    final isAllowed = evdev.isNotEmpty && _allowedEvdev.containsKey(evdev);
    final isSelected = _selected == evdev;
    final isCurrent = widget.currentKey == evdev;
    final isPressed = _pressed == evdev;

    // Colors
    Color bg;
    Color fg;
    if (isSelected) {
      bg = C.accent.withAlpha(60);
      fg = C.accent;
    } else if (isPressed && isAllowed) {
      bg = C.accent.withAlpha(40);
      fg = C.accentLight;
    } else if (isCurrent) {
      bg = C.accent.withAlpha(20);
      fg = C.accent.withAlpha(180);
    } else if (isAllowed) {
      bg = C.level2;
      fg = C.text;
    } else {
      bg = C.level1.withAlpha(100);
      fg = C.textMuted;
    }

    final keyW = unit * w + (w > 1 ? (w - 1) * 3 : 0);

    Widget key = _AnimGlow(
      glow: _glow,
      isSelected: isSelected,
      bg: bg,
      fg: fg,
      label: label,
      keyW: keyW,
      unit: unit,
      w: w,
    );

    if (isAllowed) {
      key = GestureDetector(
        onTap: () => _onKeyTap(evdev),
        child: MouseRegion(cursor: SystemMouseCursors.click, child: key),
      );
    }

    return key;
  }
}

/// Single key with animated glow when selected.
class _AnimGlow extends AnimatedWidget {
  final bool isSelected;
  final Color bg, fg;
  final String label;
  final double keyW, unit, w;

  const _AnimGlow({
    required Animation<double> glow,
    required this.isSelected,
    required this.bg,
    required this.fg,
    required this.label,
    required this.keyW,
    required this.unit,
    required this.w,
  }) : super(listenable: glow);

  @override
  Widget build(BuildContext context) {
    final anim = listenable as Animation<double>;
    final glowOpacity = isSelected ? (anim.value * 0.3 + 0.1) : 0.0;
    return Container(
      width: keyW,
      height: unit,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        boxShadow: glowOpacity > 0
            ? [
                BoxShadow(
                  color: C.accent.withAlpha((glowOpacity * 255).round()),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: w > 1.5 ? 9 : 10,
            fontWeight: FontWeight.w500,
            color: fg,
          ),
          overflow: TextOverflow.clip,
          maxLines: 1,
        ),
      ),
    );
  }
}
