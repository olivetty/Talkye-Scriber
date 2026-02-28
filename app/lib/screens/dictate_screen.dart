import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _settingsExpanded = false;
  String _language = 'auto';
  String _triggerKey = 'KEY_RIGHTCTRL';
  String _soundTheme = 'subtle';
  Timer? _pollTimer;

  // Groq key
  late TextEditingController _groqCtrl;
  bool _groqObscured = true;
  bool _groqSaved = false;

  @override
  void initState() {
    super.initState();
    _triggerKey = widget.settings.triggerKey;
    _soundTheme = widget.settings.soundTheme;
    _groqCtrl = TextEditingController(text: widget.settings.groqApiKey);
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _groqCtrl.dispose();
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

  Future<void> _saveGroqKey() async {
    final key = _groqCtrl.text.trim();
    widget.settings.groqApiKey = key;
    widget.settings.save();
    await _post('/dictate/config', {'groq_api_key': key});
    setState(() => _groqSaved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _groqSaved = false);
    });
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
              const SizedBox(height: 24),
              _settingsSection(),
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

  // ── Push to Talk ──

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

  // ── General ──

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

  // ── Settings (collapsible) ──

  Widget _settingsSection() {
    return Container(
      decoration: BoxDecoration(
        color: C.level1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _settingsExpanded = !_settingsExpanded),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.settings_rounded,
                      size: 16,
                      color: C.textSub,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Settings',
                      style: TextStyle(
                        color: C.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _settingsExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: C.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_settingsExpanded) ...[
            Container(height: 1, color: C.level2),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Groq API Key
                  const Text(
                    'LLM POST-PROCESSING',
                    style: TextStyle(
                      fontSize: 10,
                      color: C.textMuted,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Groq API key for Translate and Grammar Fix.\nGet one free at groq.com/console',
                    style: TextStyle(
                      fontSize: 11,
                      color: C.textSub,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 36,
                          decoration: BoxDecoration(
                            color: C.bg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: TextField(
                            controller: _groqCtrl,
                            obscureText: _groqObscured,
                            style: const TextStyle(
                              fontSize: 12,
                              color: C.text,
                              fontFamily: 'monospace',
                            ),
                            decoration: InputDecoration(
                              hintText: 'gsk_...',
                              hintStyle: const TextStyle(
                                fontSize: 12,
                                color: C.textMuted,
                              ),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              isDense: true,
                              suffixIcon: GestureDetector(
                                onTap: () => setState(
                                  () => _groqObscured = !_groqObscured,
                                ),
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Icon(
                                    _groqObscured
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded,
                                    size: 16,
                                    color: C.textMuted,
                                  ),
                                ),
                              ),
                              suffixIconConstraints: const BoxConstraints(
                                minWidth: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _saveGroqKey,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: _groqSaved
                                  ? C.success.withAlpha(20)
                                  : C.accent.withAlpha(20),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              _groqSaved ? 'Saved' : 'Save',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _groqSaved ? C.success : C.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Audio + About
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _miniCard('AUDIO', [
                          _infoRow('Input', 'Default mic'),
                          _infoRow('Output', 'Default speaker'),
                        ]),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _miniCard('ABOUT', [
                          _infoRow('App', 'v0.3.0'),
                          _infoRow('Sidecar', 'Python/Uvicorn'),
                        ]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Debug Console
                  const Text(
                    'DIAGNOSTICS',
                    style: TextStyle(
                      fontSize: 10,
                      color: C.textMuted,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const _DebugPanel(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10,
              color: C.textMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: C.textSub),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, color: C.text),
            ),
          ),
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

// ── Debug Console Panel ──

class _DebugPanel extends StatefulWidget {
  const _DebugPanel();
  @override
  State<_DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<_DebugPanel> {
  bool _expanded = false;
  bool _autoScroll = true;
  bool _copied = false;
  String _filter = 'ALL';
  String _search = '';
  int _lastVersion = -1;
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  late final _ticker = Stream.periodic(const Duration(milliseconds: 500));
  late final _tickSub = _ticker.listen((_) {
    if (_expanded && mounted && LogBuffer.version != _lastVersion) {
      setState(() {});
    }
  });

  static const _sourceFilters = ['ALL', 'ERROR', 'WARN', 'SIDECAR'];

  @override
  void dispose() {
    _tickSub.cancel();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<LogEntry> get _filtered {
    var logs = LogBuffer.entries;
    if (_filter == 'ERROR') {
      logs = logs.where((e) => e.level == 'ERROR').toList();
    } else if (_filter == 'WARN') {
      logs = logs
          .where((e) => e.level == 'WARN' || e.level == 'ERROR')
          .toList();
    } else if (_filter != 'ALL') {
      logs = logs.where((e) => e.source == _filter).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      logs = logs.where((e) => e.message.toLowerCase().contains(q)).toList();
    }
    return logs;
  }

  void _copy() {
    Clipboard.setData(
      ClipboardData(
        text: _filtered.map((e) => '[${e.ts}] ${e.message}').join('\n'),
      ),
    );
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _export() async {
    final logs = LogBuffer.entries
        .map((e) => '[${e.ts}] [${e.level}] ${e.message}')
        .join('\n');
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .substring(0, 19);
    final home = Platform.environment['HOME'] ?? '/tmp';
    final path = '$home/.config/talkye/logs/debug_$ts.log';
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(logs);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Saved to $path',
              style: const TextStyle(fontSize: 12),
            ),
            backgroundColor: C.level3,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Export failed: $e',
              style: const TextStyle(fontSize: 12),
            ),
            backgroundColor: C.error,
          ),
        );
      }
    }
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'ERROR':
        return C.error;
      case 'WARN':
        return C.warning;
      default:
        return C.textSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_expanded && LogBuffer.version != _lastVersion) {
      _lastVersion = LogBuffer.version;
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    }
    final logs = _filtered;
    final errorCount = LogBuffer.entries
        .where((e) => e.level == 'ERROR')
        .length;
    final warnCount = LogBuffer.entries.where((e) => e.level == 'WARN').length;

    return Container(
      decoration: BoxDecoration(
        color: C.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      _expanded
                          ? Icons.terminal_rounded
                          : Icons.bug_report_rounded,
                      size: 14,
                      color: C.textSub,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Debug Console',
                      style: TextStyle(
                        fontSize: 12,
                        color: C.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (errorCount > 0) _badge('$errorCount', C.error),
                    if (errorCount > 0) const SizedBox(width: 4),
                    if (warnCount > 0) _badge('$warnCount', C.warning),
                    const Spacer(),
                    Text(
                      '${LogBuffer.length} lines',
                      style: const TextStyle(fontSize: 10, color: C.textMuted),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: C.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            Container(height: 1, color: C.level2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _sourceFilters.map((f) {
                          final active = _filter == f;
                          return Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: GestureDetector(
                              onTap: () => setState(() => _filter = f),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? C.accent.withAlpha(20)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: active
                                          ? C.accent.withAlpha(60)
                                          : C.level3,
                                    ),
                                  ),
                                  child: Text(
                                    f,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w500,
                                      color: f == 'ERROR'
                                          ? C.error
                                          : f == 'WARN'
                                          ? C.warning
                                          : active
                                          ? C.accent
                                          : C.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  _iconBtn(
                    Icons.content_copy_rounded,
                    _copied ? C.success : C.textMuted,
                    _copy,
                  ),
                  _iconBtn(Icons.save_alt_rounded, C.textMuted, _export),
                  _iconBtn(Icons.delete_outline_rounded, C.textMuted, () {
                    LogBuffer.clear();
                    setState(() {});
                  }),
                  _iconBtn(
                    _autoScroll
                        ? Icons.vertical_align_bottom_rounded
                        : Icons.pause_rounded,
                    _autoScroll ? C.accent : C.textMuted,
                    () => setState(() => _autoScroll = !_autoScroll),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Container(
                height: 28,
                decoration: BoxDecoration(
                  color: C.level1,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(
                    fontSize: 11,
                    color: C.text,
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Search logs...',
                    hintStyle: TextStyle(fontSize: 11, color: C.textMuted),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 14,
                      color: C.textMuted,
                    ),
                    prefixIconConstraints: BoxConstraints(minWidth: 30),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 280,
              child: logs.isEmpty
                  ? const Center(
                      child: Text(
                        'No matching logs',
                        style: TextStyle(fontSize: 11, color: C.textMuted),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      itemCount: logs.length,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemBuilder: (_, i) {
                        final e = logs[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 1),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 72,
                                child: Text(
                                  e.ts,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: C.textMuted,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                              if (e.level != 'INFO')
                                Container(
                                  margin: const EdgeInsets.only(
                                    right: 4,
                                    top: 1,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _levelColor(e.level).withAlpha(20),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: Text(
                                    e.level,
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.w600,
                                      color: _levelColor(e.level),
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  e.message,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    height: 1.4,
                                    color: e.level == 'ERROR'
                                        ? C.error
                                        : e.level == 'WARN'
                                        ? C.warning
                                        : C.textSub,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }
}
