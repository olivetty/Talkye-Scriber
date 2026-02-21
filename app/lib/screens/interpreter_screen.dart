import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../main.dart';
import '../src/rust/api/engine.dart';

// Languages supported for source (input) — autodetect + specific
const _sourceLangs = [
  ('', 'Autodetect'),
  ('English', 'English'),
  ('Romanian', 'Romanian'),
  ('Spanish', 'Spanish'),
  ('French', 'French'),
  ('German', 'German'),
  ('Italian', 'Italian'),
  ('Portuguese', 'Portuguese'),
  ('Dutch', 'Dutch'),
  ('Polish', 'Polish'),
  ('Russian', 'Russian'),
  ('Ukrainian', 'Ukrainian'),
  ('Japanese', 'Japanese'),
  ('Korean', 'Korean'),
  ('Chinese', 'Chinese'),
  ('Hindi', 'Hindi'),
  ('Arabic', 'Arabic'),
  ('Turkish', 'Turkish'),
];

// Languages supported for target (output) — English has voice cloning
const _targetLangs = [
  ('English', 'English', true),     // voice clone available
  ('Romanian', 'Romanian', false),
  ('Spanish', 'Spanish', false),
  ('French', 'French', false),
  ('German', 'German', false),
  ('Italian', 'Italian', false),
  ('Portuguese', 'Portuguese', false),
  ('Dutch', 'Dutch', false),
  ('Polish', 'Polish', false),
  ('Russian', 'Russian', false),
  ('Japanese', 'Japanese', false),
  ('Korean', 'Korean', false),
  ('Chinese', 'Chinese', false),
];

class InterpreterScreen extends StatefulWidget {
  final VoidCallback? onStateChanged;
  final AppSettings settings;
  const InterpreterScreen({super.key, this.onStateChanged, required this.settings});
  @override
  State<InterpreterScreen> createState() => InterpreterScreenState();
}

class InterpreterScreenState extends State<InterpreterScreen> {
  bool _running = false;
  String _status = 'Ready';
  final List<_Entry> _transcript = [];
  final ScrollController _scroll = ScrollController();
  String? _error;
  DateTime? _startTime;

  bool get isRunning => _running;

  void _toggle() => _running ? _stop() : _start();

