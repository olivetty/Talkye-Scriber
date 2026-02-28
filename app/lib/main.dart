import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'theme.dart';
import 'status_bar.dart';
import 'screens/dictate_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(960, 680),
    minimumSize: Size(800, 560),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setTitle('Talkye Scriber');
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const TalkyeApp());
}

class TalkyeApp extends StatelessWidget {
  const TalkyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talkye Scriber',
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      home: const AppShell(),
    );
  }
}

/// Shared app settings — persisted to ~/.config/talkye/settings.json
class AppSettings {
  String triggerKey; // evdev name, e.g. KEY_RIGHTCTRL
  String soundTheme; // subtle | alex | luna | silent
  bool dictateTranslate; // translate to English via LLM
  bool dictateGrammar; // grammar/cleanup fix via LLM
  String groqApiKey; // Groq API key for LLM post-processing

  AppSettings({
    this.triggerKey = 'KEY_RIGHTCTRL',
    this.soundTheme = 'subtle',
    this.dictateTranslate = false,
    this.dictateGrammar = false,
    this.groqApiKey = '',
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
          triggerKey: map['triggerKey'] as String? ?? 'KEY_RIGHTCTRL',
          soundTheme: map['soundTheme'] as String? ?? 'subtle',
          dictateTranslate: map['dictateTranslate'] as bool? ?? false,
          dictateGrammar: map['dictateGrammar'] as bool? ?? false,
          groqApiKey: map['groqApiKey'] as String? ?? '',
        );
      }
    } catch (e) {
      stderr.writeln('WARNING: Failed to load settings, using defaults: $e');
    }
    return AppSettings();
  }

  void save() {
    try {
      final f = _file;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'triggerKey': triggerKey,
          'soundTheme': soundTheme,
          'dictateTranslate': dictateTranslate,
          'dictateGrammar': dictateGrammar,
          'groqApiKey': groqApiKey,
        }),
      );
    } catch (e) {
      stderr.writeln('WARNING: Failed to save settings: $e');
    }
  }
}

/// Custom title bar — draggable, with window controls.
class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 38,
        color: C.bg,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // Window controls (macOS-style colored dots)
            _windowBtn(const Color(0xFFFF5F57), () async {
              await windowManager.hide();
            }),
            const SizedBox(width: 6),
            _windowBtn(const Color(0xFFFFBD2E), () async {
              await windowManager.minimize();
            }),
            const SizedBox(width: 6),
            _windowBtn(const Color(0xFF28C840), () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            }),
            const Expanded(
              child: Center(
                child: Text(
                  'Talkye Scriber',
                  style: TextStyle(
                    fontSize: 12,
                    color: C.textSub,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            // Balance the row (same width as 3 dots + gaps)
            const SizedBox(width: 42),
          ],
        ),
      ),
    );
  }

  static Widget _windowBtn(Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
      ),
    );
  }
}

