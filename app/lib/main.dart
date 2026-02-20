import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:talkye_app/src/rust/api/engine.dart';
import 'package:talkye_app/src/rust/api/simple.dart';
import 'package:talkye_app/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const TalkyeApp());
}

class TalkyeApp extends StatelessWidget {
  const TalkyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talkye Meet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF4CAF50),
          surface: const Color(0xFF0A0A0A),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class TranscriptEntry {
  final String original;
  final String translated;
  final DateTime timestamp;
  TranscriptEntry({required this.original, required this.translated})
      : timestamp = DateTime.now();
}

class LogEntry {
  final String level;
  final String message;
  final DateTime timestamp;
  LogEntry({required this.level, required this.message})
      : timestamp = DateTime.now();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _running = false;
  String _status = 'Idle';
  final List<TranscriptEntry> _transcript = [];
  final List<LogEntry> _logs = [];
  final ScrollController _scrollController = ScrollController();
  final ScrollController _logScrollController = ScrollController();
  String? _error;
  bool _showLogs = false;

  final _config = FfiEngineConfig(
    sttBackend: '', sttLanguage: '', translateFrom: '', translateTo: '',
    voicePath: '', ttsSpeed: 0, groqApiKey: '', deepgramApiKey: '',
    hfToken: '', parakeetModelDir: '', vadModelPath: '', audioOutput: '',
  );

  @override
  void initState() {
    super.initState();
    final version = engineVersion();
    _addLog('INFO', 'Talkye Core v$version ready');
  }

  void _addLog(String level, String message) {
    setState(() {
      _logs.add(LogEntry(level: level, message: message));
      if (_logs.length > 500) _logs.removeRange(0, 100);
    });
    _scrollLogsToBottom();
  }

