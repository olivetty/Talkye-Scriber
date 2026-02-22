import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import '../theme.dart';
import '../main.dart';
import '../src/rust/api/engine.dart';

// Processing status messages — cycles through these for a techy feel
const _processingSteps = [
  'Analyzing vocal patterns...',
  'Extracting spectral features...',
  'Mapping neural voice embeddings...',
  'Encoding through Mimi codec...',
  'Splitting harmonic frequencies...',
  'Calibrating prosody model...',
  'Synthesizing voice signature...',
  'Generating preview...',
];

// Teleprompter text — phonetically diverse, natural English, ~75 words for 30s
const _promptText =
  'The morning sun cast a warm golden light across the quiet village. '
  'Birds sang softly in the trees while a gentle breeze carried the scent '
  'of fresh coffee through the open windows. She picked up her notebook '
  'and began writing, capturing every thought before it could slip away. '
  'The world outside was waking up slowly, and she smiled knowing the best '
  'part of the day was just beginning.';

class VoiceScreen extends StatefulWidget {
  final String activeVoicePath;
  final ValueChanged<String> onVoiceChanged;
  const VoiceScreen({super.key, required this.activeVoicePath, required this.onVoiceChanged});
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

enum _Step { idle, countdown, recording, processing, naming, done, error }

class _VoiceScreenState extends State<VoiceScreen> {
  List<FfiVoiceInfo> _voices = [];
  _Step _step = _Step.idle;
  String _newName = '';
  static const double _recordDuration = 30.0;
  double _elapsed = 0;
  int _highlightWord = 0;
  int _countdownValue = 3;
  Timer? _timer;
  String? _errorMsg;
  String? _previewingPath;
  // Temp name for recording (renamed after user picks a name)
  String _tempName = '';
  // Paths produced during processing
  String _tempStPath = '';
  // Generation counter — ignore stale futures after cancel
  int _generation = 0;
  // Processing step animation
  int _processingStep = 0;
  Timer? _processingTimer;

  late final List<String> _words;

  @override
  void initState() {
    super.initState();
    _words = _promptText.split(' ');
    _loadVoices();
  }

