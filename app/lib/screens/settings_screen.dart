import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../main.dart';
import '../src/rust/api/simple.dart';

const _baseUrl = 'http://127.0.0.1:8179';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final bool engineRunning;
  const SettingsScreen({super.key, required this.settings, required this.onChanged, required this.engineRunning});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // TTS status
  bool _chatterboxInstalled = false;
  bool _chatterboxAvailable = false;
  bool _chatterboxLoaded = false;
  bool _chatterboxCanInstall = false;
  String _gpuName = '';
  String _gpuBackend = 'cpu';
  bool _installingChatterbox = false;
  bool _loadingChatterbox = false;

  @override
  void initState() {
    super.initState();
    _fetchTtsStatusWithRetry();
  }

  Future<void> _fetchTtsStatusWithRetry() async {
    // Sidecar may still be starting — retry a few times
    for (var i = 0; i < 5; i++) {
      await _fetchTtsStatus();
      if (_gpuBackend != 'cpu' || _chatterboxInstalled) return;
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }
  }

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.getUrl(Uri.parse('$_baseUrl$path'));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final data = await resp.transform(utf8.decoder).join();
      c.close();
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (_) { return null; }
  }

  Future<void> _fetchTtsStatus() async {
    final status = await _get('/tts/status');
    if (status != null && mounted) {
      final cbx = status['chatterbox'] as Map<String, dynamic>? ?? {};
      final gpu = cbx['gpu'] as Map<String, dynamic>? ?? {};
      setState(() {
        _chatterboxInstalled = cbx['installed'] as bool? ?? false;
        _chatterboxAvailable = cbx['available'] as bool? ?? false;
        _chatterboxLoaded = cbx['loaded'] as bool? ?? false;
        _chatterboxCanInstall = cbx['can_install'] as bool? ?? false;
        _gpuName = gpu['name'] as String? ?? 'Unknown';
        _gpuBackend = gpu['backend'] as String? ?? 'cpu';
      });
    }
  }

  Future<void> _installChatterbox() async {
    setState(() => _installingChatterbox = true);
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.postUrl(Uri.parse('$_baseUrl/tts/install-chatterbox'));
      req.headers.set('Content-Type', 'application/json');
      req.write('{}');
      await req.close().timeout(const Duration(minutes: 10));
      c.close();
      await _fetchTtsStatus();
    } catch (_) {}
    if (mounted) setState(() => _installingChatterbox = false);
  }

  Future<void> _loadChatterbox() async {
    setState(() => _loadingChatterbox = true);
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.postUrl(Uri.parse('$_baseUrl/tts/load-chatterbox'));
      req.headers.set('Content-Type', 'application/json');
      req.write('{}');
      await req.close().timeout(const Duration(minutes: 5));
      c.close();
      await _fetchTtsStatus();
    } catch (_) {}
    if (mounted) setState(() => _loadingChatterbox = false);
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.engineRunning;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Row(children: [
        const Text('Settings',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: C.text, letterSpacing: -0.5)),
        const Spacer(),
        if (locked) Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: C.orange.withAlpha(15), borderRadius: BorderRadius.circular(8)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_rounded, size: 12, color: C.orange),
            SizedBox(width: 4),
            Text('Engine running', style: TextStyle(fontSize: 11, color: C.orange, fontWeight: FontWeight.w500)),
          ]),
        ),
      ]),
      const SizedBox(height: 24),
      const Text('SPEECH RECOGNITION',
        style: TextStyle(fontSize: 11, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 10),
      _sttOption('parakeet', 'Talkye Local',
        'On-device · Free · 17 languages', Icons.computer_rounded, locked),
      const SizedBox(height: 8),
      _sttOption('deepgram', 'Talkye Max',
        'Cloud · Premium · \$1/hr · 36+ languages', Icons.cloud_rounded, locked),
      const SizedBox(height: 20),
      // TTS Backend
      const Text('TEXT TO SPEECH',
        style: TextStyle(fontSize: 11, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 10),
      _ttsOption('pocket', 'Pocket TTS',
        'CPU · English only · Built-in', Icons.memory_rounded),
      const SizedBox(height: 8),
      _ttsChatterboxOption(),
      const SizedBox(height: 20),
      // Audio + About side by side
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _miniSection('AUDIO', [
          _infoRow('Input', 'Default mic'),
          _infoRow('Output', 'Default speaker'),
        ])),
        const SizedBox(width: 12),
        Expanded(child: _miniSection('ABOUT', [
          _infoRow('App', 'v0.2.1'),
          _infoRow('Engine', engineVersion()),
          _infoRow('Voice', 'Neural clone'),
        ])),
      ]),
      const SizedBox(height: 20),
      const Text('DIAGNOSTICS',
        style: TextStyle(fontSize: 11, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 10),
      const _CopyLogsBtn(),
      const SizedBox(height: 16),
      Text(locked ? 'Stop the engine to change settings.' : 'Changes apply on next engine start.',
        style: TextStyle(fontSize: 11, color: locked ? C.orange.withAlpha(150) : C.textMuted.withAlpha(100))),
    ]);
  }

  Widget _ttsOption(String value, String label, String desc, IconData icon) {
    final selected = widget.settings.ttsBackend == value;
    return GestureDetector(
      onTap: () {
        widget.settings.ttsBackend = value;
        widget.onChanged(widget.settings);
        setState(() {});
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? C.accent.withAlpha(15) : C.level1,
          borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            size: 16, color: selected ? C.accent : C.textMuted),
          const SizedBox(width: 12),
          Icon(icon, size: 16, color: selected ? C.accent : C.textSub),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 13, color: C.text,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
            Text(desc, style: const TextStyle(fontSize: 11, color: C.textSub)),
          ])),
        ]),
      ),
    );
  }

  Widget _ttsChatterboxOption() {
    final selected = widget.settings.ttsBackend == 'chatterbox';
    final hasGpu = _gpuBackend != 'cpu';
    // Allow selection if GPU exists (even if not installed yet — install button shown)
    final canSelect = hasGpu;

    // Determine status text
    String statusText;
    Color statusColor;
    if (!hasGpu) {
      statusText = 'Requires GPU';
      statusColor = C.textMuted;
    } else if (!_chatterboxInstalled) {
      statusText = 'Not installed';
      statusColor = C.warning;
    } else if (!_chatterboxLoaded && selected) {
      statusText = 'Ready to load';
      statusColor = C.warning;
    } else if (_chatterboxLoaded) {
      statusText = 'Loaded';
      statusColor = C.success;
    } else {
      statusText = 'Installed';
      statusColor = C.textSub;
    }

    return GestureDetector(
      onTap: canSelect ? () {
        widget.settings.ttsBackend = 'chatterbox';
        widget.onChanged(widget.settings);
        setState(() {});
        // Auto-load if installed but not loaded
        if (_chatterboxInstalled && !_chatterboxLoaded) {
          _loadChatterbox();
        }
      } : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? C.accent.withAlpha(15) : C.level1,
          borderRadius: BorderRadius.circular(10)),
        child: Opacity(
          opacity: hasGpu ? 1.0 : 0.5,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(selected && canSelect ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                size: 16, color: selected && canSelect ? C.accent : C.textMuted),
              const SizedBox(width: 12),
              const Icon(Icons.graphic_eq_rounded, size: 16, color: C.textSub),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('Chatterbox', style: TextStyle(fontSize: 13, color: C.text, fontWeight: FontWeight.w400)),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: C.accent.withAlpha(20), borderRadius: BorderRadius.circular(4)),
                    child: const Text('GPU', style: TextStyle(fontSize: 9, color: C.accent, fontWeight: FontWeight.w600)),
                  ),
                ]),
                Text('23 languages · Voice cloning · $_gpuName',
                  style: const TextStyle(fontSize: 11, color: C.textSub)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: statusColor.withAlpha(15), borderRadius: BorderRadius.circular(4)),
                child: Text(statusText, style: TextStyle(fontSize: 9, color: statusColor, fontWeight: FontWeight.w500)),
              ),
            ]),
            // Install button if GPU available but not installed
            if (hasGpu && !_chatterboxInstalled) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _installingChatterbox ? null : _installChatterbox,
                child: MouseRegion(
                  cursor: _installingChatterbox ? SystemMouseCursors.basic : SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _installingChatterbox ? C.level2 : C.accent,
                      borderRadius: BorderRadius.circular(6)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_installingChatterbox) ...[
                        const SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: C.textSub)),
                        const SizedBox(width: 6),
                        const Text('Installing...', style: TextStyle(fontSize: 11, color: C.textSub)),
                      ] else ...[
                        const Icon(Icons.download_rounded, size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                        const Text('Install (~2 GB)', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500)),
                      ],
                    ]),
                  ),
                ),
              ),
            ],
            // Load button if installed but not loaded and selected
            if (_chatterboxInstalled && !_chatterboxLoaded && selected) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _loadingChatterbox ? null : _loadChatterbox,
                child: MouseRegion(
                  cursor: _loadingChatterbox ? SystemMouseCursors.basic : SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _loadingChatterbox ? C.level2 : C.accent,
                      borderRadius: BorderRadius.circular(6)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_loadingChatterbox) ...[
                        const SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: C.textSub)),
                        const SizedBox(width: 6),
                        const Text('Loading model...', style: TextStyle(fontSize: 11, color: C.textSub)),
                      ] else ...[
                        const Icon(Icons.play_arrow_rounded, size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                        const Text('Load Model', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500)),
                      ],
                    ]),
                  ),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _miniSection(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 10, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }

  Widget _sttOption(String value, String label, String desc, IconData icon, bool locked) {
    final selected = widget.settings.sttBackend == value;
    final isPremium = value == 'deepgram';
    return GestureDetector(
      onTap: locked ? null : () {
        widget.settings.sttBackend = value;
        widget.onChanged(widget.settings);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? C.accent.withAlpha(15) : C.level1,
          borderRadius: BorderRadius.circular(10)),
        child: Opacity(opacity: locked ? 0.5 : 1.0, child: Row(children: [
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            size: 16, color: selected ? C.accent : C.textMuted),
          const SizedBox(width: 12),
          Icon(icon, size: 16, color: selected ? C.accent : C.textSub),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(label, style: TextStyle(fontSize: 13, color: C.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              if (isPremium) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: C.warning.withAlpha(20), borderRadius: BorderRadius.circular(4)),
                  child: const Text('Premium', style: TextStyle(fontSize: 9, color: C.warning, fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
            Text(desc, style: const TextStyle(fontSize: 11, color: C.textSub)),
          ])),
        ])),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 56, child: Text(label, style: const TextStyle(fontSize: 11, color: C.textSub))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 11, color: C.text))),
      ]),
    );
  }
}

class _CopyLogsBtn extends StatefulWidget {
  const _CopyLogsBtn();
  @override
  State<_CopyLogsBtn> createState() => _CopyLogsBtnState();
}

class _CopyLogsBtnState extends State<_CopyLogsBtn> {
  bool _copied = false;

  void _copy() {
    final logs = LogBuffer.text;
    Clipboard.setData(ClipboardData(text: logs.isEmpty ? '(no logs yet)' : logs));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _copy,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 14,
            color: _copied ? C.success : C.textSub),
          const SizedBox(width: 10),
          Text(_copied ? 'Copied to clipboard' : 'Copy Logs',
            style: TextStyle(fontSize: 12, color: _copied ? C.success : C.text, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text('${LogBuffer.length} lines',
            style: const TextStyle(fontSize: 11, color: C.textMuted)),
        ]),
      ),
    );
  }
}
