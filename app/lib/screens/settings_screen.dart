import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../main.dart';
import '../src/rust/api/simple.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final bool engineRunning;
  const SettingsScreen({super.key, required this.settings, required this.onChanged, required this.engineRunning});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
