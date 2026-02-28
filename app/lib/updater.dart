import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'version.dart';

const _repoOwner = 'olivetty';
const _repoName = 'Talkye-Meet-Assistant';

/// Primary CDN for fast downloads; GitHub Releases as fallback.
const _cdnBase = 'https://cdn.talkye.com';
const _appImageName = 'TalkyeScriber-x86_64.AppImage';

class UpdateInfo {
  final String version;
  final String githubUrl; // fallback download URL
  final String body;
  UpdateInfo({required this.version, required this.githubUrl, this.body = ''});

  /// Primary: R2 CDN. Fallback: GitHub Releases.
  String get cdnUrl => '$_cdnBase/$_appImageName';
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

    // Find AppImage asset URL (fallback)
    final assets = data['assets'] as List<dynamic>? ?? [];
    String? githubUrl;
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.contains('AppImage') && name.contains('x86_64')) {
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
  while (r.length < 3) {
    r.add(0);
  }
  while (l.length < 3) {
    l.add(0);
  }
  for (var i = 0; i < 3; i++) {
    if (r[i] > l[i]) return true;
    if (r[i] < l[i]) return false;
  }
  return false;
}

/// Download new AppImage and replace current one, then restart.
/// Tries R2 CDN first, falls back to GitHub Releases.
Future<void> performUpdate(
  UpdateInfo info,
  void Function(double progress, String status) onProgress,
) async {
  final appImagePath = Platform.environment['APPIMAGE'];
  if (appImagePath == null || appImagePath.isEmpty) {
    throw Exception('Not running as AppImage');
  }

  final tmpPath = '$appImagePath.new';

  // Try R2 CDN first, fallback to GitHub
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
      break; // success
    } catch (e) {
      stderr.writeln('[UPDATER] $source failed: $e');
      lastError = '$source: $e';
      // Clean up failed download
      try {
        File(tmpPath).deleteSync();
      } catch (_) {}
    }
  }

  if (lastError != null) throw Exception(lastError);

  onProgress(1.0, 'Installing...');

  // Make executable
  await Process.run('chmod', ['+x', tmpPath]);
  // Replace current AppImage
  File(tmpPath).renameSync(appImagePath);

  onProgress(1.0, 'Restarting...');
  await Future.delayed(const Duration(milliseconds: 500));

  // Remove PID lock so the new instance doesn't think we're a duplicate
  try {
    final home = Platform.environment['HOME'] ?? '/tmp';
    File('$home/.config/talkye/app.pid').deleteSync();
  } catch (_) {}

  // Restart — await the spawn, then give OS time before exiting
  await Process.start(appImagePath, [], mode: ProcessStartMode.detached);
  await Future.delayed(const Duration(seconds: 2));
  exit(0);
}

Future<void> _downloadFile(
  String url,
  String destPath,
  String version,
  String source,
  void Function(double progress, String status) onProgress,
) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);
  client.autoUncompress = false; // don't decompress — we want raw bytes
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set('User-Agent', 'TalkyeScriber/$appVersion');
  request.headers.set('Accept-Encoding', 'identity'); // no gzip
  final response = await request.close().timeout(const Duration(seconds: 30));

  if (response.statusCode != 200) {
    client.close();
    throw Exception('HTTP ${response.statusCode}');
  }

  final total = response.contentLength;
  var downloaded = 0;
  final sink = File(destPath).openWrite();

  await for (final chunk in response) {
    sink.add(chunk);
    downloaded += chunk.length;
    final pct = total > 0 ? downloaded / total : 0.0;
    final mb = (downloaded / 1048576).toStringAsFixed(0);
    final totalMb = total > 0 ? (total / 1048576).toStringAsFixed(0) : '?';
    onProgress(pct, 'Downloading v$version ($source)... $mb / $totalMb MB');
  }
  await sink.close();
  client.close();
}
