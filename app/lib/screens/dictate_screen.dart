import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../main.dart';
import '../theme.dart';
import 'key_picker_dialog.dart';

const _baseUrl = 'http://127.0.0.1:8179';

const _voiceCommands = [
  ('enter', 'Press Enter'),
  ('delete', 'Delete character'),
  ('delete_word', 'Delete word'),
  ('undo', 'Undo'),
  ('redo', 'Redo'),
  ('copy', 'Copy'),
  ('paste', 'Paste'),
  ('cut', 'Cut'),
  ('select_all', 'Select all'),
  ('save', 'Save'),
  ('tab', 'Tab'),
  ('escape', 'Escape'),
  ('period', 'Insert .'),
  ('comma', 'Insert ,'),
  ('question_mark', 'Insert ?'),
];

class DictateScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<void> Function() onRestartSidecar;
  const DictateScreen({
    super.key,
    required this.settings,
    required this.onRestartSidecar,
  });
  @override
  State<DictateScreen> createState() => _DictateScreenState();
}

class _DictateScreenState extends State<DictateScreen> {
  bool _connected = false;
  bool _pttRunning = false;
  bool _recording = false;
  bool _busy = false;
  bool _commandsExpanded = false;
  String _language = 'auto';
  String _triggerKey = 'KEY_RIGHTCTRL';
  String _soundTheme = 'subtle';
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _triggerKey = widget.settings.triggerKey;
    _soundTheme = widget.settings.soundTheme;
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ── HTTP ──

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      final req = await c.getUrl(Uri.parse('$_baseUrl$path'));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      final data = await resp.transform(utf8.decoder).join();
      c.close();
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _post(String path, Map<String, dynamic> body) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      final req = await c.postUrl(Uri.parse('$_baseUrl$path'));
      req.headers.set('Content-Type', 'application/json');
      req.write(jsonEncode(body));
      await req.close().timeout(const Duration(seconds: 2));
      c.close();
    } catch (_) {}
  }

  Future<void> _poll() async {
    final health = await _get('/health');
    final ok = health != null && health['status'] == 'ok';
    if (ok) {
      if (!_connected) {
        // Sync settings on first connect
        await _post('/dictate/config', {
          'trigger_key': widget.settings.triggerKey,
          'sound_theme': widget.settings.soundTheme,
          'dictate_translate': widget.settings.dictateTranslate,
          'dictate_grammar': widget.settings.dictateGrammar,
          if (widget.settings.groqApiKey.isNotEmpty)
            'groq_api_key': widget.settings.groqApiKey,
        });
      }
      final s = await _get('/dictate/status');
      if (mounted && s != null) {
        setState(() {
          _connected = true;
          _pttRunning = s['running'] as bool? ?? false;
          _recording = s['recording'] as bool? ?? false;
          _busy = s['busy'] as bool? ?? false;
          _language = s['language'] as String? ?? 'auto';
          _triggerKey = s['trigger_key'] as String? ?? 'KEY_RIGHTCTRL';
          _soundTheme = s['sound_theme'] as String? ?? 'subtle';
          final sidecarTranslate = s['dictate_translate'] as bool? ?? false;
          if (widget.settings.dictateTranslate != sidecarTranslate) {
            widget.settings.dictateTranslate = sidecarTranslate;
          }
          final sidecarGrammar = s['dictate_grammar'] as bool? ?? false;
          if (widget.settings.dictateGrammar != sidecarGrammar) {
            widget.settings.dictateGrammar = sidecarGrammar;
          }
        });
      }
    } else {
      if (mounted) setState(() => _connected = false);
    }
  }

  Future<void> _updateConfig(Map<String, dynamic> cfg) async {
    await _post('/dictate/config', cfg);
    if (cfg.containsKey('trigger_key'))
      widget.settings.triggerKey = cfg['trigger_key'] as String;
    if (cfg.containsKey('sound_theme'))
      widget.settings.soundTheme = cfg['sound_theme'] as String;
    widget.settings.save();
    _poll();
  }

  void _showKeyPicker() {
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      useSafeArea: false,
      builder: (_) => KeyPickerDialog(
        currentKey: _triggerKey,
        onKeySelected: (evdev) {
          _updateConfig({'trigger_key': evdev});
          setState(() => _triggerKey = evdev);
        },
      ),
    );
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _header(),
              const SizedBox(height: 6),
              const Text(
                'Type anywhere with your voice. Hold a key, speak, release — text appears at your cursor.',
                style: TextStyle(fontSize: 12, color: C.textSub, height: 1.4),
              ),
              const SizedBox(height: 20),
              if (!_connected)
                _offlineBanner()
              else ...[
                _statusRow(),
                const SizedBox(height: 16),
                _pttSection(),
                const SizedBox(height: 16),
                _generalSection(),
                const SizedBox(height: 16),
                _commandsSection(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Text(
          'Scriber',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: C.text,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (_connected && _pttRunning ? C.success : C.textMuted)
                .withAlpha(20),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _connected && _pttRunning ? C.success : C.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                !_connected
                    ? 'Offline'
                    : (_pttRunning ? 'Active' : 'Starting...'),
                style: TextStyle(
                  fontSize: 11,
                  color: _connected && _pttRunning ? C.success : C.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusRow() {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _recording ? C.error : (_busy ? C.warning : C.success),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _recording ? 'Recording' : (_busy ? 'Transcribing' : 'Ready'),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: _recording ? C.error : (_busy ? C.warning : C.success),
          ),
        ),
      ],
    );
  }

  Widget _offlineBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.warning.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.power_off_rounded,
            color: C.warning.withAlpha(150),
            size: 20,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sidecar not running',
                  style: TextStyle(
                    color: C.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'The background service starts automatically with the app.\nCheck Settings → Logs if it failed.',
                  style: TextStyle(color: C.textSub, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Push to Talk section ──

  Widget _pttSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.level1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Push to Talk',
            style: TextStyle(
              color: C.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Hold a key to record, release to transcribe',
            style: TextStyle(fontSize: 11, color: C.textSub, height: 1.3),
          ),
          const SizedBox(height: 14),
          _row('Trigger Key', _triggerKeyWidget()),
        ],
      ),
    );
  }

  Widget _triggerKeyWidget() {
    return GestureDetector(
      onTap: _connected ? _showKeyPicker : null,
      child: MouseRegion(
        cursor: _connected
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: C.level2,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                labelForEvdev(_triggerKey),
                style: const TextStyle(
                  fontSize: 12,
                  color: C.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Change',
                style: TextStyle(
                  fontSize: 11,
                  color: C.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── General settings ──

  Widget _generalSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.level1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'General',
            style: TextStyle(
              color: C.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          _row('Language', _langDropdown()),
          const SizedBox(height: 12),
          _row('Sound', _soundDropdown()),
          const SizedBox(height: 12),
          _row('Translate', _translateToggle()),
          const SizedBox(height: 12),
          _row('Grammar Fix', _grammarToggle()),
        ],
      ),
    );
  }

  // ── Voice Commands ──

  Widget _commandsSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.level1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _commandsExpanded = !_commandsExpanded),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Voice Commands',
                          style: TextStyle(
                            color: C.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Say commands like "enter", "delete", "undo" in any language',
                          style: TextStyle(
                            fontSize: 11,
                            color: C.textSub,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _commandsExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: C.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_commandsExpanded) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _voiceCommands
                  .map(
                    (cmd) => Tooltip(
                      message: cmd.$2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: C.level2,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          cmd.$1,
                          style: const TextStyle(
                            fontSize: 11,
                            color: C.textSub,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ── Shared widgets ──

  Widget _row(String label, Widget child) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: C.textSub, fontSize: 12),
          ),
        ),
        child,
      ],
    );
  }

  Widget _langDropdown() {
    const langs = [
      ('auto', 'Autodetect'),
      ('ar', 'Arabic'),
      ('bg', 'Bulgarian'),
      ('ca', 'Catalan'),
      ('zh', 'Chinese'),
      ('hr', 'Croatian'),
      ('cs', 'Czech'),
      ('da', 'Danish'),
      ('nl', 'Dutch'),
      ('en', 'English'),
      ('fi', 'Finnish'),
      ('fr', 'French'),
      ('de', 'German'),
      ('el', 'Greek'),
      ('hi', 'Hindi'),
      ('hu', 'Hungarian'),
      ('id', 'Indonesian'),
      ('it', 'Italian'),
      ('ja', 'Japanese'),
      ('ko', 'Korean'),
      ('no', 'Norwegian'),
      ('pl', 'Polish'),
      ('pt', 'Portuguese'),
      ('ro', 'Romanian'),
      ('ru', 'Russian'),
      ('sr', 'Serbian'),
      ('sk', 'Slovak'),
      ('es', 'Spanish'),
      ('sv', 'Swedish'),
      ('th', 'Thai'),
      ('tr', 'Turkish'),
      ('uk', 'Ukrainian'),
      ('vi', 'Vietnamese'),
    ];
    return PopupMenuButton<String>(
      onSelected: (v) => _updateConfig({'language': v}),
      offset: const Offset(0, 32),
      color: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      constraints: const BoxConstraints(maxHeight: 400),
      itemBuilder: (_) => langs
          .map(
            (e) => PopupMenuItem(
              value: e.$1,
              height: 34,
              child: Text(
                e.$2,
                style: TextStyle(
                  fontSize: 12,
                  color: e.$1 == _language ? C.accent : C.text,
                  fontWeight: e.$1 == _language
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: C.level2,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              langs
                  .firstWhere(
                    (e) => e.$1 == _language,
                    orElse: () => langs.first,
                  )
                  .$2,
              style: const TextStyle(
                fontSize: 12,
                color: C.text,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more_rounded, size: 14, color: C.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _soundDropdown() {
    const themes = [
      ('subtle', 'Subtle'),
      ('alex', 'Alex'),
      ('luna', 'Luna'),
      ('silent', 'Silent'),
    ];
    return PopupMenuButton<String>(
      onSelected: (v) {
        _updateConfig({'sound_theme': v});
        setState(() => _soundTheme = v);
        if (v != 'silent') _post('/dictate/preview-sound', {'theme': v});
      },
      offset: const Offset(0, 32),
      color: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) => themes
          .map(
            (e) => PopupMenuItem(
              value: e.$1,
              height: 38,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.$2,
                      style: TextStyle(
                        fontSize: 12,
                        color: e.$1 == _soundTheme ? C.accent : C.text,
                        fontWeight: e.$1 == _soundTheme
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (e.$1 != 'silent')
                    GestureDetector(
                      onTap: () =>
                          _post('/dictate/preview-sound', {'theme': e.$1}),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 16,
                            color: e.$1 == _soundTheme ? C.accent : C.textMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: C.level2,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              themes
                  .firstWhere(
                    (e) => e.$1 == _soundTheme,
                    orElse: () => themes.first,
                  )
                  .$2,
              style: const TextStyle(
                fontSize: 12,
                color: C.text,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more_rounded, size: 14, color: C.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _translateToggle() {
    final on = widget.settings.dictateTranslate;
    return GestureDetector(
      onTap: _connected
          ? () {
              final v = !on;
              widget.settings.dictateTranslate = v;
              widget.settings.save();
              _post('/dictate/config', {'dictate_translate': v});
              setState(() {});
            }
          : null,
      child: MouseRegion(
        cursor: _connected
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: C.level2,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                on ? 'English' : 'Off',
                style: TextStyle(
                  fontSize: 12,
                  color: on ? C.accent : C.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.translate_rounded,
                size: 14,
                color: on ? C.accent : C.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grammarToggle() {
    final on = widget.settings.dictateGrammar;
    return GestureDetector(
      onTap: _connected
          ? () {
              final v = !on;
              widget.settings.dictateGrammar = v;
              widget.settings.save();
              _post('/dictate/config', {'dictate_grammar': v});
              setState(() {});
            }
          : null,
      child: MouseRegion(
        cursor: _connected
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: C.level2,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                on ? 'On' : 'Off',
                style: TextStyle(
                  fontSize: 12,
                  color: on ? C.accent : C.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.spellcheck_rounded,
                size: 14,
                color: on ? C.accent : C.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
