import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'version.dart';

const _repoOwner = 'olivetty';
const _repoName = 'Talkye-Scriber';

/// Primary CDN for fast downloads; GitHub Releases as fallback.
const _cdnBase = 'https://cdn.talkye.com';
const _appImageName = 'TalkyeScriber-x86_64.AppImage';

/// Detect install type: "deb", "appimage", or "dev"
String get installType {
  if (Platform.environment['TALKYE_INSTALL_TYPE'] == 'deb') return 'deb';
  if (Platform.environment['APPIMAGE'] != null) return 'appimage';
  return 'dev';
}

String _debAssetName(String version) => 'talkye-scriber_${version}_amd64.deb';

class UpdateInfo {
  final String version;
  final String githubUrl; // fallback download URL (AppImage or .deb)
  final String body;
  UpdateInfo({required this.version, required this.githubUrl, this.body = ''});

  /// CDN URL based on install type
  String get cdnUrl {
    if (installType == 'deb') {
      return '$_cdnBase/${_debAssetName(version)}';
    }
    return '$_cdnBase/$_appImageName';
  }
}

/// Global notifier so any widget can react to available updates.
final updateAvailable = ValueNotifier<UpdateInfo?>(null);

/// Check GitHub Releases for a newer version. Returns null if up to date.
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final req = await client.getUrl(
      Uri.parse(
        'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest',
      ),
    );
    req.headers.set('Accept', 'application/vnd.github.v3+json');
    req.headers.set('User-Agent', 'TalkyeScriber/$appVersion');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;

    final body = await resp.transform(utf8.decoder).join();
    client.close();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final tagName = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (tagName.isEmpty || !_isNewer(tagName, appVersion)) return null;

    // Find the right asset based on install type
    final assets = data['assets'] as List<dynamic>? ?? [];
    String? githubUrl;
    final wantDeb = installType == 'deb';
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (wantDeb && name.endsWith('.deb')) {
        githubUrl = asset['browser_download_url'] as String?;
        break;
      }
      if (!wantDeb && name.contains('AppImage') && name.contains('x86_64')) {
        githubUrl = asset['browser_download_url'] as String?;
        break;
      }
    }

    return UpdateInfo(
      version: tagName,
      githubUrl: githubUrl ?? '',
      body: data['body'] as String? ?? '',
    );
  } catch (_) {
    return null;
  }
}

/// Compare semver strings. Returns true if remote > local.
bool _isNewer(String remote, String local) {
  final r = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final l = local.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  while (r.length < 3) r.add(0);
  while (l.length < 3) l.add(0);
  for (var i = 0; i < 3; i++) {
    if (r[i] > l[i]) return true;
    if (r[i] < l[i]) return false;
  }
  return false;
}

/// Download and install update. Routes to .deb or AppImage path.
Future<void> performUpdate(
  UpdateInfo info,
  void Function(double progress, String status) onProgress,
) async {
  if (installType == 'deb') {
    await _performDebUpdate(info, onProgress);
  } else {
    await _performAppImageUpdate(info, onProgress);
  }
}

// ── .deb update path ──

Future<void> _performDebUpdate(
  UpdateInfo info,
  void Function(double progress, String status) onProgress,
) async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final debName = _debAssetName(info.version);
  final tmpPath = '/tmp/$debName';

  // Download .deb
  final urls = [info.cdnUrl, if (info.githubUrl.isNotEmpty) info.githubUrl];
  String? lastError;

  for (final url in urls) {
    final source = url.contains('cdn.talkye') ? 'CDN' : 'GitHub';
    stderr.writeln('[UPDATER] Trying $source: $url');
    onProgress(0, 'Downloading v${info.version} ($source)...');

    try {
      await _downloadFile(url, tmpPath, info.version, source, onProgress);
      stderr.writeln('[UPDATER] Download from $source succeeded');
      lastError = null;
      break;
    } catch (e) {
      stderr.writeln('[UPDATER] $source failed: $e');
      lastError = '$source: $e';
      try {
        File(tmpPath).deleteSync();
      } catch (_) {}
    }
  }

  if (lastError != null) throw Exception(lastError);

  onProgress(1.0, 'Installing (password required)...');
  stderr.writeln('[UPDATER] Installing .deb via pkexec dpkg -i');

  // Install via pkexec (shows system password dialog)
  final result = await Process.run('pkexec', ['dpkg', '-i', tmpPath]);
  if (result.exitCode != 0) {
    // Clean up
    try {
      File(tmpPath).deleteSync();
    } catch (_) {}
    final err = (result.stderr as String).trim();
    if (err.contains('dismissed') || err.contains('Not authorized')) {
      throw Exception('Installation cancelled by user');
    }
    throw Exception('dpkg failed (exit ${result.exitCode}): $err');
  }

  // Clean up downloaded .deb
  try {
    File(tmpPath).deleteSync();
  } catch (_) {}

  // Remove lock/pid files for clean restart
  try {
    File('$home/.config/talkye/app.pid').deleteSync();
  } catch (_) {}
  try {
    File('$home/.config/talkye/app.lock').deleteSync();
  } catch (_) {}

  onProgress(1.0, 'Restarting...');
  stderr.writeln('[UPDATER] .deb installed, restarting');

  // Kill sidecar, then restart — no FUSE issues with .deb
  try {
    await Process.run('pkill', ['-f', 'uvicorn.*server:app.*8179']);
  } catch (_) {}

  // Launch new version and exit
  await Process.start('talkye-scriber', [], mode: ProcessStartMode.detached);
  await Future.delayed(const Duration(milliseconds: 300));
  exit(0);
}