  void _start() {
    setState(() { _running = true; _status = 'Loading...'; _error = null; _startTime = DateTime.now(); });
    widget.onStateChanged?.call();

    startEngine(config: FfiEngineConfig(
      sttBackend: widget.settings.sttBackend,
      sttLanguage: widget.settings.sourceLang,
      translateFrom: widget.settings.sourceLang.isEmpty ? '' : widget.settings.sourceLang,
      translateTo: widget.settings.targetLang,
      voicePath: widget.settings.targetLang == 'English' ? widget.settings.activeVoicePath : '',
      ttsSpeed: 0, groqApiKey: '', deepgramApiKey: '',
      hfToken: '', parakeetModelDir: '', vadModelPath: '', audioOutput: '',
    )).listen(
      (event) {
        if (!mounted) return;
        event.when(
          statusChanged: (status) {
            LogBuffer.add('STATUS: $status');
            setState(() => _status = status);
            if (status == 'Stopped' || status == 'Idle') {
              setState(() { _running = false; _startTime = null; });
              widget.onStateChanged?.call();
            }
          },
          transcript: (original, translated) {
            setState(() => _transcript.add(_Entry(original: original, translated: translated)));
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scroll.hasClients) {
                _scroll.animateTo(_scroll.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
              }
            });
          },
          error: (message) {
            LogBuffer.add('ERROR: $message');
            setState(() => _error = message);
          },
          log: (level, msg) => LogBuffer.add('$level: $msg'),
        );
      },
      onError: (e) { if (mounted) { setState(() { _error = '$e'; _running = false; _status = 'Error'; _startTime = null; }); widget.onStateChanged?.call(); } },
      onDone: () { if (mounted) { setState(() { _running = false; _status = 'Ready'; _startTime = null; }); widget.onStateChanged?.call(); } },
    );
  }

  void _stop() {
    stopEngine();
    setState(() { _running = false; _status = 'Ready'; _startTime = null; });
    widget.onStateChanged?.call();
  }

  void _clearTranscript() => setState(() => _transcript.clear());

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Live Interpreter',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: C.text, letterSpacing: -0.5)),
          const Spacer(),
          if (_transcript.isNotEmpty && !_running)
            _IconBtn(icon: Icons.delete_outline_rounded, tooltip: 'Clear', onTap: _clearTranscript),
          if (_startTime != null) ...[const SizedBox(width: 8), _Timer(start: _startTime!)],
        ]),
        const SizedBox(height: 20),
        _languageBar(),
        const SizedBox(height: 16),
        if (_error != null) _errorBar(),
        Expanded(child: _transcript.isEmpty ? _buildEmpty() : _buildList()),
        const SizedBox(height: 16),
        _bottomBar(),
      ]),
    );
  }

  Widget _languageBar() {
    final locked = _running;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.mic_rounded, size: 16, color: _running ? C.accent : C.textSub),
        const SizedBox(width: 6),
        _dropdown(
          value: widget.settings.sourceLang,
          items: _sourceLangs.map((e) => (e.$1, e.$2)).toList(),
          locked: locked,
          onChanged: (v) => setState(() { widget.settings.sourceLang = v; widget.settings.save(); }),
        ),
        const SizedBox(width: 8),
        Icon(Icons.arrow_forward_rounded, size: 16, color: C.accent.withAlpha(150)),
        const SizedBox(width: 8),
        Icon(Icons.volume_up_rounded, size: 16, color: _running ? C.info : C.textSub),
        const SizedBox(width: 6),
        // TODO: Re-enable target language dropdown when multi-language TTS is available
        // Currently pocket-tts only supports English output
        // _dropdown(
        //   value: widget.settings.targetLang,
        //   items: _targetLangs.map((e) => (e.$1, e.$2)).toList(),
        //   locked: locked,
        //   onChanged: (v) => setState(() {
        //     widget.settings.targetLang = v;
        //     if (v != 'English' && widget.settings.activeVoicePath.isNotEmpty) {
        //       widget.settings.activeVoicePath = '';
        //     }
        //     widget.settings.save();
        //   }),
        // ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
          child: const Text('English', style: TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w500)),
        ),
        if (widget.settings.activeVoicePath.isNotEmpty)
          Padding(padding: const EdgeInsets.only(left: 8),
            child: Icon(Icons.record_voice_over_rounded, size: 13, color: C.accent.withAlpha(120))),
        const Spacer(),
        _dropdown(
          value: widget.settings.sttBackend,
          items: const [('parakeet', 'Talkye Local'), ('deepgram', 'Talkye Max')],
          locked: locked,
          onChanged: (v) => setState(() { widget.settings.sttBackend = v; widget.settings.save(); }),
          small: true,
        ),
      ]),
    );
  }

  Widget _dropdown({
    required String value,
    required List<(String, String)> items,
    required bool locked,
    required ValueChanged<String> onChanged,
    bool small = false,
  }) {
    return PopupMenuButton<String>(
      enabled: !locked,
      onSelected: onChanged,
      offset: const Offset(0, 36),
      color: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) => items.map((e) => PopupMenuItem(
        value: e.$1,
        height: 36,
        child: Text(e.$2, style: TextStyle(fontSize: 12, color: e.$1 == value ? C.accent : C.text,
          fontWeight: e.$1 == value ? FontWeight.w600 : FontWeight.w400)),
      )).toList(),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 8 : 10, vertical: 4),
        decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(items.firstWhere((e) => e.$1 == value, orElse: () => items.first).$2,
            style: TextStyle(fontSize: small ? 10 : 12, color: locked ? C.textMuted : C.text,
              fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          Icon(Icons.expand_more_rounded, size: small ? 12 : 14, color: C.textMuted),
        ]),
      ),
    );
  }

  Widget _errorBar() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.error.withAlpha(15), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, color: C.error, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(_error!, style: const TextStyle(color: C.error, fontSize: 12),
          maxLines: 2, overflow: TextOverflow.ellipsis)),
        IconButton(icon: const Icon(Icons.close_rounded, size: 14),
          onPressed: () => setState(() => _error = null), splashRadius: 14),
      ]),
    );
  }

  Widget _bottomBar() {
    return Row(children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: _dotColor)),
      const SizedBox(width: 8),
      Text(_status, style: TextStyle(color: _dotColor, fontSize: 12, fontWeight: FontWeight.w500)),
      const Spacer(),
      SizedBox(height: 40, child: TextButton(
        onPressed: _toggle,
        style: TextButton.styleFrom(
          backgroundColor: (_running ? C.error : C.accent).withAlpha(30),
          foregroundColor: _running ? C.error : C.accent,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        child: Text(_running ? 'Stop' : 'Start',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      )),
    ]);
  }

  Color get _dotColor {
    switch (_status) {
      case 'Listening': return C.success;
      case 'Translating': return C.warning;
      case 'Speaking': return C.info;
      case 'Loading': case 'Loading...': return C.orange;
      default: return C.textMuted;
    }
  }

  Widget _buildEmpty() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(_running ? Icons.hearing_rounded : Icons.translate_rounded, size: 48, color: C.textMuted.withAlpha(60)),
    const SizedBox(height: 12),
    Text(_running ? 'Listening for speech...' : 'Start the interpreter to begin',
      style: TextStyle(color: C.textMuted.withAlpha(120), fontSize: 13)),
  ]));

  Widget _buildList() => Container(
    decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(12)),
    child: ListView.builder(
      controller: _scroll, padding: const EdgeInsets.all(16),
      itemCount: _transcript.length,
      itemBuilder: (_, i) {
        final e = _transcript[i];
        return Opacity(opacity: i >= _transcript.length - 3 ? 1.0 : 0.5,
          child: Padding(padding: const EdgeInsets.only(bottom: 16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.original, style: const TextStyle(color: C.textSub, fontSize: 12, height: 1.5)),
              const SizedBox(height: 3),
              Text(e.translated, style: const TextStyle(color: C.text, fontSize: 14, fontWeight: FontWeight.w500, height: 1.5)),
            ])));
      },
    ),
  );

  @override
  void dispose() { if (_running) stopEngine(); _scroll.dispose(); super.dispose(); }
}

class _Entry {
  final String original, translated;
  _Entry({required this.original, required this.translated});
}

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.tooltip, required this.onTap});
  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(message: widget.tooltip, child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _hovered ? C.level2 : Colors.transparent,
            borderRadius: BorderRadius.circular(8)),
          child: Icon(widget.icon, size: 18, color: _hovered ? C.text : C.textSub),
        ),
      )),
    );
  }
}

class _Timer extends StatelessWidget {
  final DateTime start;
  const _Timer({required this.start});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (_, __) {
        final d = DateTime.now().difference(start);
        final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
        final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        final t = d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: C.accent.withAlpha(15), borderRadius: BorderRadius.circular(8)),
          child: Text(t, style: const TextStyle(fontSize: 12, color: C.accent,
            fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
        );
      },
    );
  }
}
