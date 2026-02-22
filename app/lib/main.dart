import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'package:talkye_app/src/rust/api/engine.dart';
import 'package:talkye_app/src/rust/frb_generated.dart';
import 'theme.dart';
import 'sidebar.dart';
import 'status_bar.dart';
import 'screens/interpreter_screen.dart';
import 'screens/voice_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/dictate_screen.dart';
import 'screens/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await RustLib.init();

  await windowManager.setTitle('Talkye Meet');
  await windowManager.setPreventClose(true);
  await windowManager.show();

  runApp(const TalkyeApp());
}

class TalkyeApp extends StatelessWidget {
  const TalkyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talkye Meet',
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      home: const AppShell(),
    );
  }
}

/// Shared app settings — persisted to ~/.config/talkye/settings.json
class AppSettings {
  String sttBackend;
  String activeVoicePath;
  String sourceLang; // '' = autodetect
  String targetLang;
  String triggerKey; // evdev name, e.g. KEY_RIGHTCTRL
  String soundTheme; // subtle | mechanical | silent
  String inputMode; // ptt | vad
  String dictateSttBackend; // groq | local (whisper.cpp)
  bool dictateTranslate; // translate to English via whisper.cpp
  String ttsBackend; // pocket | chatterbox
  String wakePhrase; // wake phrase for VAD (user-trained)
  int vadTimeout; // seconds of silence → standby
  bool autoEnter; // press Enter when VAD session ends
  // Chatterbox quality parameters
  double cbxExaggeration; // 0.0-1.0, voice expressiveness
  double cbxCfgWeight; // 0.0-1.0, reference voice adherence
  double cbxTemperature; // 0.1-1.0, generation variability
  int cbxContextWindow; // 25-100, overlap between streaming chunks

  AppSettings({
    this.sttBackend = 'parakeet',
    this.activeVoicePath = '',
    this.sourceLang = '',
    this.targetLang = 'English',
    this.triggerKey = 'KEY_RIGHTCTRL',
    this.soundTheme = 'subtle',
    this.inputMode = 'ptt',
    this.dictateSttBackend = 'local',
    this.dictateTranslate = false,
    this.ttsBackend = 'pocket',
    this.wakePhrase = 'hey mira',
    this.vadTimeout = 8,
    this.autoEnter = true,
    this.cbxExaggeration = 0.5,
    this.cbxCfgWeight = 0.5,
    this.cbxTemperature = 0.8,
    this.cbxContextWindow = 50,
  });

  static File get _file {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.config/talkye/settings.json');
  }

  static AppSettings load() {
    try {
      final f = _file;
      if (f.existsSync()) {
        final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return AppSettings(
          sttBackend: map['sttBackend'] as String? ?? 'parakeet',
          activeVoicePath: map['activeVoicePath'] as String? ?? '',
          sourceLang: map['sourceLang'] as String? ?? '',
          targetLang: map['targetLang'] as String? ?? 'English',
          triggerKey: map['triggerKey'] as String? ?? 'KEY_RIGHTCTRL',
          soundTheme: map['soundTheme'] as String? ?? 'subtle',
          inputMode: map['inputMode'] as String? ?? 'ptt',
          dictateSttBackend: map['dictateSttBackend'] as String? ?? 'groq',
          dictateTranslate: map['dictateTranslate'] as bool? ?? false,
          ttsBackend: map['ttsBackend'] as String? ?? 'pocket',
          wakePhrase: map['wakePhrase'] as String? ?? 'hey mira',
          vadTimeout: map['vadTimeout'] as int? ?? 8,
          autoEnter: map['autoEnter'] as bool? ?? true,
          cbxExaggeration: (map['cbxExaggeration'] as num?)?.toDouble() ?? 0.5,
          cbxCfgWeight: (map['cbxCfgWeight'] as num?)?.toDouble() ?? 0.5,
          cbxTemperature: (map['cbxTemperature'] as num?)?.toDouble() ?? 0.8,
          cbxContextWindow: map['cbxContextWindow'] as int? ?? 50,
        );
      }
    } catch (e) {
      // Log corruption so user knows settings were reset
      stderr.writeln('WARNING: Failed to load settings, using defaults: $e');
    }
    return AppSettings();
  }

