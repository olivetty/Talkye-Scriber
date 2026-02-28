import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../theme.dart';
import 'key_picker_dialog.dart';

const _baseUrl = 'http://127.0.0.1:8179';

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
  bool _settingsExpanded = false;
  String _language = 'auto';
  String _triggerKey = 'KEY_RIGHTCTRL';
  String _soundTheme = 'subtle';
  Timer? _pollTimer;

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
          final st = s['dictate_translate'] as bool? ?? false;
          if (widget.settings.dictateTranslate != st)
            widget.settings.dictateTranslate = st;
          final sg = s['dictate_grammar'] as bool? ?? false;
          if (widget.settings.dictateGrammar != sg)
            widget.settings.dictateGrammar = sg;
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
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _header(),
        const SizedBox(height: 6),
        const Text(
          'Hold a key, speak, release — text appears at your cursor.',
          style: TextStyle(fontSize: 12, color: C.textSub, height: 1.4),
        ),
        const SizedBox(height: 20),
        if (!_connected)
          _offlineBanner()
        else ...[
          _statusBanner(),
          const SizedBox(height: 16),
          _dictationSection(),
        ],
        const SizedBox(height: 24),
        _settingsSection(),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'Talkye Scriber v0.3.0',
            style: TextStyle(fontSize: 10, color: C.textMuted.withAlpha(120)),
          ),
        ),
        const SizedBox(height: 8),
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

  Widget _statusBanner() {
    final Color color;
    final String label;
    final IconData icon;
    if (_recording) {
      color = C.error;
      label = 'Recording...';
      icon = Icons.mic_rounded;
    } else if (_busy) {
      color = C.warning;
      label = 'Transcribing...';
      icon = Icons.hearing_rounded;
    } else {
      color = C.success;
      label = 'Ready — hold trigger key to speak';
      icon = Icons.check_circle_outline_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color.withAlpha(180)),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
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
                  'The background service starts automatically with the app.\nOpen the debug console below if it failed.',
                  style: TextStyle(color: C.textSub, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Dictation (merged PTT + General) ──

  Widget _dictationSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.level1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Trigger Key', _triggerKeyWidget()),
          const SizedBox(height: 12),
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
                  const Text(
                    'GROQ API KEY',
                    style: TextStyle(
                      fontSize: 10,
                      color: C.textMuted,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Needed for Translate and Grammar Fix. Free at groq.com',
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
                  _DebugPanel(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Helper widgets ──

  Widget _row(String label, Widget trailing) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: C.textSub)),
        const Spacer(),
        trailing,
      ],
    );
  }

  Widget _langDropdown() {
    final langs = {
      'auto': 'Auto-detect',
      'en': 'English',
      'ro': 'Romanian',
      'de': 'German',
      'fr': 'French',
      'es': 'Spanish',
      'it': 'Italian',
      'pt': 'Portuguese',
      'nl': 'Dutch',
      'pl': 'Polish',
      'ja': 'Japanese',
      'zh': 'Chinese',
      'ko': 'Korean',
    };
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: C.level2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButton<String>(
        value: langs.containsKey(_language) ? _language : 'auto',
        underline: const SizedBox.shrink(),
        dropdownColor: C.level3,
        style: const TextStyle(fontSize: 12, color: C.text),
        icon: const Icon(
          Icons.expand_more_rounded,
          size: 16,
          color: C.textMuted,
        ),
        isDense: true,
        items: langs.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: _connected
            ? (v) {
                if (v != null) _updateConfig({'language': v});
              }
            : null,
      ),
    );
  }

  Widget _soundDropdown() {
    final sounds = {
      'subtle': 'Subtle',
      'alex': 'Alex',
      'luna': 'Luna',
      'silent': 'Silent',
    };
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: C.level2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButton<String>(
        value: sounds.containsKey(_soundTheme) ? _soundTheme : 'subtle',
        underline: const SizedBox.shrink(),
        dropdownColor: C.level3,
        style: const TextStyle(fontSize: 12, color: C.text),
        icon: const Icon(
          Icons.expand_more_rounded,
          size: 16,
          color: C.textMuted,
        ),
        isDense: true,
        items: sounds.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: _connected
            ? (v) {
                if (v != null) _updateConfig({'sound_theme': v});
              }
            : null,
      ),
    );
  }

  Widget _translateToggle() {
    return GestureDetector(
      onTap: _connected
          ? () {
              final next = !widget.settings.dictateTranslate;
              widget.settings.dictateTranslate = next;
              _updateConfig({'dictate_translate': next});
            }
          : null,
      child: MouseRegion(
        cursor: _connected
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          width: 38,
          height: 20,
          decoration: BoxDecoration(
            color: widget.settings.dictateTranslate
                ? C.accent.withAlpha(60)
                : C.level2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: widget.settings.dictateTranslate
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.settings.dictateTranslate
                    ? C.accent
                    : C.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grammarToggle() {
    return GestureDetector(
      onTap: _connected
          ? () {
              final next = !widget.settings.dictateGrammar;
              widget.settings.dictateGrammar = next;
              _updateConfig({'dictate_grammar': next});
            }
          : null,
      child: MouseRegion(
        cursor: _connected
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          width: 38,
          height: 20,
          decoration: BoxDecoration(
            color: widget.settings.dictateGrammar
                ? C.accent.withAlpha(60)
                : C.level2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: widget.settings.dictateGrammar
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.settings.dictateGrammar ? C.accent : C.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Debug Console ──

class _DebugPanel extends StatefulWidget {
  const _DebugPanel();
  @override
  State<_DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<_DebugPanel> {
  bool _expanded = false;
  String _filter = '';
  int _lastVersion = -1;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<LogEntry> get _filtered {
    final all = LogBuffer.entries;
    if (_filter.isEmpty) return all;
    final q = _filter.toLowerCase();
    return all
        .where(
          (e) =>
              e.message.toLowerCase().contains(q) ||
              e.level.toLowerCase().contains(q) ||
              e.source.toLowerCase().contains(q),
        )
        .toList();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() {
            _expanded = !_expanded;
          }),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              children: [
                const Text(
                  'DEBUG CONSOLE',
                  style: TextStyle(
                    fontSize: 10,
                    color: C.textMuted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
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
        if (_expanded) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 30,
                  decoration: BoxDecoration(
                    color: C.bg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: TextField(
                    style: const TextStyle(
                      fontSize: 11,
                      color: C.text,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Filter logs...',
                      hintStyle: TextStyle(fontSize: 11, color: C.textMuted),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 7,
                      ),
                      isDense: true,
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 14,
                        color: C.textMuted,
                      ),
                      prefixIconConstraints: BoxConstraints(minWidth: 30),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _iconBtn(Icons.copy_rounded, 'Copy', () {
                Clipboard.setData(ClipboardData(text: LogBuffer.text));
              }),
              const SizedBox(width: 4),
              _iconBtn(Icons.delete_outline_rounded, 'Clear', () {
                LogBuffer.clear();
                setState(() {});
              }),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: C.bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: _logList(),
          ),
        ],
      ],
    );
  }

  Widget _logList() {
    final logs = _filtered;
    if (_lastVersion != LogBuffer.version) {
      _lastVersion = LogBuffer.version;
      _scrollToBottom();
    }
    if (logs.isEmpty) {
      return const Center(
        child: Text(
          'No logs yet',
          style: TextStyle(fontSize: 11, color: C.textMuted),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(8),
      itemCount: logs.length,
      itemBuilder: (_, i) {
        final e = logs[i];
        final color = switch (e.level) {
          'ERROR' => C.error,
          'WARN' => C.warning,
          _ => C.textSub,
        };
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${e.ts} ',
                  style: TextStyle(
                    color: C.textMuted.withAlpha(150),
                    fontSize: 10,
                  ),
                ),
                if (e.source.isNotEmpty)
                  TextSpan(
                    text: '[${e.source}] ',
                    style: TextStyle(
                      color: C.accent.withAlpha(180),
                      fontSize: 10,
                    ),
                  ),
                TextSpan(
                  text: e.message,
                  style: TextStyle(color: color, fontSize: 10),
                ),
              ],
            ),
            style: const TextStyle(fontFamily: 'monospace', height: 1.5),
          ),
        );
      },
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: C.bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 14, color: C.textMuted),
          ),
        ),
      ),
    );
  }
}
