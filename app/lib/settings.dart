import 'package:flutter/material.dart';

/// Engine settings — persisted in state, sent to Rust at start.
class EngineSettings {
  String sttBackend;   // 'parakeet' | 'deepgram'

  EngineSettings({
    this.sttBackend = 'parakeet',
  });
}

/// Show settings bottom sheet. Returns updated settings or null if cancelled.
Future<EngineSettings?> showSettingsSheet(
  BuildContext context, {
  required EngineSettings current,
  required bool isDark,
}) {
  return showModalBottomSheet<EngineSettings>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _SettingsSheet(current: current, isDark: isDark),
  );
}

class _SettingsSheet extends StatefulWidget {
  final EngineSettings current;
  final bool isDark;
  const _SettingsSheet({required this.current, required this.isDark});
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late String _sttBackend;

  @override
  void initState() {
    super.initState();
    _sttBackend = widget.current.sttBackend;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = widget.isDark;
    final bg = isDark ? const Color(0xFF161616) : Colors.white;
    final subtle = isDark ? const Color(0xFF888888) : const Color(0xFF666666);
    final border = isDark ? const Color(0xFF222222) : const Color(0xFFE0E0E0);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: subtle.withAlpha(60),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text('Engine Settings',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ],
          ),
          const SizedBox(height: 20),
          Text('Speech Recognition', style: TextStyle(fontSize: 11, color: subtle, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          ...List.generate(2, (i) {
            final options = ['parakeet', 'deepgram'];
            final labels = ['🖥️ Parakeet (local)', '☁️ Deepgram (cloud)'];
            final descs = ['NVIDIA TDT v3 · 25 langs · free · ~200ms', 'Cloud streaming · fast · \$0.46/hr'];
            final selected = _sttBackend == options[i];
            final selBg = isDark ? cs.primary.withAlpha(15) : cs.primary.withAlpha(10);
            return GestureDetector(
              onTap: () => setState(() => _sttBackend = options[i]),
              child: Container(
                margin: EdgeInsets.only(bottom: i == 0 ? 6 : 0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? selBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? cs.primary.withAlpha(60) : border, width: selected ? 1.0 : 0.5),
                ),
                child: Row(children: [
                  Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    size: 16, color: selected ? cs.primary : subtle),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(labels[i], style: TextStyle(fontSize: 13, color: cs.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                    Text(descs[i], style: TextStyle(fontSize: 10, color: subtle)),
                  ])),
                ]),
              ),
            );
          }),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity, height: 44,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, EngineSettings(sttBackend: _sttBackend)),
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary.withAlpha(isDark ? 30 : 20),
                foregroundColor: cs.primary, elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: BorderSide(color: cs.primary.withAlpha(40)),
              ),
              child: const Text('Save', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
