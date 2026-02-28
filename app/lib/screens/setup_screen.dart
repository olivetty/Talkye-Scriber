import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';

const _modelUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin';

class SetupScreen extends StatefulWidget {
  final VoidCallback onSetupComplete;
  const SetupScreen({super.key, required this.onSetupComplete});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String _status = 'Checking...';
  double _progress = 0;
  int _bytesDownloaded = 0;
  int _bytesTotal = 0;
  bool _downloading = false;
  bool _error = false;
  String _errorMsg = '';

  static String get _modelDir {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.config/talkye/models';
  }

  static String get _modelPath => '$_modelDir/ggml-large-v3-turbo.bin';

  @override
  void initState() {
    super.initState();
    _checkAndDownload();
  }

  Future<void> _checkAndDownload() async {
    final file = File(_modelPath);
    if (await file.exists() && await file.length() > 100000000) {
      // Model exists and is reasonably sized (>100MB)
      widget.onSetupComplete();
      return;
    }
    setState(() {
      _status = 'Downloading speech model...';
      _downloading = true;
    });
    await _downloadModel();
  }

  Future<void> _downloadModel() async {
    try {
      await Directory(_modelDir).create(recursive: true);
      final tmpPath = '$_modelPath.download';
      final tmpFile = File(tmpPath);

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse(_modelUrl));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      _bytesTotal = response.contentLength;
      _bytesDownloaded = 0;

      final sink = tmpFile.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        _bytesDownloaded += chunk.length;
        if (mounted) {
          setState(() {
            _progress = _bytesTotal > 0 ? _bytesDownloaded / _bytesTotal : 0;
            _status =
                'Downloading speech model... ${_formatBytes(_bytesDownloaded)} / ${_formatBytes(_bytesTotal)}';
          });
        }
      }
      await sink.close();
      client.close();

      // Rename temp to final
      await tmpFile.rename(_modelPath);

      if (mounted) {
        setState(() {
          _status = 'Ready';
          _downloading = false;
        });
        // Small delay so user sees "Ready"
        await Future.delayed(const Duration(milliseconds: 500));
        widget.onSetupComplete();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _downloading = false;
          _errorMsg = e.toString();
          _status = 'Download failed';
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(0)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Talkye Scriber',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: C.text,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'First-time setup',
              style: TextStyle(fontSize: 13, color: C.textSub),
            ),
            const SizedBox(height: 40),
            if (_downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 6,
                  backgroundColor: C.level2,
                  valueColor: const AlwaysStoppedAnimation<Color>(C.accent),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              _status,
              style: TextStyle(
                fontSize: 12,
                color: _error ? C.error : C.textSub,
              ),
            ),
            if (_error) ...[
              const SizedBox(height: 8),
              Text(
                _errorMsg,
                style: const TextStyle(fontSize: 11, color: C.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _error = false;
                    _errorMsg = '';
                  });
                  _checkAndDownload();
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: C.accent.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: C.accent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
