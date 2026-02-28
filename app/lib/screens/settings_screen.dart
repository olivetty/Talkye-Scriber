import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../main.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: C.text,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 24),
        // Audio + About side by side
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _miniSection('AUDIO', [
                _infoRow('Input', 'Default mic'),
                _infoRow('Output', 'Default speaker'),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _miniSection('ABOUT', [
                _infoRow('App', 'v0.3.0'),
                _infoRow('Sidecar', 'Python/Uvicorn'),
              ]),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          'DIAGNOSTICS',
          style: TextStyle(
            fontSize: 11,
            color: C.textMuted,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 10),
        const _DebugPanel(),
      ],
    );
  }

  Widget _miniSection(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.level1,
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
    final logs = _filtered.map((e) => '[${e.ts}] ${e.message}').join('\n');
    Clipboard.setData(ClipboardData(text: logs.isEmpty ? '(no logs)' : logs));
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

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: C.level1,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
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
                  color: C.bg,
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
                                    vertical: 0,
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
