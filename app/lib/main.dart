import 'package:flutter/material.dart';
import 'dart:io';

void main() {
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
      ),
      home: const TranslationPage(),
    );
  }
}

class TranslationPage extends StatefulWidget {
  const TranslationPage({super.key});

  @override
  State<TranslationPage> createState() => _TranslationPageState();
}

class _TranslationPageState extends State<TranslationPage> {
  bool _isRunning = false;
  Process? _process;
  String _status = 'Ready';

  Future<void> _toggle() async {
    if (_isRunning) {
      _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    setState(() {
      _isRunning = true;
      _status = 'Starting...';
    });

    try {
      // Run the Rust binary from project root
      _process = await Process.start(
        'cargo',
        ['run', '--release'],
        workingDirectory: '../core',
        environment: {
          ...Platform.environment,
          'RUST_LOG': 'info',
        },
      );

      setState(() => _status = 'Translating — speak Romanian');

      // Log stdout
      _process!.stdout.transform(const SystemEncoding().decoder).listen(
        (data) => debugPrint('[talkye] $data'),
      );
      _process!.stderr.transform(const SystemEncoding().decoder).listen(
        (data) => debugPrint('[talkye] $data'),
      );

      // Handle process exit
      _process!.exitCode.then((code) {
        if (mounted) {
          setState(() {
            _isRunning = false;
            _status = code == 0 ? 'Stopped' : 'Error (code $code)';
            _process = null;
          });
        }
      });
    } catch (e) {
      setState(() {
        _isRunning = false;
        _status = 'Failed: $e';
        _process = null;
      });
    }
  }

  void _stop() {
    _process?.kill(ProcessSignal.sigint);
    setState(() {
      _isRunning = false;
      _status = 'Stopped';
      _process = null;
    });
  }

  @override
  void dispose() {
    _process?.kill(ProcessSignal.sigint);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Talkye Meet',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Real-time voice translation',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 48),
            // The button
            GestureDetector(
              onTap: _toggle,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isRunning
                      ? const Color(0xFF1C0A0A)
                      : const Color(0xFF1A1A1A),
                  border: Border.all(
                    color: _isRunning
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF333333),
                    width: 2,
                  ),
                ),
                child: Icon(
                  _isRunning ? Icons.stop_rounded : Icons.mic_rounded,
                  size: 48,
                  color: _isRunning
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF888888),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _status,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