  void _scrollLogsToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(
          _logScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  void _toggleEngine() {
    if (_running) { _stopEngine(); } else { _startEngine(); }
  }

  void _startEngine() {
    setState(() { _running = true; _status = 'Loading...'; _error = null; });
    _addLog('INFO', 'Starting engine...');

    startEngine(config: _config).listen(
      (event) {
        event.when(
          statusChanged: (status) {
            setState(() => _status = status);
            _addLog('INFO', '● Status: $status');
            if (status == 'Stopped' || status == 'Idle') {
              setState(() => _running = false);
            }
          },
          transcript: (original, translated) {
            setState(() {
              _transcript.add(TranscriptEntry(
                original: original, translated: translated,
              ));
            });
            _addLog('INFO', '🎤 $original');
            _addLog('INFO', '🔊 $translated');
            _scrollToBottom();
          },
          error: (message) {
            setState(() => _error = message);
            _addLog('ERROR', message);
          },
          log: (level, message) {
            _addLog(level, message);
          },
        );
      },
      onError: (e) {
        setState(() { _error = e.toString(); _running = false; _status = 'Error'; });
        _addLog('ERROR', e.toString());
      },
      onDone: () {
        setState(() { _running = false; _status = 'Idle'; });
        _addLog('INFO', 'Engine stopped');
      },
    );
  }

  void _stopEngine() {
    stopEngine();
    setState(() { _running = false; _status = 'Idle'; });
    _addLog('INFO', 'Stop requested');
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyLogs() {
    final text = _logs.map((l) =>
      '${l.timestamp.toIso8601String().substring(11, 23)} [${l.level}] ${l.message}'
    ).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs copied to clipboard'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildLanguageBar(),
            if (_error != null) _buildErrorBanner(),
            Expanded(
              child: _showLogs ? _buildLogPanel() : _buildTranscript(),
            ),
            _buildStatusBar(),
            _buildActionButton(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _running ? const Color(0xFF4CAF50) : Colors.grey,
            ),
          ),
          const SizedBox(width: 8),
          const Text('Talkye Meet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const Spacer(),
          // Log toggle
          IconButton(
            icon: Icon(
              _showLogs ? Icons.article : Icons.article_outlined,
              size: 20,
              color: _showLogs ? const Color(0xFF4CAF50) : Colors.grey,
            ),
            tooltip: _showLogs ? 'Show Transcript' : 'Show Logs',
            onPressed: () => setState(() => _showLogs = !_showLogs),
          ),
          if (_showLogs)
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy Logs',
              onPressed: _copyLogs,
            ),
          IconButton(
            icon: const Icon(Icons.devices, size: 20),
            tooltip: 'Audio Devices',
            onPressed: _showDevices,
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Text('.env → .env', style: TextStyle(fontSize: 14, color: Colors.white70)),
          const Spacer(),
          Text('${_transcript.length} translations',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withAlpha(80)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12),
              maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _error = null),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: ListView.builder(
        controller: _logScrollController,
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          final time = log.timestamp.toIso8601String().substring(11, 23);
          Color color;
          switch (log.level) {
            case 'ERROR': color = Colors.red; break;
            case 'WARN': color = Colors.orange; break;
            default: color = const Color(0xFF888888);
          }
          // Highlight key events
          if (log.message.contains('🎤') || log.message.contains('🔊')) {
            color = Colors.white70;
          }
          if (log.message.contains('[STT]')) color = const Color(0xFF64B5F6);
          if (log.message.contains('[TRANSLATE]')) color = const Color(0xFFFFD54F);
          if (log.message.contains('[TTS]')) color = const Color(0xFF81C784);

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText(
              '$time ${ log.message}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: color,
                height: 1.4,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTranscript() {
    if (_transcript.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_running ? Icons.mic : Icons.translate,
              size: 48, color: Colors.grey.withAlpha(80)),
            const SizedBox(height: 12),
            Text(
              _running ? 'Listening...' : 'Press Start to begin translating',
              style: TextStyle(color: Colors.grey.withAlpha(150), fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _transcript.length,
      itemBuilder: (context, index) {
        final entry = _transcript[index];
        final isRecent = index >= _transcript.length - 3;
        return Opacity(
          opacity: isRecent ? 1.0 : 0.6,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('🎤 ', style: TextStyle(fontSize: 13)),
                  Expanded(child: Text(entry.original,
                    style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.4))),
                ]),
                const SizedBox(height: 2),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('🔊 ', style: TextStyle(fontSize: 13)),
                  Expanded(child: Text(entry.translated,
                    style: const TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w500, height: 1.4))),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusBar() {
    Color dotColor;
    switch (_status) {
      case 'Listening': dotColor = const Color(0xFF4CAF50); break;
      case 'Translating': dotColor = Colors.amber; break;
      case 'Speaking': dotColor = Colors.blue; break;
      case 'Loading': case 'Loading...': dotColor = Colors.orange; break;
      default: dotColor = Colors.grey;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Container(width: 8, height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor)),
        const SizedBox(width: 8),
        Text(_status, style: TextStyle(color: dotColor, fontSize: 13)),
      ]),
    );
  }

  Widget _buildActionButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity, height: 48,
        child: ElevatedButton.icon(
          onPressed: _toggleEngine,
          icon: Icon(_running ? Icons.stop : Icons.play_arrow),
          label: Text(_running ? 'Stop Translation' : 'Start Translation'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _running
                ? Colors.red.withAlpha(40)
                : const Color(0xFF4CAF50).withAlpha(40),
            foregroundColor: _running ? Colors.red : const Color(0xFF4CAF50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
  }

  void _showDevices() {
    final inputs = listInputDevices();
    final outputs = listOutputDevices();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Audio Devices'),
        content: SizedBox(
          width: 350,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Input', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ...inputs.map((d) => ListTile(dense: true,
                leading: Icon(d.isDefault ? Icons.mic : Icons.mic_none,
                  color: d.isDefault ? const Color(0xFF4CAF50) : Colors.grey, size: 18),
                title: Text(d.name, style: const TextStyle(fontSize: 13)))),
              const Divider(),
              const Text('Output', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ...outputs.map((d) => ListTile(dense: true,
                leading: Icon(d.isDefault ? Icons.volume_up : Icons.volume_down,
                  color: d.isDefault ? const Color(0xFF4CAF50) : Colors.grey, size: 18),
                title: Text(d.name, style: const TextStyle(fontSize: 13)))),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  void dispose() {
    if (_running) stopEngine();
    _scrollController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }
}
