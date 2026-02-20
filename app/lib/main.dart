import 'package:flutter/material.dart';
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
      home: const BridgeTestPage(),
    );
  }
}

/// Stage 1 test page — verifies FFI bridge works.
class BridgeTestPage extends StatefulWidget {
  const BridgeTestPage({super.key});

  @override
  State<BridgeTestPage> createState() => _BridgeTestPageState();
}

class _BridgeTestPageState extends State<BridgeTestPage> {
  String _syncResult = '';
  String _asyncResult = '';
  final List<String> _streamEvents = [];
  bool _streamRunning = false;

  @override
  void initState() {
    super.initState();
    _testSync();
  }

  void _testSync() {
    final greeting = greet(name: "Flutter");
    final version = engineVersion();
    setState(() {
      _syncResult = '$greeting\nEngine v$version';
    });
  }

  Future<void> _testAsync() async {
    setState(() => _asyncResult = 'Running...');
    final result = await testAsync(delayMs: 500);
    setState(() => _asyncResult = result);
  }

  void _testStream() {
    setState(() {
      _streamEvents.clear();
      _streamRunning = true;
    });

    testStream(count: 5, intervalMs: 300).listen(
      (event) {
        setState(() => _streamEvents.add(event));
      },
      onDone: () {
        setState(() => _streamRunning = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talkye Meet — FFI Bridge Test'),
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('1. Sync Call (Rust → Dart)', _syncResult),
            const SizedBox(height: 16),
            _section('2. Async Call', _asyncResult),
            ElevatedButton(
              onPressed: _testAsync,
              child: const Text('Test Async'),
            ),
            const SizedBox(height: 16),
            _section(
              '3. Stream (Rust → Dart)',
              _streamEvents.isEmpty
                  ? (_streamRunning ? 'Starting...' : 'Not started')
                  : _streamEvents.join('\n'),
            ),
            ElevatedButton(
              onPressed: _streamRunning ? null : _testStream,
              child: Text(_streamRunning ? 'Streaming...' : 'Test Stream'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            content.isEmpty ? '—' : content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}