  void _loadVoices() => setState(() => _voices = listVoices());
  String get _activePath => widget.activeVoicePath;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Voice Clone',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: C.text, letterSpacing: -0.5)),
        const SizedBox(height: 8),
        const Text('Create custom voices for your translations.',
          style: TextStyle(fontSize: 13, color: C.textSub)),
        const SizedBox(height: 24),
        if (_errorMsg != null) _errorBanner(),
        Expanded(child: _step == _Step.idle ? _voiceList() : _activeFlow()),
      ]),
    );
  }

  // ── Voice List ──

  // Built-in voices (not deletable)
  static final _builtinDir = '${voicesDir()}/builtin';
  static final _builtinVoices = [
    ('Cosette', 'Female · Natural English', '$_builtinDir/cosette.safetensors'),
    ('Marius', 'Male · Natural English', '$_builtinDir/marius.safetensors'),
  ];

  Widget _voiceList() {
    return ListView(children: [
      // Standard voices section
      const Text('STANDARD VOICES',
        style: TextStyle(fontSize: 11, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 10),
      for (final v in _builtinVoices) ...[
        _voiceCard(name: v.$1, desc: v.$2, path: v.$3,
          isBuiltin: true, isActive: _activePath == v.$3),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 20),
      // My voices section
      const Text('MY VOICES',
        style: TextStyle(fontSize: 11, color: C.textMuted, fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 10),
      if (_voices.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('No cloned voices yet.', style: TextStyle(fontSize: 12, color: C.textMuted.withAlpha(120)))),
      for (final v in _voices)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: _voiceCard(
          name: v.name, path: v.path,
          desc: _voiceDesc(v),
          isBuiltin: false, isActive: _activePath == v.path,
        )),
      const SizedBox(height: 8),
      _addButton(),
    ]);
  }

  Widget _voiceCard({
    required String name, required String desc, required String path,
    bool isBuiltin = false, bool isActive = false,
  }) {
    final isPreviewing = _previewingPath == path;
    final hasCbx = !isBuiltin && _hasCbxVoice(path);
    final hasPocket = !isBuiltin && (path.endsWith('.safetensors') || File(path.replaceAll(RegExp(r'\.[^.]+$'), '.safetensors')).existsSync());
    return _HoverCard(
      onTap: () => widget.onVoiceChanged(path),
      isActive: isActive,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(
              color: (isActive ? C.accent : C.textMuted).withAlpha(20),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(isBuiltin ? Icons.graphic_eq_rounded : Icons.record_voice_over_rounded,
              size: 20, color: isActive ? C.accent : C.textMuted),
          ),
          const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name[0].toUpperCase() + name.substring(1),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: C.text)),
          const SizedBox(height: 2),
          Text(desc, style: const TextStyle(fontSize: 12, color: C.textSub)),
        ])),
        if (!isBuiltin) Row(mainAxisSize: MainAxisSize.min, children: [
          _SmallBtn(icon: Icons.play_arrow_rounded, tooltip: 'Preview',
            loading: isPreviewing, onTap: () => _preview(path)),
          const SizedBox(width: 4),
          _SmallBtn(icon: Icons.delete_outline_rounded, tooltip: 'Delete',
            onTap: () => _deleteVoice(path, name)),
        ]),
        if (isActive)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: C.success.withAlpha(15), borderRadius: BorderRadius.circular(6)),
            child: const Text('Active', style: TextStyle(fontSize: 10, color: C.success, fontWeight: FontWeight.w600)),
          ),
      ]),
        // Engine readiness badges for custom voices
        if (!isBuiltin) ...[
          const SizedBox(height: 8),
          Row(children: [
            const SizedBox(width: 54), // align with text
            _engineBadge('Pocket', hasPocket, Icons.memory_rounded),
            const SizedBox(width: 6),
            _engineBadge('Chatterbox', hasCbx, Icons.graphic_eq_rounded),
            if (!hasCbx && _hasRawWav(path)) ...[
              const SizedBox(width: 8),
              _prepareBtn(path, name),
            ],
          ]),
        ],
      ]),
    );
  }

  String _voiceDesc(FfiVoiceInfo v) {
    final hasCbx = _hasCbxVoice(v.path);
    final hasPocket = v.isPrecomputed;
    if (hasPocket && hasCbx) return 'Cloned · Both engines ready';
    if (hasPocket) return 'Cloned · Pocket ready';
    if (hasCbx) return 'Cloned · Chatterbox ready';
    return 'Raw recording';
  }

  bool _hasCbxVoice(String path) {
    final stem = path.replaceAll(RegExp(r'\.[^.]+$'), '');
    return File('${stem}_cbx.wav').existsSync();
  }

  bool _hasRawWav(String path) {
    final stem = path.replaceAll(RegExp(r'\.[^.]+$'), '');
    return File('$stem.wav').existsSync();
  }

  Widget _engineBadge(String label, bool ready, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (ready ? C.success : C.textMuted).withAlpha(15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ready ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 10, color: ready ? C.success : C.textMuted),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 9, color: ready ? C.success : C.textMuted,
          fontWeight: FontWeight.w500)),
      ]),
    );
  }

  bool _preparingCbx = false;

  Widget _prepareBtn(String path, String name) {
    return GestureDetector(
      onTap: _preparingCbx ? null : () async {
        final stem = path.replaceAll(RegExp(r'\.[^.]+$'), '');
        final wavPath = '$stem.wav';
        setState(() => _preparingCbx = true);
        try {
          final result = prepareCbxVoice(wavPath: wavPath);
          if (result.startsWith('ERROR')) {
            setState(() => _errorMsg = result);
          } else {
            LogBuffer.add('CBX voice prepared for $name: $result');
          }
        } catch (e) {
          setState(() => _errorMsg = 'Prepare failed: $e');
        }
        if (mounted) setState(() => _preparingCbx = false);
      },
      child: MouseRegion(
        cursor: _preparingCbx ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: C.accent.withAlpha(20),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_preparingCbx)
              const SizedBox(width: 10, height: 10,
                child: CircularProgressIndicator(strokeWidth: 1, color: C.accent))
            else
              const Icon(Icons.auto_fix_high_rounded, size: 10, color: C.accent),
            const SizedBox(width: 3),
            Text(_preparingCbx ? 'Preparing...' : 'Optimize for Chatterbox',
              style: const TextStyle(fontSize: 9, color: C.accent, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  Widget _addButton() {
    return _HoverCard(
      onTap: _startCloneFlow,
      child: const Center(child: Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text('Clone Your Voice',
          style: TextStyle(fontSize: 13, color: C.textSub, fontWeight: FontWeight.w500)),
      )),
    );
  }

  // ── Clone Flow: countdown → recording → processing → naming → done ──

  void _startCloneFlow() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _tempName = '_temp_clone_$ts';
    _generation++;
    setState(() { _step = _Step.countdown; _countdownValue = 3; _errorMsg = null; });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_countdownValue <= 1) {
        t.cancel();
        _startRecording();
      } else {
        setState(() => _countdownValue--);
      }
    });
  }

  void _cancelFlow() {
    final gen = _generation;
    _generation++; // invalidate any in-flight futures
    _timer?.cancel();
    _stopProcessingAnim();
    setState(() { _step = _Step.idle; });
    // Clean up temp files in background
    _cleanupTemp(_tempName, gen);
  }

  Future<void> _cleanupTemp(String tempName, int gen) async {
    final dir = voicesDir();
    final base = '$dir/$tempName';
    for (final ext in ['.wav', '.safetensors', '_cbx.wav', '_preview.wav']) {
      try { await File('$base$ext').delete(); } catch (_) {}
    }
  }

  void _startRecording() {
    final gen = _generation;
    setState(() { _step = _Step.recording; _elapsed = 0; _highlightWord = 0; });

    final msPerWord = (1000 / 2.8).round();
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: msPerWord), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _highlightWord = t.tick.clamp(0, _words.length);
        _elapsed = (t.tick * msPerWord / 1000).clamp(0, _recordDuration);
      });
      if (t.tick >= _words.length) t.cancel();
    });

    recordVoice(name: _tempName, durationSecs: _recordDuration).then((result) {
      _timer?.cancel();
      if (!mounted || _generation != gen) return; // cancelled
      if (result.startsWith('ERROR')) {
        _stopProcessingAnim();
        setState(() { _step = _Step.error; _errorMsg = result; });
        return;
      }
      setState(() => _step = _Step.processing);
      _startProcessingAnim();
      precomputeVoice(wavPath: result).then((stPath) {
        if (!mounted || _generation != gen) return;
        if (stPath.startsWith('ERROR')) {
          _stopProcessingAnim();
          setState(() { _step = _Step.error; _errorMsg = stPath; });
          return;
        }
        _tempStPath = stPath;
        // Also prepare Chatterbox-optimized voice (normalized, trimmed)
        prepareCbxVoice(wavPath: result).then((cbxPath) {
          if (mounted && _generation == gen) {
            if (cbxPath.startsWith('ERROR')) {
              LogBuffer.add('CBX voice prep warning: $cbxPath');
            } else {
              LogBuffer.add('CBX voice ready: $cbxPath');
            }
          }
        }).catchError((e) {
          LogBuffer.add('CBX voice prep error: $e');
        });
        // Generate preview (TTS model already warm)
        previewVoice(voicePath: stPath).then((_) {
          if (!mounted || _generation != gen) return;
          _stopProcessingAnim();
          setState(() => _step = _Step.naming);
        }).catchError((e) {
          _stopProcessingAnim();
          if (mounted && _generation == gen) setState(() => _step = _Step.naming);
        });
      });
    });
  }

  // ── Rename temp files to final name ──

  void _startProcessingAnim() {
    _processingStep = 0;
    _processingTimer?.cancel();
    _processingTimer = Timer.periodic(const Duration(milliseconds: 2200), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _processingStep = (t.tick) % _processingSteps.length);
    });
  }

  void _stopProcessingAnim() {
    _processingTimer?.cancel();
    _processingTimer = null;
  }

  Future<void> _finalizeName(String name) async {
    final dir = voicesDir();
    final oldBase = '$dir/$_tempName';
    final newBase = '$dir/$name';
    try {
      // Rename: wav, safetensors, cbx.wav, preview
      for (final ext in ['.wav', '.safetensors', '_cbx.wav']) {
        final old = File('$oldBase$ext');
        if (await old.exists()) await old.rename('$newBase$ext');
      }
      final oldPreview = File('${oldBase}_preview.wav');
      if (await oldPreview.exists()) await oldPreview.rename('${newBase}_preview.wav');

      final finalPath = '$newBase.safetensors';
      setState(() { _newName = name; _step = _Step.done; });
      _loadVoices();
      widget.onVoiceChanged(finalPath);
    } catch (e) {
      setState(() { _step = _Step.error; _errorMsg = 'Rename failed: $e'; });
    }
  }

  // ── Active Flow UI ──

  Widget _activeFlow() {
    if (_step == _Step.countdown) return _countdownUI();
    if (_step == _Step.recording) return _teleprompterUI();
    if (_step == _Step.processing) return _processingUI();
    if (_step == _Step.naming) return _namingUI();
    if (_step == _Step.done) return _doneUI();
    return _errorUI();
  }

  Widget _countdownUI() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.mic_rounded, size: 48, color: C.accent),
      const SizedBox(height: 20),
      const Text('Get ready to read aloud',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text)),
      const SizedBox(height: 8),
      const Text('Speak clearly at a natural pace',
        style: TextStyle(fontSize: 13, color: C.textSub)),
      const SizedBox(height: 32),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text('$_countdownValue', key: ValueKey(_countdownValue),
          style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w700, color: C.accent)),
      ),
      const SizedBox(height: 32),
      TextButton(
        onPressed: _cancelFlow,
        style: TextButton.styleFrom(backgroundColor: C.level2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        child: const Text('Cancel', style: TextStyle(color: C.textSub, fontSize: 13, fontWeight: FontWeight.w500)),
      ),
    ]));
  }

  Widget _teleprompterUI() {
    final progress = _elapsed / _recordDuration;
    return Column(children: [
      Row(children: [
        const Icon(Icons.mic_rounded, size: 16, color: C.error),
        const SizedBox(width: 6),
        const Text('Recording', style: TextStyle(fontSize: 12, color: C.error, fontWeight: FontWeight.w600)),
        const Spacer(),
        Text('${_elapsed.toStringAsFixed(0)}s / ${_recordDuration.toInt()}s',
          style: const TextStyle(fontSize: 12, color: C.textMuted,
            fontFeatures: [FontFeature.tabularFigures()])),
      ]),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: progress, minHeight: 4,
          backgroundColor: C.level2, valueColor: AlwaysStoppedAnimation(C.accent)),
      ),
      const SizedBox(height: 24),
      Expanded(child: SingleChildScrollView(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(color: C.level1, borderRadius: BorderRadius.circular(16)),
        child: Wrap(
          spacing: 6, runSpacing: 6,
          children: List.generate(_words.length, (i) {
            final isPast = i < _highlightWord;
            final isCurrent = i == _highlightWord;
            final active = isCurrent || isPast;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isCurrent ? C.accent.withAlpha(30)
                  : isPast ? C.level2
                  : C.level2.withAlpha(80),
                borderRadius: BorderRadius.circular(6)),
              child: Text(_words[i],
                style: TextStyle(
                  fontSize: 16, height: 1.3,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
                  color: isCurrent ? C.accent
                    : isPast ? C.textSub
                    : C.textMuted.withAlpha(80),
                )),
            );
          }),
        ),
      ))),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text('Read the text above at a comfortable pace',
          style: TextStyle(fontSize: 11, color: C.textMuted.withAlpha(120))),
        const SizedBox(width: 16),
        TextButton(
          onPressed: _cancelFlow,
          style: TextButton.styleFrom(backgroundColor: C.level2,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Cancel', style: TextStyle(color: C.textSub, fontSize: 11, fontWeight: FontWeight.w500)),
        ),
      ]),
    ]);
  }

  Widget _processingUI() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 180, height: 180,
        child: Lottie.asset('assets/vui-animation.json', fit: BoxFit.contain)),
      const SizedBox(height: 16),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: Text(_processingSteps[_processingStep],
          key: ValueKey(_processingStep),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: C.text)),
      ),
    ]));
  }

  Widget _namingUI() {
    final controller = TextEditingController();
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle_rounded, size: 48, color: C.success),
      const SizedBox(height: 16),
      const Text('Voice recorded!', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text)),
      const SizedBox(height: 8),
      const Text('Give your voice a name to save it.',
        style: TextStyle(fontSize: 13, color: C.textSub)),
      const SizedBox(height: 24),
      SizedBox(width: 260, child: TextField(
        controller: controller, autofocus: true,
        style: const TextStyle(color: C.text, fontSize: 14),
        textAlign: TextAlign.center,
        onSubmitted: (v) {
          final name = v.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
          if (name.isNotEmpty) _finalizeName(name);
        },
        decoration: InputDecoration(
          hintText: 'e.g. My Voice',
          hintStyle: TextStyle(color: C.textMuted.withAlpha(100)),
          filled: true, fillColor: C.level1,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        ),
      )),
      const SizedBox(height: 16),
      Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
          onPressed: () { _cancelFlow(); _cleanupTemp(_tempName, _generation); },
          style: TextButton.styleFrom(backgroundColor: C.level2,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('Discard', style: TextStyle(color: C.textSub, fontSize: 13, fontWeight: FontWeight.w500)),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () {
            final name = controller.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
            if (name.isNotEmpty) _finalizeName(name);
          },
          style: TextButton.styleFrom(backgroundColor: C.accent.withAlpha(30),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('Save', style: TextStyle(color: C.accent, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ]),
    ]));
  }

  Widget _doneUI() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle_rounded, size: 48, color: C.success),
      const SizedBox(height: 16),
      Text('Voice "$_newName" ready!', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text)),
      const SizedBox(height: 8),
      const Text('Your cloned voice is now active.', style: TextStyle(fontSize: 13, color: C.textSub)),
      const SizedBox(height: 24),
      TextButton(
        onPressed: () => setState(() { _step = _Step.idle; _loadVoices(); }),
        style: TextButton.styleFrom(backgroundColor: C.accent.withAlpha(30)),
        child: const Text('Back to Voices', style: TextStyle(color: C.accent, fontWeight: FontWeight.w600)),
      ),
    ]));
  }

  Widget _errorUI() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline_rounded, size: 48, color: C.error),
      const SizedBox(height: 16),
      const Text('Something went wrong', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text)),
      const SizedBox(height: 8),
      Text(_errorMsg ?? 'Unknown error', style: const TextStyle(fontSize: 13, color: C.textSub), textAlign: TextAlign.center),
      const SizedBox(height: 24),
      TextButton(
        onPressed: () => setState(() { _step = _Step.idle; _loadVoices(); }),
        style: TextButton.styleFrom(backgroundColor: C.accent.withAlpha(30)),
        child: const Text('Back to Voices', style: TextStyle(color: C.accent, fontWeight: FontWeight.w600)),
      ),
    ]));
  }

  // ── Actions ──

  Future<void> _preview(String path) async {
    if (_previewingPath != null) return;
    setState(() => _previewingPath = path);
    try {
      final stem = path.replaceAll(RegExp(r'\.[^.]+$'), '');
      final cachedPreview = '${stem}_preview.wav';
      final played = await playPreview(previewWavPath: cachedPreview);
      if (!played && mounted) {
        final result = await previewVoice(voicePath: path);
        if (result.startsWith('ERROR') && mounted) {
          setState(() => _errorMsg = result);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _errorMsg = 'Preview error: $e');
    } finally {
      if (mounted) setState(() => _previewingPath = null);
    }
  }

  void _deleteVoice(String path, String name) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: C.level3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Delete "$name"?', style: const TextStyle(fontSize: 16, color: C.text)),
      content: const Text('This will remove the voice permanently.',
        style: TextStyle(fontSize: 13, color: C.textSub)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel', style: TextStyle(color: C.textSub))),
        TextButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await deleteVoice(voicePath: path);
            if (_activePath == path) widget.onVoiceChanged('');
            _loadVoices();
          },
          style: TextButton.styleFrom(backgroundColor: C.error.withAlpha(30)),
          child: const Text('Delete', style: TextStyle(color: C.error, fontWeight: FontWeight.w600)),
        ),
      ],
    ));
  }

  Widget _errorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.error.withAlpha(15), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, color: C.error, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(_errorMsg!, style: const TextStyle(color: C.error, fontSize: 12),
          maxLines: 2, overflow: TextOverflow.ellipsis)),
        IconButton(icon: const Icon(Icons.close_rounded, size: 14),
          onPressed: () => setState(() => _errorMsg = null), splashRadius: 14),
      ]),
    );
  }

  @override
  void dispose() { _timer?.cancel(); _processingTimer?.cancel(); super.dispose(); }
}

