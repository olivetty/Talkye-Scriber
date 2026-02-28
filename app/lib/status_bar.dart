import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'theme.dart';
import 'version.dart';
import 'updater.dart';

/// Global status bar shown at the bottom of every page.
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});
  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  Timer? _timer;
  int _ramMB = 0;
  double _cpuPct = 0;
  UpdateInfo? _updateInfo;
  bool _updating = false;
  double _updateProgress = 0;
  String _updateStatus = '';

  // Delta CPU tracking
  final Map<int, _CpuSample> _prev = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    final info = await checkForUpdate();
    if (info != null && mounted) {
      setState(() => _updateInfo = info);
    }
  }

  Future<void> _doUpdate() async {
    if (_updateInfo == null) return;
    setState(() => _updating = true);
    try {
      await performUpdate(_updateInfo!, (progress, status) {
        if (mounted) {
          setState(() {
            _updateProgress = progress;
            _updateStatus = status;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _updating = false;
          _updateStatus = 'Update failed: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    // App process tree (Flutter)
    final app = await _sampleTree(pid);
    // Sidecar process tree (port 8179)
    final sidecarPid = await _findPid('uvicorn.*server:app.*8179');
    final sidecar = sidecarPid != null ? await _sampleTree(sidecarPid) : null;

    if (!mounted) return;
    setState(() {
      _ramMB =
          ((app?.rssBytes ?? 0) + (sidecar?.rssBytes ?? 0)) ~/ (1024 * 1024);
      _cpuPct = (app?.cpuPct ?? 0) + (sidecar?.cpuPct ?? 0);
    });
  }

  static Future<int?> _findPid(String pattern) async {
    try {
      final r = await Process.run('pgrep', ['-f', pattern]);
      if (r.exitCode == 0) {
        return int.tryParse((r.stdout as String).trim().split('\n').first);
      }
    } catch (_) {}
    return null;
  }

  Future<_ProcStats?> _sampleTree(int rootPid) async {
    final pids = <int>[rootPid];
    try {
      final r = await Process.run('pgrep', ['-P', '$rootPid']);
      if (r.exitCode == 0) {
        for (final l in (r.stdout as String).trim().split('\n')) {
          final p = int.tryParse(l.trim());
          if (p != null) pids.add(p);
        }
      }
    } catch (_) {}

    var totalRss = 0, totalTicks = 0, valid = 0;
    for (final p in pids) {
      try {
        final statm = await File('/proc/$p/statm').readAsString();
        final rss = int.parse(statm.split(' ')[1]) * 4096;
        final stat = await File('/proc/$p/stat').readAsString();
        final f = stat.split(' ');
        final ticks = int.parse(f[13]) + int.parse(f[14]);
        totalRss += rss;
        totalTicks += ticks;
        valid++;
      } catch (_) {}
    }
    if (valid == 0) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = _prev[rootPid];
    double cpu = 0;
    if (prev != null) {
      final dt = now - prev.ts;
      if (dt > 0) cpu = ((totalTicks - prev.ticks) * 1000) / dt;
    }
    _prev[rootPid] = _CpuSample(ticks: totalTicks, ts: now);
    return _ProcStats(rssBytes: totalRss, cpuPct: cpu);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: const BoxDecoration(color: C.level1),
      child: Row(
        children: [
          _item(Icons.memory_rounded, '$_ramMB MB'),
          const SizedBox(width: 16),
          _item(Icons.speed_rounded, '${_cpuPct.toStringAsFixed(1)}%'),
          const Spacer(),
          if (_updating) ...[
            SizedBox(
              width: 60,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: _updateProgress > 0 ? _updateProgress : null,
                  minHeight: 3,
                  backgroundColor: C.level2,
                  valueColor: const AlwaysStoppedAnimation<Color>(C.accent),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _updateStatus,
              style: const TextStyle(fontSize: 10, color: C.textSub),
            ),
          ] else if (_updateInfo != null) ...[
            GestureDetector(
              onTap: _doUpdate,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: C.accent.withAlpha(20),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Update v${_updateInfo!.version}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: C.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            'Talkye Scriber v$appVersion',
            style: TextStyle(fontSize: 10, color: C.textSub.withAlpha(120)),
          ),
        ],
      ),
    );
  }

  Widget _item(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: C.textMuted),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: C.textSub,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

class _CpuSample {
  final int ticks, ts;
  const _CpuSample({required this.ticks, required this.ts});
}

class _ProcStats {
  final int rssBytes;
  final double cpuPct;
  const _ProcStats({required this.rssBytes, required this.cpuPct});
}
