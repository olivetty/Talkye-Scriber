import 'package:flutter/material.dart';
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

/// Transcript entry — original + translated pair.
class TranscriptEntry {
  final String original;
  final String translated;
  final DateTime timestamp;

  TranscriptEntry({
    required this.original,
    required this.translated,
  }) : timestamp = DateTime.now();
}

/// Main home screen — transcript + engine control.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _running = false;
  String _status = 'Idle';
  final List<TranscriptEntry> _transcript = [];
  final ScrollController _scrollController = ScrollController();
  String? _error;

  // Default config — will come from settings later
  final _config = FfiEngineConfig(
    sttBackend: 'parakeet',
    sttLanguage: 'ro',
    translateFrom: 'Romanian',
    translateTo: 'English',
    voicePath: 'voices/oliver.safetensors',
    ttsSpeed: 1.0,
    groqApiKey: '',  // loaded from .env in dev
    deepgramApiKey: '',
    hfToken: '',
    parakeetModelDir: 'models/parakeet-tdt',
    vadModelPath: 'models/silero_vad.onnx',
    audioOutput: 'talkye_combined',
  );

  @override
  void initState() {
    super.initState();
    // Show FFI bridge version on start
    final version = engineVersion();
    debugPrint('Talkye Core v$version');
  }

  void _toggleEngine() {
    if (_running) {
      _stopEngine();
    } else {
      _startEngine();
    }
  }

  void _startEngine() {
    setState(() {
      _running = true;
      _status = 'Loading...';
      _error = null;
    });

    startEngine(config: _config).listen(
      (event) {
        event.when(
          statusChanged: (status) {
            setState(() => _status = status);
            if (status == 'Stopped' || status == 'Idle') {
              setState(() => _running = false);
            }
          },
          transcript: (original, translated) {
            setState(() {
              _transcript.add(TranscriptEntry(
                original: original,
                translated: translated,
              ));
            });
            _scrollToBottom();
          },
          error: (message) {
            setState(() => _error = message);
          },
        );
      },
      onError: (e) {
        setState(() {
          _error = e.toString();
          _running = false;
          _status = 'Error';
        });
      },
      onDone: () {
        setState(() {
          _running = false;
          _status = 'Idle';
        });
      },
    );
  }

  void _stopEngine() {
    stopEngine();
    setState(() {
      _running = false;
      _status = 'Idle';
    });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(),
            // Language bar
            _buildLanguageBar(),
            // Error banner
            if (_error != null) _buildErrorBanner(),
            // Transcript area
            Expanded(child: _buildTranscript()),
            // Status + action
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
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _running ? const Color(0xFF4CAF50) : Colors.grey,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Talkye Meet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.devices, size: 20),
            tooltip: 'Audio Devices',
            onPressed: _showDevices,
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            tooltip: 'Settings',
            onPressed: () {}, // TODO: settings page
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
          Text(
            '${_config.translateFrom} → ${_config.translateTo}',
            style: const TextStyle(fontSize: 14, color: Colors.white70),
          ),
          const Spacer(),
          Text(
            '${_transcript.length} translations',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
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
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _error = null),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscript() {
    if (_transcript.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _running ? Icons.mic : Icons.translate,
              size: 48,
              color: Colors.grey.withAlpha(80),
            ),
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
                // Original
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🎤 ', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Text(
                        entry.original,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // Translated
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🔊 ', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Text(
                        entry.translated,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
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
      case 'Listening':
        dotColor = const Color(0xFF4CAF50);
        break;
      case 'Translating':
        dotColor = Colors.amber;
        break;
      case 'Speaking':
        dotColor = Colors.blue;
        break;
      case 'Loading':
      case 'Loading...':
        dotColor = Colors.orange;
        break;
      default:
        dotColor = Colors.grey;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _status,
            style: TextStyle(color: dotColor, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton.icon(
          onPressed: _toggleEngine,
          icon: Icon(_running ? Icons.stop : Icons.play_arrow),
          label: Text(_running ? 'Stop Translation' : 'Start Translation'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _running
                ? Colors.red.withAlpha(40)
                : const Color(0xFF4CAF50).withAlpha(40),
            foregroundColor: _running ? Colors.red : const Color(0xFF4CAF50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
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
              ...inputs.map((d) => ListTile(
                dense: true,
                leading: Icon(
                  d.isDefault ? Icons.mic : Icons.mic_none,
                  color: d.isDefault ? const Color(0xFF4CAF50) : Colors.grey,
                  size: 18,
                ),
                title: Text(d.name, style: const TextStyle(fontSize: 13)),
              )),
              const Divider(),
              const Text('Output', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ...outputs.map((d) => ListTile(
                dense: true,
                leading: Icon(
                  d.isDefault ? Icons.volume_up : Icons.volume_down,
                  color: d.isDefault ? const Color(0xFF4CAF50) : Colors.grey,
                  size: 18,
                ),
                title: Text(d.name, style: const TextStyle(fontSize: 13)),
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    if (_running) stopEngine();
    _scrollController.dispose();
    super.dispose();
  }
}
