import 'dart:async';
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
  bool _chatterboxWarmedUp = false;
  bool _chatterboxCanInstall = false;
  String _gpuName = '';
  String _gpuBackend = 'cpu';
  bool _installingChatterbox = false;
  bool _loadingChatterbox = false;
  bool _testingTts = false;
  bool _initialLoading = true; // true until model loaded + warmed up

  @override
  void initState() {
    super.initState();
    _fetchTtsStatusWithRetry();
  }

  Future<void> _fetchTtsStatusWithRetry() async {
    // Sidecar may still be starting — retry until GPU detected
    for (var i = 0; i < 5; i++) {
      await _fetchTtsStatus();
      if (_gpuBackend != 'cpu') break;
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }
    // If Chatterbox is selected but not warmed up yet, keep polling
    // (auto-load + warm-up takes ~20-25s at startup)
    if (widget.settings.ttsBackend == 'chatterbox' && !_chatterboxWarmedUp) {
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        await _fetchTtsStatus();
        if (_chatterboxWarmedUp) break;
      }
    }
    if (mounted) setState(() => _initialLoading = false);
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
        _chatterboxWarmedUp = cbx['warmed_up'] as bool? ?? false;
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
      final resp = await req.close().timeout(const Duration(minutes: 5));
      final body = await resp.transform(utf8.decoder).join();
      c.close();
      // Parse response to get immediate loaded state
      try {
        final result = jsonDecode(body) as Map<String, dynamic>;
        final st = result['status'] as Map<String, dynamic>?;
        if (result['ok'] == true && st != null && mounted) {
          setState(() {
            _chatterboxLoaded = st['loaded'] as bool? ?? false;
            _chatterboxAvailable = st['available'] as bool? ?? false;
          });
        }
      } catch (_) {}
      // Also refresh full status
      await _fetchTtsStatus();
    } catch (_) {}
    if (mounted) setState(() => _loadingChatterbox = false);
  }

  Future<void> _testTts(String text, String langId) async {
    setState(() => _testingTts = true);
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.postUrl(Uri.parse('$_baseUrl/tts/test'));
      req.headers.set('Content-Type', 'application/json');
      req.write(jsonEncode({'text': text, 'language_id': langId}));
      await req.close().timeout(const Duration(seconds: 10));
      c.close();
    } catch (_) {}
    // Wait a bit for audio to play before re-enabling button
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) setState(() => _testingTts = false);
  }

  @override
  Widget build(BuildContext context) {
    // Show loading overlay while Chatterbox auto-loads at startup
    if (_initialLoading && widget.settings.ttsBackend == 'chatterbox') {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 32, height: 32,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: C.accent)),
          const SizedBox(height: 20),
          const Text('Loading models...', style: TextStyle(fontSize: 15, color: C.text, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(_chatterboxLoaded
            ? 'Warming up TTS · $_gpuName'
            : 'Chatterbox TTS · $_gpuName',
            style: const TextStyle(fontSize: 12, color: C.textSub)),
          const SizedBox(height: 4),
          const Text('This takes about 20 seconds on first launch',
            style: TextStyle(fontSize: 11, color: C.textMuted)),
        ]),
      );
    }
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
      // Chatterbox Quality Settings (when selected)
      if (widget.settings.ttsBackend == 'chatterbox') ...[
        const Text('CHATTERBOX QUALITY',
          style: TextStyle(fontSize: 11, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
        const SizedBox(height: 10),
        _cbxSlider(
          label: 'Exaggeration',
          desc: 'Voice expressiveness',
          value: widget.settings.cbxExaggeration,
          min: 0.0, max: 1.0,
          onChanged: (v) => setState(() { widget.settings.cbxExaggeration = _round2(v); widget.settings.save(); }),
        ),
        const SizedBox(height: 6),
        _cbxSlider(
          label: 'CFG Weight',
          desc: 'Reference voice adherence',
          value: widget.settings.cbxCfgWeight,
          min: 0.0, max: 1.0,
          onChanged: (v) => setState(() { widget.settings.cbxCfgWeight = _round2(v); widget.settings.save(); }),
        ),
        const SizedBox(height: 6),
        _cbxSlider(
          label: 'Temperature',
          desc: 'Generation variability',
          value: widget.settings.cbxTemperature,
          min: 0.1, max: 1.0,
          onChanged: (v) => setState(() { widget.settings.cbxTemperature = _round2(v); widget.settings.save(); }),
        ),
        const SizedBox(height: 6),
        _cbxSlider(
          label: 'Context Window',
          desc: 'Overlap tokens for smooth boundaries',
          value: widget.settings.cbxContextWindow.toDouble(),
          min: 25, max: 100, divisions: 15, isInt: true,
          onChanged: (v) => setState(() { widget.settings.cbxContextWindow = v.round(); widget.settings.save(); }),
        ),
        const SizedBox(height: 8),
        _cbxPresets(),
        const SizedBox(height: 20),
      ],
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
      const _DebugPanel(),
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
            // Test buttons when loaded
            if (_chatterboxLoaded && selected) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _testBtn('🇬🇧 English', 'Hello, this is a test of the Chatterbox voice.', 'en'),
                _testBtn('🇫🇷 French', 'Bonjour, ceci est un test de la voix.', 'fr'),
                _testBtn('🇩🇪 German', 'Hallo, dies ist ein Test der Stimme.', 'de'),
                _testBtn('🇪🇸 Spanish', 'Hola, esta es una prueba de la voz.', 'es'),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _testBtn(String label, String text, String langId) {
    return GestureDetector(
      onTap: _testingTts ? null : () => _testTts(text, langId),
      child: MouseRegion(
        cursor: _testingTts ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _testingTts ? C.level2 : C.level2,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: C.accent.withAlpha(40)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_testingTts)
              const SizedBox(width: 10, height: 10,
                child: CircularProgressIndicator(strokeWidth: 1, color: C.textMuted))
            else
              const Icon(Icons.volume_up_rounded, size: 10, color: C.accent),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 10, color: C.textSub)),
          ]),
        ),
      ),
    );
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  Widget _cbxSlider({
    required String label,
    required String desc,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    int? divisions,
    bool isInt = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        SizedBox(width: 110, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
          Text(desc, style: const TextStyle(fontSize: 10, color: C.textSub)),
        ])),
        Expanded(child: SliderTheme(
          data: SliderThemeData(
            activeTrackColor: C.accent,
            inactiveTrackColor: C.level2,
            thumbColor: C.accent,
            overlayColor: C.accent.withAlpha(30),
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min, max: max,
            divisions: divisions ?? ((max - min) * 20).round(),
            onChanged: onChanged,
          ),
        )),
        SizedBox(width: 36, child: Text(
          isInt ? value.round().toString() : value.toStringAsFixed(2),
          style: const TextStyle(fontSize: 11, color: C.accent, fontWeight: FontWeight.w600),
          textAlign: TextAlign.right,
        )),
      ]),
    );
  }

  Widget _cbxPresets() {
    return Row(children: [
      const Text('Presets:', style: TextStyle(fontSize: 11, color: C.textSub)),
      const SizedBox(width: 8),
      _presetBtn('Natural', 0.5, 0.5, 0.8, 50),
      const SizedBox(width: 6),
      _presetBtn('Expressive', 0.7, 0.5, 0.85, 50),
      const SizedBox(width: 6),
      _presetBtn('Smooth', 0.4, 0.3, 0.7, 75),
    ]);
  }

  Widget _presetBtn(String label, double exag, double cfg, double temp, int ctx) {
    final isActive = widget.settings.cbxExaggeration == exag &&
        widget.settings.cbxCfgWeight == cfg &&
        widget.settings.cbxTemperature == temp &&
        widget.settings.cbxContextWindow == ctx;
    return GestureDetector(
      onTap: () => setState(() {
        widget.settings.cbxExaggeration = exag;
        widget.settings.cbxCfgWeight = cfg;
        widget.settings.cbxTemperature = temp;
        widget.settings.cbxContextWindow = ctx;
        widget.settings.save();
      }),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? C.accent.withAlpha(20) : C.level1,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isActive ? C.accent.withAlpha(60) : C.level2),
          ),
          child: Text(label, style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w500,
            color: isActive ? C.accent : C.textSub,
          )),
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