/// Global log buffer — collects engine logs for debugging.
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

    _entries[_writeIdx] = LogEntry(
      ts: ts,
      level: level,
      source: source,
      message: line,
    );
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

  static String get text =>
      entries.map((e) => '[${e.ts}] ${e.message}').join('\n');
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
  const LogEntry({
    required this.ts,
    required this.level,
    required this.source,
    required this.message,
  });
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener {
  late final AppSettings _settings;

  // System tray
  final SystemTray _tray = SystemTray();
  String _trayIconIdle = 'assets/tray-dark.png';

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

  // ── Python Sidecar ──

  Future<void> _startSidecar({bool skipHealthCheck = false}) async {
    final exe = Platform.resolvedExecutable;
    final projectRoot = exe.contains('/build/')
        ? exe.substring(0, exe.indexOf('/app/build'))
        : exe.substring(0, exe.lastIndexOf('/'));

    final candidates = [
      '$projectRoot/sidecar',
      '${Platform.environment['HOME']}/Code/talkye-meet/sidecar',
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

    if (!skipHealthCheck) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 1);
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:8179/health'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 2));
        final body = await resp.transform(utf8.decoder).join();
        client.close();
        if (body.contains('"ok"')) {
          LogBuffer.add('SIDECAR: already running on :8179');
          return;
        }
      } catch (_) {}
    }

    final venvPython = '$sidecarDir/venv/bin/python';

    LogBuffer.add('SIDECAR: running setup...');
    try {
      final setupResult = await Process.run('bash', [
        '$sidecarDir/setup.sh',
      ], workingDirectory: sidecarDir).timeout(const Duration(minutes: 3));
      if (setupResult.exitCode != 0) {
        LogBuffer.add('SIDECAR: setup failed: ${setupResult.stderr}');
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
      _sidecar = await Process.start('$sidecarDir/venv/bin/uvicorn', [
        'server:app',
        '--host',
        '127.0.0.1',
        '--port',
        '8179',
      ], workingDirectory: sidecarDir);
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

  Future<void> restartSidecar() async {
    _stopSidecar();
    await Future.delayed(const Duration(milliseconds: 800));
    await _startSidecar(skipHealthCheck: true);
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:8179/health'),
        );
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
    for (final name in ['tray-dark.png', 'tray-light.png']) {
      final data = await rootBundle.load('assets/$name');
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(data.buffer.asUint8List());
    }
    _trayIconIdle = '${dir.path}/tray-dark.png';
  }

  Future<void> _initTray() async {
    await _tray.initSystemTray(
      title: 'Talkye Scriber',
      iconPath: _trayIconIdle,
      toolTip: 'Talkye Scriber',
    );
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: 'Show / Hide',
        onClicked: (_) async {
          if (await windowManager.isVisible()) {
            await windowManager.hide();
          } else {
            await windowManager.show();
            await windowManager.focus();
          }
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Quit',
        onClicked: (_) async {
          _stopSidecar();
          await windowManager.setPreventClose(false);
          await windowManager.close();
        },
      ),
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
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Scaffold(
            body: Column(
              children: [
                const _TitleBar(),
                Expanded(
                  child: DictateScreen(
                    settings: _settings,
                    onRestartSidecar: restartSidecar,
                  ),
                ),
                const StatusBar(),
              ],
            ),
          ),
        ),
        // Resize edges — invisible hit areas on all sides
        ..._resizeEdges(),
      ],
    );
  }

  List<Widget> _resizeEdges() {
    const e = 4.0; // edge thickness
    return [
      // Top
      Positioned(
        top: 0,
        left: e,
        right: e,
        height: e,
        child: _resizeArea(SystemMouseCursors.resizeUp, ResizeEdge.top),
      ),
      // Bottom
      Positioned(
        bottom: 0,
        left: e,
        right: e,
        height: e,
        child: _resizeArea(SystemMouseCursors.resizeDown, ResizeEdge.bottom),
      ),
      // Left
      Positioned(
        left: 0,
        top: e,
        bottom: e,
        width: e,
        child: _resizeArea(SystemMouseCursors.resizeLeft, ResizeEdge.left),
      ),
      // Right
      Positioned(
        right: 0,
        top: e,
        bottom: e,
        width: e,
        child: _resizeArea(SystemMouseCursors.resizeRight, ResizeEdge.right),
      ),
      // Top-left
      Positioned(
        top: 0,
        left: 0,
        width: e * 2,
        height: e * 2,
        child: _resizeArea(SystemMouseCursors.resizeUpLeft, ResizeEdge.topLeft),
      ),
      // Top-right
      Positioned(
        top: 0,
        right: 0,
        width: e * 2,
        height: e * 2,
        child: _resizeArea(
          SystemMouseCursors.resizeUpRight,
          ResizeEdge.topRight,
        ),
      ),
      // Bottom-left
      Positioned(
        bottom: 0,
        left: 0,
        width: e * 2,
        height: e * 2,
        child: _resizeArea(
          SystemMouseCursors.resizeDownLeft,
          ResizeEdge.bottomLeft,
        ),
      ),
      // Bottom-right
      Positioned(
        bottom: 0,
        right: 0,
        width: e * 2,
        height: e * 2,
        child: _resizeArea(
          SystemMouseCursors.resizeDownRight,
          ResizeEdge.bottomRight,
        ),
      ),
    ];
  }

  Widget _resizeArea(MouseCursor cursor, ResizeEdge edge) {
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        onPanStart: (_) => windowManager.startResizing(edge),
      ),
    );
  }

  @override
  void dispose() {
    _stopSidecar();
    windowManager.removeListener(this);
    super.dispose();
  }
}