// ── Reusable widgets ──

class _HoverCard extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  final bool isActive;
  const _HoverCard({required this.onTap, required this.child, this.isActive = false});
  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final bg = widget.isActive ? C.accent.withAlpha(12)
      : _hovered ? C.level2 : C.level1;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: widget.child,
        ),
      ),
    );
  }
}

class _SmallBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool loading;
  const _SmallBtn({required this.icon, required this.tooltip, required this.onTap, this.loading = false});
  @override
  State<_SmallBtn> createState() => _SmallBtnState();
}

class _SmallBtnState extends State<_SmallBtn> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.loading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Tooltip(message: widget.tooltip, child: GestureDetector(
        onTap: widget.loading ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _hovered ? C.level3 : Colors.transparent,
            borderRadius: BorderRadius.circular(8)),
          child: widget.loading
            ? const _Waveform(width: 16, height: 16, barCount: 3, color: C.textSub)
            : Icon(widget.icon, size: 16, color: _hovered ? C.text : C.textSub),
        ),
      )),
    );
  }
}

// ── Animated Waveform (replaces spinners) ──

class _Waveform extends StatefulWidget {
  final double width, height;
  final int barCount;
  final Color color;
  const _Waveform({required this.width, required this.height, required this.barCount, required this.color});
  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final gap = widget.width * 0.12 / (widget.barCount - 1).clamp(1, 99);
        final barW = (widget.width - gap * (widget.barCount - 1)) / widget.barCount;
        return SizedBox(width: widget.width, height: widget.height,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(widget.barCount, (i) {
              final phase = i * 0.7;
              final h = (0.3 + 0.7 * ((math.sin(_ctrl.value * 2 * math.pi + phase) + 1) / 2)) * widget.height;
              return Padding(
                padding: EdgeInsets.only(right: i < widget.barCount - 1 ? gap : 0),
                child: Container(width: barW, height: h,
                  decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(barW / 2))),
              );
            }),
          ),
        );
      },
    );
  }
}