class _DebugPanel extends StatefulWidget {
  const _DebugPanel();
  @override
  State<_DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<_DebugPanel> {
  bool _expanded = false;
  bool _autoScroll = true;
  bool _copied = false;
  String _filter = 'ALL'; // ALL, ERROR, WARN, or source tag
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

  // Memory stats (polled every 10s when expanded)
  String _vramInfo = '';
  String _ramInfo = '';
  Timer? _memTimer;

  static const _sourceFilters = ['ALL', 'ERROR', 'WARN', 'STT', 'TTS', 'TRANSLATE', 'CAPTURE', 'SIDECAR', 'ACCUM', 'PIPELINE'];

  @override
  void dispose() {
    _tickSub.cancel();
    _memTimer?.cancel();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _startMemPolling() {
    _memTimer?.cancel();
    _fetchMemory();
    _memTimer = Timer.periodic(const Duration(seconds: 10), (_) => _fetchMemory());
  }

  void _stopMemPolling() {
    _memTimer?.cancel();
    _memTimer = null;
  }

  Future<void> _fetchMemory() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await c.getUrl(Uri.parse('http://127.0.0.1:8179/tts/memory'));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      final body = await resp.transform(utf8.decoder).join();
      c.close();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data.containsKey('error') && data['gpu'] == null) return;
      final gpu = data['gpu'] as Map<String, dynamic>? ?? {};
      final ram = data['ram'] as Map<String, dynamic>? ?? {};
      if (mounted) {
        setState(() {
          final allocGb = gpu['vram_allocated_gb'] ?? 0;
          final totalGb = gpu['vram_total_gb'] ?? 0;
          final freeGb = gpu['vram_free_gb'] ?? 0;
          _vramInfo = 'VRAM: ${allocGb}GB / ${totalGb}GB (${freeGb}GB free)';
          _ramInfo = 'RAM: ${ram['rss_mb'] ?? 0}MB';
        });
      }
    } catch (_) {}
  }

  List<LogEntry> get _filtered {
    var logs = LogBuffer.entries;
    if (_filter == 'ERROR') {
      logs = logs.where((e) => e.level == 'ERROR').toList();
    } else if (_filter == 'WARN') {
      logs = logs.where((e) => e.level == 'WARN' || e.level == 'ERROR').toList();
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
    final logs = _filtered.map((e) => '[${e.ts}] ${e.message}').join('\n');
    Clipboard.setData(ClipboardData(text: logs.isEmpty ? '(no logs)' : logs));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _export() async {
    final logs = LogBuffer.entries.map((e) => '[${e.ts}] [${e.level}] ${e.message}').join('\n');
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
    final home = Platform.environment['HOME'] ?? '/tmp';
    final path = '$home/.config/talkye/logs/debug_$ts.log';
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(logs);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved to $path', style: const TextStyle(fontSize: 12)),
          backgroundColor: C.level3,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Export failed: $e', style: const TextStyle(fontSize: 12)),
          backgroundColor: C.error,
        ));
      }
    }
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'ERROR': return C.error;
      case 'WARN': return C.warning;
      default: return C.textSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Poll for new logs
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
    final errorCount = LogBuffer.entries.where((e) => e.level == 'ERROR').length;
    final warnCount = LogBuffer.entries.where((e) => e.level == 'WARN').length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(10)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Header — always visible
        GestureDetector(
          onTap: () {
            setState(() => _expanded = !_expanded);
            if (_expanded) {
              _startMemPolling();
            } else {
              _stopMemPolling();
            }
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Icon(_expanded ? Icons.terminal_rounded : Icons.bug_report_rounded,
                  size: 14, color: C.textSub),
                const SizedBox(width: 10),
                const Text('Debug Console',
                  style: TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                if (errorCount > 0) _badge('$errorCount', C.error),
                if (errorCount > 0) const SizedBox(width: 4),
                if (warnCount > 0) _badge('$warnCount', C.warning),
                const Spacer(),
                Text('${LogBuffer.length} lines',
                  style: const TextStyle(fontSize: 10, color: C.textMuted)),
                const SizedBox(width: 8),
                Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 16, color: C.textMuted),
              ]),
            ),
          ),
        ),
        // Expanded panel
        if (_expanded) ...[
          // Memory stats bar
          if (_vramInfo.isNotEmpty) ...[
            Container(height: 1, color: C.level2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              child: Row(children: [
                const Icon(Icons.memory_rounded, size: 12, color: C.accent),
                const SizedBox(width: 6),
                Text(_vramInfo, style: const TextStyle(fontSize: 10, color: C.textSub, fontFamily: 'monospace')),
                const SizedBox(width: 12),
                const Icon(Icons.developer_board_rounded, size: 12, color: C.textMuted),
                const SizedBox(width: 4),
                Text(_ramInfo, style: const TextStyle(fontSize: 10, color: C.textSub, fontFamily: 'monospace')),
              ]),
            ),
          ],
          Container(height: 1, color: C.level2),
          // Toolbar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(children: [
              // Filter chips
              Expanded(child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: _sourceFilters.map((f) {
                  final active = _filter == f;
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: GestureDetector(
                      onTap: () => setState(() => _filter = f),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: active ? C.accent.withAlpha(20) : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: active ? C.accent.withAlpha(60) : C.level3),
                          ),
                          child: Text(f, style: TextStyle(
                            fontSize: 9, fontWeight: FontWeight.w500,
                            color: f == 'ERROR' ? C.error : f == 'WARN' ? C.warning : active ? C.accent : C.textMuted,
                          )),
                        ),
                      ),
                    ),
                  );
                }).toList()),
              )),
              // Actions
              _iconBtn(Icons.content_copy_rounded, _copied ? C.success : C.textMuted, _copy),
              _iconBtn(Icons.save_alt_rounded, C.textMuted, _export),
              _iconBtn(Icons.delete_outline_rounded, C.textMuted, () {
                LogBuffer.clear();
                setState(() {});
              }),
              _iconBtn(
                _autoScroll ? Icons.vertical_align_bottom_rounded : Icons.pause_rounded,
                _autoScroll ? C.accent : C.textMuted,
                () => setState(() => _autoScroll = !_autoScroll),
              ),
            ]),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Container(
              height: 28,
              decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(6)),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 11, color: C.text, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: 'Search logs...',
                  hintStyle: TextStyle(fontSize: 11, color: C.textMuted),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  prefixIcon: Icon(Icons.search_rounded, size: 14, color: C.textMuted),
                  prefixIconConstraints: BoxConstraints(minWidth: 30),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Log lines
          SizedBox(
            height: 280,
            child: logs.isEmpty
              ? const Center(child: Text('No matching logs', style: TextStyle(fontSize: 11, color: C.textMuted)))
              : ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: logs.length,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemBuilder: (_, i) {
                    final e = logs[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 72, child: Text(
                          e.ts,
                          style: const TextStyle(fontSize: 10, color: C.textMuted, fontFamily: 'monospace'),
                        )),
                        if (e.level != 'INFO')
                          Container(
                            margin: const EdgeInsets.only(right: 4, top: 1),
                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                            decoration: BoxDecoration(
                              color: _levelColor(e.level).withAlpha(20),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(e.level, style: TextStyle(
                              fontSize: 8, fontWeight: FontWeight.w600,
                              color: _levelColor(e.level),
                            )),
                          ),
                        Expanded(child: Text(
                          e.message,
                          style: TextStyle(
                            fontSize: 10, fontFamily: 'monospace', height: 1.4,
                            color: e.level == 'ERROR' ? C.error : e.level == 'WARN' ? C.warning : C.textSub,
                          ),
                        )),
                      ]),
                    );
                  },
                ),
          ),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w600)),
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