// ── AppImage update path (existing logic) ──

Future<void> _performAppImageUpdate(
  UpdateInfo info,
  void Function(double progress, String status) onProgress,
) async {
  final appImagePath = Platform.environment['APPIMAGE'];
  if (appImagePath == null || appImagePath.isEmpty) {
    throw Exception('Not running as AppImage');
  }

  final tmpPath = '$appImagePath.new';
  final urls = [info.cdnUrl, if (info.githubUrl.isNotEmpty) info.githubUrl];
  String? lastError;

  for (final url in urls) {
    final source = url.contains('cdn.talkye') ? 'CDN' : 'GitHub';
    stderr.writeln('[UPDATER] Trying $source: $url');
    onProgress(0, 'Downloading v${info.version} ($source)...');

    try {
      await _downloadFile(url, tmpPath, info.version, source, onProgress);
      stderr.writeln('[UPDATER] Download from $source succeeded');
      lastError = null;
      break;
    } catch (e) {
      stderr.writeln('[UPDATER] $source failed: $e');
      lastError = '$source: $e';
      try {
        File(tmpPath).deleteSync();
      } catch (_) {}
    }
  }

  if (lastError != null) throw Exception(lastError);

  onProgress(1.0, 'Installing...');
  await Process.run('chmod', ['+x', tmpPath]);
  File(tmpPath).renameSync(appImagePath);

  final home = Platform.environment['HOME'] ?? '/tmp';
  try {
    File('$home/.config/talkye/app.pid').deleteSync();
  } catch (_) {}
  try {
    File('$home/.config/talkye/app.lock').deleteSync();
  } catch (_) {}

  // Restart via helper script (waits for FUSE unmount)
  final restartScript = '$home/.config/talkye/restart.sh';
  File(restartScript).writeAsStringSync(
    '#!/bin/bash\n'
    'OLD_PID=\$1\n'
    'APP=\$2\n'
    'while kill -0 \$OLD_PID 2>/dev/null; do sleep 0.5; done\n'
    'sleep 1\n'
    'pkill -f "uvicorn.*server:app.*8179" 2>/dev/null\n'
    'sleep 0.5\n'
    'setsid "\$APP" &\n',
  );
  await Process.run('chmod', ['+x', restartScript]);

  onProgress(1.0, 'Restarting...');
  stderr.writeln(
    '[UPDATER] Launching restart script (PID=$pid, app=$appImagePath)',
  );

  await Process.start('setsid', [
    restartScript,
    '$pid',
    appImagePath,
  ], mode: ProcessStartMode.detached);

  await Future.delayed(const Duration(milliseconds: 300));
  exit(0);
}

// ── Shared download helper ──

Future<void> _downloadFile(
  String url,
  String destPath,
  String version,
  String source,
  void Function(double progress, String status) onProgress,
) async {
  final process = await Process.start('curl', [
    '-fSL',
    '--output',
    destPath,
    '--write-out',
    '%{size_download}\n',
    '-#',
    url,
  ]);

  int? totalBytes;
  try {
    final head = await Process.run('curl', ['-sI', url]);
    final match = RegExp(
      r'content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(head.stdout as String);
    if (match != null) totalBytes = int.tryParse(match.group(1)!);
  } catch (_) {}

  final destFile = File(destPath);
  Timer? progressTimer;
  progressTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
    try {
      if (destFile.existsSync()) {
        final size = destFile.lengthSync();
        final pct = totalBytes != null && totalBytes > 0
            ? size / totalBytes
            : 0.0;
        final mb = (size / 1048576).toStringAsFixed(0);
        final totalMb = totalBytes != null
            ? (totalBytes / 1048576).toStringAsFixed(0)
            : '?';
        onProgress(pct, 'Downloading v$version ($source)... $mb / $totalMb MB');
      }
    } catch (_) {}
  });

  process.stdout.drain<void>();
  process.stderr.drain<void>();

  final exitCode = await process.exitCode;
  progressTimer.cancel();

  if (exitCode != 0) {
    throw Exception('curl exit code $exitCode');
  }

  onProgress(1.0, 'Download complete');
}