  void save() {
    try {
      final f = _file;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'sttBackend': sttBackend,
        'activeVoicePath': activeVoicePath,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'triggerKey': triggerKey,
        'soundTheme': soundTheme,
        'inputMode': inputMode,
        'dictateSttBackend': dictateSttBackend,
        'dictateTranslate': dictateTranslate,
        'ttsBackend': ttsBackend,
        'wakePhrase': wakePhrase,
        'vadTimeout': vadTimeout,
        'autoEnter': autoEnter,
        'cbxExaggeration': cbxExaggeration,
        'cbxCfgWeight': cbxCfgWeight,
        'cbxTemperature': cbxTemperature,
        'cbxContextWindow': cbxContextWindow,
      }));
    } catch (e) {
      stderr.writeln('WARNING: Failed to save settings: $e');
    }
  }
}

/// Global log buffer — collects engine logs for debugging.
/// Uses a circular write index for O(1) adds. Entries carry level + source metadata.
class LogBuffer {
  static final List<LogEntry?> _entries = List.filled(_maxLines, null);
  static const int _maxLines = 500;
  static int _writeIdx = 0;
  static int _count = 0;
  static int _version = 0;

  static void add(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    String level = 'INFO';
    String source = '';

    if (line.contains('[ERROR]') || line.startsWith('ERROR')) {
      level = 'ERROR';
    } else if (line.contains('[WARN]') || line.startsWith('WARN')) {
      level = 'WARN';
    }

    final tagMatch = RegExp(r'\[([A-Z_-]+)\]').firstMatch(line);
    if (tagMatch != null) {
      final tag = tagMatch.group(1)!;
      if (!{'INFO', 'WARN', 'ERROR', 'DEBUG'}.contains(tag)) {
        source = tag;
      }
    }
    if (line.startsWith('SIDECAR')) source = 'SIDECAR';

    _entries[_writeIdx] = LogEntry(ts: ts, level: level, source: source, message: line);
    _writeIdx = (_writeIdx + 1) % _maxLines;
    if (_count < _maxLines) _count++;
    _version++;
  }

  static List<LogEntry> get entries {
    if (_count < _maxLines) {
      return _entries.sublist(0, _count).whereType<LogEntry>().toList();
    }
    final tail = _entries.sublist(_writeIdx).whereType<LogEntry>().toList();
    final head = _entries.sublist(0, _writeIdx).whereType<LogEntry>().toList();
    return [...tail, ...head];
  }

  static String get text => entries.map((e) => '[${e.ts}] ${e.message}').join('\n');
  static int get length => _count;
  static int get version => _version;
  static void clear() {
    _entries.fillRange(0, _maxLines, null);
    _writeIdx = 0;
    _count = 0;
    _version++;
  }
}

