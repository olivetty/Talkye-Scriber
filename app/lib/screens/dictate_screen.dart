import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
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
  const DictateScreen({super.key, required this.settings, required this.onRestartSidecar});
  @override
  State<DictateScreen> createState() => _DictateScreenState();
}

class _DictateScreenState extends State<DictateScreen> {
  bool _connected = false;
  bool _pttRunning = false;
  bool _recording = false;
  bool _busy = false;
  bool _restarting = false;
  bool _commandsExpanded = false;
  String _language = 'auto';
  String _inputMode = 'ptt';
  String _triggerKey = 'KEY_RIGHTCTRL';
  String _soundTheme = 'subtle';
  String _magicWord = 'hey mira';
  int _vadTimeout = 8;
  bool _autoEnter = true;
  Timer? _pollTimer;

  static const _restartMessages = [
    'Switching input mode...',
    'Restarting background service...',
    'Warming up microphone...',
    'Almost there...',
  ];
  int _restartMsgIndex = 0;
  Timer? _restartMsgTimer;

  @override
  void initState() {
    super.initState();
    _triggerKey = widget.settings.triggerKey;
    _soundTheme = widget.settings.soundTheme;
    _inputMode = widget.settings.inputMode;
    _magicWord = widget.settings.magicWord;
    _vadTimeout = widget.settings.vadTimeout;
    _autoEnter = widget.settings.autoEnter;
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _restartMsgTimer?.cancel();
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
    } catch (_) { return null; }
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
    if (_restarting) return;
    final health = await _get('/health');
    final ok = health != null && health['status'] == 'ok';
    if (ok) {
      if (!_connected) {
        await _post('/dictate/config', {
          'trigger_key': widget.settings.triggerKey,
          'sound_theme': widget.settings.soundTheme,
          'input_mode': widget.settings.inputMode,
          'magic_word': widget.settings.magicWord,
          'vad_timeout': widget.settings.vadTimeout,
          'auto_enter': widget.settings.autoEnter,
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
          _inputMode = s['input_mode'] as String? ?? 'ptt';
          _triggerKey = s['trigger_key'] as String? ?? 'KEY_RIGHTCTRL';
          _soundTheme = s['sound_theme'] as String? ?? 'subtle';
          _magicWord = s['magic_word'] as String? ?? 'hey mira';
          _vadTimeout = s['vad_timeout'] as int? ?? 8;
          _autoEnter = s['auto_enter'] as bool? ?? true;
        });
      }
    } else {
      if (mounted) setState(() => _connected = false);
    }
  }

  Future<void> _updateConfig(Map<String, dynamic> cfg) async {
    await _post('/dictate/config', cfg);
    if (cfg.containsKey('trigger_key')) widget.settings.triggerKey = cfg['trigger_key'] as String;
    if (cfg.containsKey('sound_theme')) widget.settings.soundTheme = cfg['sound_theme'] as String;
    if (cfg.containsKey('input_mode')) widget.settings.inputMode = cfg['input_mode'] as String;
    if (cfg.containsKey('magic_word')) widget.settings.magicWord = cfg['magic_word'] as String;
    if (cfg.containsKey('vad_timeout')) widget.settings.vadTimeout = cfg['vad_timeout'] as int;
    if (cfg.containsKey('auto_enter')) widget.settings.autoEnter = cfg['auto_enter'] as bool;
    widget.settings.save();
    _poll();
  }

  Future<void> _switchMode(String newMode) async {
    if (newMode == _inputMode) return;
    widget.settings.inputMode = newMode;
    widget.settings.save();
    setState(() { _restarting = true; _restartMsgIndex = 0; _inputMode = newMode; });
    _restartMsgTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && _restarting) {
        setState(() => _restartMsgIndex = (_restartMsgIndex + 1) % _restartMessages.length);
      }
    });
    try {
      await widget.onRestartSidecar();
      await Future.delayed(const Duration(milliseconds: 500));
    } finally {
      _restartMsgTimer?.cancel();
      if (mounted) { setState(() { _restarting = false; _connected = false; }); _poll(); }
    }
  }

  void _showKeyPicker() {
    showDialog(
      context: context, barrierColor: Colors.transparent, useSafeArea: false,
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
    if (_restarting) return _restartingView();
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.all(24), children: [
        _header(),
        const SizedBox(height: 6),
        const Text(
          'Type anywhere with your voice. Hold a key or say a wake word, speak, release — text appears at your cursor.',
          style: TextStyle(fontSize: 12, color: C.textSub, height: 1.4)),
        const SizedBox(height: 20),
        if (!_connected) _offlineBanner() else ...[
          _statusRow(),
          const SizedBox(height: 16),
          _pttSection(),
          const SizedBox(height: 12),
          _vadSection(),
          const SizedBox(height: 16),
          _generalSection(),
          const SizedBox(height: 16),
          _commandsSection(),
        ],
      ])),
      _footer(),
    ]);
  }

  Widget _restartingView() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 120, height: 120,
        child: Lottie.asset('assets/vui-animation.json', animate: true)),
      const SizedBox(height: 20),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Text(_restartMessages[_restartMsgIndex],
          key: ValueKey(_restartMsgIndex),
          style: const TextStyle(fontSize: 13, color: C.textSub, fontWeight: FontWeight.w500)),
      ),
    ]));
  }

  Widget _header() {
    return Row(children: [
      const Text('Scriber', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
        color: C.text, letterSpacing: -0.5)),
      const SizedBox(width: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (_connected && _pttRunning ? C.success : C.textMuted).withAlpha(20),
          borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle,
            color: _connected && _pttRunning ? C.success : C.textMuted)),
          const SizedBox(width: 6),
          Text(!_connected ? 'Offline' : (_pttRunning ? 'Active' : 'Starting...'),
            style: TextStyle(fontSize: 11,
              color: _connected && _pttRunning ? C.success : C.textMuted,
              fontWeight: FontWeight.w500)),
        ]),
      ),
    ]);
  }

  Widget _statusRow() {
    return Row(children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
        color: _recording ? C.error : (_busy ? C.warning : C.success))),
      const SizedBox(width: 6),
      Text(_recording ? 'Recording' : (_busy ? 'Transcribing' : 'Ready'),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
          color: _recording ? C.error : (_busy ? C.warning : C.success))),
    ]);
  }

  Widget _offlineBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: C.warning.withAlpha(10), borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.power_off_rounded, color: C.warning.withAlpha(150), size: 20),
        const SizedBox(width: 12),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sidecar not running',
            style: TextStyle(color: C.text, fontSize: 13, fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('The background service starts automatically with the app.\nCheck Settings → Logs if it failed.',
            style: TextStyle(color: C.textSub, fontSize: 12, height: 1.5)),
        ])),
      ]),
    );
  }

  // ── Push to Talk section ──

  Widget _pttSection() {
    final active = _inputMode == 'ptt';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: active ? C.level1 : C.level1.withAlpha(120),
        borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Push to Talk',
            style: TextStyle(color: active ? C.text : C.textMuted, fontSize: 13, fontWeight: FontWeight.w600))),
          _modeSwitch(active, () => _switchMode('ptt')),
        ]),
        if (active) ...[
          const SizedBox(height: 4),
          Text('Hold a key to record, release to transcribe',
            style: TextStyle(fontSize: 11, color: C.textSub, height: 1.3)),
          const SizedBox(height: 14),
          _row('Trigger Key', _triggerKeyWidget()),
        ],
      ]),
    );
  }

  // ── Voice Activate section ──

  Widget _vadSection() {
    final active = _inputMode == 'vad';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: active ? C.level1 : C.level1.withAlpha(120),
        borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Voice Activate',
            style: TextStyle(color: active ? C.text : C.textMuted, fontSize: 13, fontWeight: FontWeight.w600))),
          _modeSwitch(active, () => _switchMode('vad')),
        ]),
        if (active) ...[
          const SizedBox(height: 4),
          Text('Say the wake phrase to start dictating. Microphone listens at all times.',
            style: TextStyle(fontSize: 11, color: C.textSub, height: 1.3)),
          const SizedBox(height: 14),
          _row('Wake Words', _wakeWordsWidget()),
          const SizedBox(height: 12),
          _row('Timeout', _timeoutWidget()),
          const SizedBox(height: 12),
          _row('Auto Enter', _autoEnterToggle()),
        ],
      ]),
    );
  }

  Widget _modeSwitch(bool isOn, VoidCallback onTap) {
    return GestureDetector(
      onTap: _connected && !isOn ? onTap : null,
      child: MouseRegion(
        cursor: _connected && !isOn ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 38, height: 22, padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: isOn ? C.accent : C.level3, borderRadius: BorderRadius.circular(11)),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(width: 18, height: 18,
              decoration: BoxDecoration(shape: BoxShape.circle,
                color: isOn ? Colors.white : C.textMuted)),
          ),
        ),
      ),
    );
  }

  Widget _triggerKeyWidget() {
    return GestureDetector(
      onTap: _connected ? _showKeyPicker : null,
      child: MouseRegion(
        cursor: _connected ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(labelForEvdev(_triggerKey),
              style: const TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
            const SizedBox(width: 6),
            const Text('Change', style: TextStyle(fontSize: 11, color: C.accent, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  Widget _wakeWordsWidget() {
    return _chip('Hey Mira');
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: C.accent.withAlpha(20), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: const TextStyle(fontSize: 11, color: C.accent, fontWeight: FontWeight.w500)),
    );
  }

  Widget _timeoutWidget() {
    return PopupMenuButton<int>(
      onSelected: (v) {
        _updateConfig({'vad_timeout': v});
        setState(() => _vadTimeout = v);
      },
      offset: const Offset(0, 32), color: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) => [4, 6, 8, 10, 15].map((s) => PopupMenuItem(
        value: s, height: 34,
        child: Text('${s}s silence → standby', style: TextStyle(fontSize: 12,
          color: s == _vadTimeout ? C.accent : C.text,
          fontWeight: s == _vadTimeout ? FontWeight.w600 : FontWeight.w400)),
      )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${_vadTimeout}s', style: const TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 14, color: C.textMuted),
        ]),
      ),
    );
  }

  Widget _autoEnterToggle() {
    return GestureDetector(
      onTap: _connected ? () {
        final v = !_autoEnter;
        _updateConfig({'auto_enter': v});
        setState(() => _autoEnter = v);
      } : null,
      child: MouseRegion(
        cursor: _connected ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 38, height: 22, padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: _autoEnter ? C.accent : C.level3, borderRadius: BorderRadius.circular(11)),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: _autoEnter ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(width: 18, height: 18,
              decoration: BoxDecoration(shape: BoxShape.circle,
                color: _autoEnter ? Colors.white : C.textMuted)),
          ),
        ),
      ),
    );
  }

  // ── General settings ──

  Widget _generalSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('General', style: TextStyle(color: C.text, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        _row('Language', _langDropdown()),
        const SizedBox(height: 12),
        _row('Sound', _soundDropdown()),
      ]),
    );
  }

  // ── Voice Commands ──

  Widget _commandsSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: () => setState(() => _commandsExpanded = !_commandsExpanded),
          child: MouseRegion(cursor: SystemMouseCursors.click,
            child: Row(children: [
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Voice Commands', style: TextStyle(color: C.text, fontSize: 13, fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text('Say commands like "enter", "delete", "undo" in any language',
                  style: TextStyle(fontSize: 11, color: C.textSub, height: 1.3)),
              ])),
              Icon(_commandsExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                size: 18, color: C.textMuted),
            ]),
          ),
        ),
        if (_commandsExpanded) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: _voiceCommands.map((cmd) =>
            Tooltip(message: cmd.$2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
                child: Text(cmd.$1, style: const TextStyle(fontSize: 11, color: C.textSub,
                  fontFamily: 'monospace')),
              ),
            ),
          ).toList()),
        ],
      ]),
    );
  }

  // ── Shared widgets ──

  Widget _row(String label, Widget child) {
    return Row(children: [
      Expanded(child: Text(label, style: const TextStyle(color: C.textSub, fontSize: 12))),
      child,
    ]);
  }

  Widget _langDropdown() {
    const langs = [
      ('auto', 'Autodetect'), ('ro', 'Romanian'), ('en', 'English'),
      ('es', 'Spanish'), ('fr', 'French'), ('de', 'German'),
      ('it', 'Italian'), ('pt', 'Portuguese'),
    ];
    return PopupMenuButton<String>(
      onSelected: (v) => _updateConfig({'language': v}),
      offset: const Offset(0, 32), color: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) => langs.map((e) => PopupMenuItem(
        value: e.$1, height: 34,
        child: Text(e.$2, style: TextStyle(fontSize: 12,
          color: e.$1 == _language ? C.accent : C.text,
          fontWeight: e.$1 == _language ? FontWeight.w600 : FontWeight.w400)),
      )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(langs.firstWhere((e) => e.$1 == _language, orElse: () => langs.first).$2,
            style: const TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 14, color: C.textMuted),
        ]),
      ),
    );
  }

  Widget _soundDropdown() {
    const themes = [
      ('subtle', 'Subtle'), ('mechanical', 'Mechanical'),
      ('alex', 'Alex'), ('emma', 'Emma'), ('sofia', 'Sofia'), ('luna', 'Luna'),
      ('silent', 'Silent'),
    ];
    return PopupMenuButton<String>(
      onSelected: (v) {
        _updateConfig({'sound_theme': v});
        setState(() => _soundTheme = v);
        if (v != 'silent') _post('/dictate/preview-sound', {'theme': v});
      },
      offset: const Offset(0, 32), color: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) => themes.map((e) => PopupMenuItem(
        value: e.$1, height: 38,
        child: Row(children: [
          Expanded(child: Text(e.$2, style: TextStyle(fontSize: 12,
            color: e.$1 == _soundTheme ? C.accent : C.text,
            fontWeight: e.$1 == _soundTheme ? FontWeight.w600 : FontWeight.w400))),
          if (e.$1 != 'silent')
            GestureDetector(
              onTap: () => _post('/dictate/preview-sound', {'theme': e.$1}),
              child: MouseRegion(cursor: SystemMouseCursors.click,
                child: Padding(padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.play_arrow_rounded, size: 16,
                    color: e.$1 == _soundTheme ? C.accent : C.textMuted))),
            ),
        ]),
      )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(themes.firstWhere((e) => e.$1 == _soundTheme, orElse: () => themes.first).$2,
            style: const TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 14, color: C.textMuted),
        ]),
      ),
    );
  }

  Widget _footer() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      color: C.level1,
      child: const Text('Works system-wide — in any app where you can type',
        style: TextStyle(fontSize: 10, color: C.textSub)),
    );
  }
}