class LogEntry {
  final String ts;
  final String level;
  final String source;
  final String message;
  const LogEntry({required this.ts, required this.level, required this.source, required this.message});
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener {
  NavSection _section = NavSection.interpreter;
  final _interpreterKey = GlobalKey<InterpreterScreenState>();
  late final AppSettings _settings;

  // System tray
  final SystemTray _tray = SystemTray();
  String _trayIconIdle = 'assets/tray-dark.png';
  String _trayIconLive = 'assets/tray-live.png';

  // Python sidecar process
  Process? _sidecar;

  @override
  void initState() {
    super.initState();
    _settings = AppSettings.load();
    windowManager.addListener(this);
    _extractTrayIcons().then((_) => _initTray());
    _startSidecar();
  }

  bool get _engineRunning {
    final state = _interpreterKey.currentState;
    return state != null && state.isRunning;
  }

  // ── Python Sidecar ──

  Future<void> _startSidecar({bool skipHealthCheck = false}) async {
    // Find sidecar directory relative to the executable
    final exe = Platform.resolvedExecutable;
    final projectRoot = exe.contains('/build/')
        ? exe.substring(0, exe.indexOf('/app/build'))
        : exe.substring(0, exe.lastIndexOf('/'));

    // Try multiple paths to find sidecar
    final candidates = [
      '$projectRoot/sidecar',
      '${Platform.environment['HOME']}/Code/talkye-meet/sidecar',
      // Relative to current working directory
      '${Directory.current.path}/sidecar',
    ];

    String? sidecarDir;
    for (final c in candidates) {
      if (await File('$c/server.py').exists()) {
        sidecarDir = c;
        break;
      }
    }

    if (sidecarDir == null) {
      LogBuffer.add('SIDECAR: server.py not found, skipping auto-start');
      return;
    }

    // Check if already running (skip on restart)
    if (!skipHealthCheck) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 1);
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:8179/health'));
        final resp = await req.close().timeout(const Duration(seconds: 2));
        final body = await resp.transform(utf8.decoder).join();
        client.close();
        if (body.contains('"ok"')) {
          LogBuffer.add('SIDECAR: already running on :8179');
          return;
        }
      } catch (_) {
        // Not running — we'll start it
      }
    }

    // Find Python — prefer sidecar venv, fallback to system
    final venvPython = '$sidecarDir/venv/bin/python';

    // Run setup.sh — creates venv, installs deps, detects CUDA for llama-cpp-python
    LogBuffer.add('SIDECAR: running setup...');
    try {
      final setupResult = await Process.run(
        'bash', ['$sidecarDir/setup.sh'],
        workingDirectory: sidecarDir,
      ).timeout(const Duration(minutes: 3));
      if (setupResult.exitCode != 0) {
        LogBuffer.add('SIDECAR: setup failed: ${setupResult.stderr}');
        // Try to continue if venv already exists
        if (!await File(venvPython).exists()) return;
      } else {
        for (final line in (setupResult.stdout as String).split('\n')) {
          if (line.trim().isNotEmpty) LogBuffer.add('SIDECAR: $line');
        }
      }
    } on TimeoutException {
      LogBuffer.add('SIDECAR: setup.sh timed out after 3 minutes');
      if (!await File(venvPython).exists()) return;
    }

    LogBuffer.add('SIDECAR: starting on :8179...');
    try {
      _sidecar = await Process.start(
        '$sidecarDir/venv/bin/uvicorn',
        ['server:app', '--host', '127.0.0.1', '--port', '8179'],
        workingDirectory: sidecarDir,
      );
      _sidecar!.stdout.transform(utf8.decoder).listen((line) {
        for (final l in line.split('\n')) {
          if (l.trim().isNotEmpty) LogBuffer.add('SIDECAR: $l');
        }
      });
      _sidecar!.stderr.transform(utf8.decoder).listen((line) {
        for (final l in line.split('\n')) {
          if (l.trim().isNotEmpty) LogBuffer.add('SIDECAR ERR: $l');
        }
      });
      LogBuffer.add('SIDECAR: started (PID ${_sidecar!.pid})');
    } catch (e) {
      LogBuffer.add('SIDECAR: failed to start: $e');
    }
  }

  void _stopSidecar() {
    if (_sidecar != null) {
      LogBuffer.add('SIDECAR: stopping (PID ${_sidecar!.pid})');
      _sidecar!.kill(ProcessSignal.sigterm);
      _sidecar = null;
    }
  }

  /// Restart sidecar process. Returns when the new instance is healthy.
  Future<void> restartSidecar() async {
    _stopSidecar();
    // Wait for port to free up
    await Future.delayed(const Duration(milliseconds: 800));
    await _startSidecar(skipHealthCheck: true);
    // Wait for health check to pass
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:8179/health'));
        final resp = await req.close().timeout(const Duration(seconds: 2));
        final body = await resp.transform(utf8.decoder).join();
        client.close();
        if (body.contains('"ok"')) return;
      } catch (_) {}
    }
  }

  // ── System Tray ──

  Future<void> _extractTrayIcons() async {
    final dir = await getTemporaryDirectory();
    for (final name in ['tray-dark.png', 'tray-light.png', 'tray-live.png']) {
      final data = await rootBundle.load('assets/$name');
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(data.buffer.asUint8List());
    }
    _trayIconIdle = '${dir.path}/tray-dark.png';
    _trayIconLive = '${dir.path}/tray-live.png';
  }

  void _updateTrayIcon() {
    _tray.setImage(_engineRunning ? _trayIconLive : _trayIconIdle);
  }

  Future<void> _initTray() async {
    await _tray.initSystemTray(
      title: 'Talkye Meet',
      iconPath: _trayIconIdle,
      toolTip: 'Talkye Meet',
    );
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show / Hide', onClicked: (_) async {
        if (await windowManager.isVisible()) {
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      }),
      MenuSeparator(),
      MenuItemLabel(label: 'Quit', onClicked: (_) async {
        if (_engineRunning) stopEngine();
        _stopSidecar();
        await windowManager.setPreventClose(false);
        await windowManager.close();
      }),
    ]);
    await _tray.setContextMenu(menu);
    _tray.registerSystemTrayEventHandler((eventName) async {
      if (eventName == kSystemTrayEventClick) {
        if (await windowManager.isVisible()) {
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      } else if (eventName == kSystemTrayEventRightClick) {
        await _tray.popUpContextMenu();
      }
    });
  }

  @override
  void onWindowClose() async => await windowManager.hide();

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Sidebar(
            active: _section,
            onSelect: (s) => setState(() => _section = s),
            engineRunning: _engineRunning,
          ),
          Container(width: 1, color: C.level2),
          Expanded(child: Column(children: [
            Expanded(child: _buildContent()),
            const StatusBar(),
          ])),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_section) {
      case NavSection.interpreter:
        return InterpreterScreen(
          key: _interpreterKey,
          settings: _settings,
          onStateChanged: () => setState(() => _updateTrayIcon()),
        );
      case NavSection.dictate:
        return DictateScreen(
          settings: _settings,
          onRestartSidecar: restartSidecar,
        );
      case NavSection.chat:
        return const ChatScreen();
      case NavSection.assistant:
        return _comingSoon('Meeting Assistant', Icons.groups_rounded,
          'AI-powered meeting notes with speaker diarization.');
      case NavSection.calendar:
        return _comingSoon('Calendar', Icons.calendar_month_rounded,
          'See upcoming meetings and join with one click.');
      case NavSection.voice:
        return VoiceScreen(
          activeVoicePath: _settings.activeVoicePath,
          onVoiceChanged: (path) {
            final changed = _settings.activeVoicePath != path;
            setState(() { _settings.activeVoicePath = path; _settings.save(); });
            // Restart engine if running so new voice takes effect
            if (changed && _engineRunning) {
              _interpreterKey.currentState?.restartWithNewVoice();
            }
          },
        );
      case NavSection.settings:
        return SettingsScreen(
          settings: _settings,
          onChanged: (s) => setState(() {
            _settings.sttBackend = s.sttBackend;
            _settings.ttsBackend = s.ttsBackend;
            _settings.save();
          }),
          engineRunning: _engineRunning,
        );
    }
  }

  Widget _comingSoon(String title, IconData icon, String desc) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 56, color: C.textMuted.withAlpha(50)),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.text)),
        const SizedBox(height: 8),
        Text(desc, style: const TextStyle(fontSize: 13, color: C.textSub)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: C.accent.withAlpha(15), borderRadius: BorderRadius.circular(8)),
          child: const Text('Coming Soon', style: TextStyle(fontSize: 12, color: C.accent, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  @override
  void dispose() {
    _stopSidecar();
    windowManager.removeListener(this);
    super.dispose();
  }
}
