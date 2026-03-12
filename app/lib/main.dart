import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'package:lottie/lottie.dart';
import 'theme.dart';
import 'status_bar.dart';
import 'screens/dictate_screen.dart';
import 'screens/setup_screen.dart';
import 'desktop_integration.dart';

Future<void> main() async {
  // Single-instance guard: lock file + PID verification
  final lockResult = await _acquireInstanceLock();
  if (!lockResult) exit(0);

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

  // Write our PID so future launches know we're running
  _writePidFile();

  runApp(const TalkyeApp());
}

File get _pidFile {
  final home = Platform.environment['HOME'] ?? '/tmp';
  return File('$home/.config/talkye/app.pid');
}

File get _lockFile {
  final home = Platform.environment['HOME'] ?? '/tmp';
  return File('$home/.config/talkye/app.lock');
}

RandomAccessFile? _lockHandle;

void _writePidFile() {
  try {
    _pidFile.parent.createSync(recursive: true);
    _pidFile.writeAsStringSync('$pid');
  } catch (_) {}
}

/// Acquire a file lock to guarantee single-instance.
/// Returns true if we got the lock (we're the only instance).
/// Returns false if another instance is running (we should exit).
Future<bool> _acquireInstanceLock() async {
  try {
    _lockFile.parent.createSync(recursive: true);

    // Try to open and exclusively lock the file
    _lockHandle = _lockFile.openSync(mode: FileMode.write);
    try {
      _lockHandle!.lockSync(FileLock.exclusive);
    } on FileSystemException {
      // Lock held by another process — it's alive
      _lockHandle!.closeSync();
      _lockHandle = null;

      // Try to activate the existing window
      await _activateExistingWindow();
      return false;
    }

    // We got the lock — write our PID
    _lockHandle!.writeStringSync('$pid');
    _lockHandle!.flushSync();
    // Keep _lockHandle open (lock is held as long as the file is open)
    // Also write PID file for backward compat
    _writePidFile();
    return true;
  } catch (e) {
    // If locking fails entirely, fall back to PID-based check
    stderr.writeln('WARNING: Lock file failed ($e), falling back to PID check');
    if (await _activateExistingInstance()) return false;
    _writePidFile();
    return true;
  }
}

Future<void> _activateExistingWindow() async {
  try {
    await Process.run('xdotool', [
      'search',
      '--name',
      'Talkye Scriber',
      'windowactivate',
    ]);
  } catch (_) {}
}

Future<bool> _activateExistingInstance() async {
  try {
    if (!_pidFile.existsSync()) return false;
    final existingPid = int.tryParse(_pidFile.readAsStringSync().trim());
    if (existingPid == null || existingPid == pid) return false;

    // Check if process is alive AND is actually Talkye
    final procDir = Directory('/proc/$existingPid');
    if (!procDir.existsSync()) return false;

    // Verify it's our app, not a recycled PID
    try {
      final cmdline = File('/proc/$existingPid/cmdline').readAsStringSync();
      if (!cmdline.toLowerCase().contains('talkye') &&
          !cmdline.toLowerCase().contains('flutter')) {
        // PID was recycled — not our app
        return false;
      }
    } catch (_) {
      // Can't read cmdline — might be permission issue, assume it's ours
    }

    await _activateExistingWindow();
    return true;
  } catch (_) {
    return false;
  }
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
  bool _setupDone = false;
  bool _sidecarReady = false;
  String _loadingMsg = 'Warming up...';
  int _loadingStep = 0;

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
    _checkModelAndStart();
    installDesktopEntry();
  }

  Future<void> _checkModelAndStart() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final modelPath = '$home/.config/talkye/models/ggml-large-v3-turbo.bin';
    final modelFile = File(modelPath);
    if (await modelFile.exists() && await modelFile.length() > 100000000) {
      setState(() => _setupDone = true);
      await _startSidecar();
      await _waitForSidecar();
    }
    // If model missing, SetupScreen will show and call _onSetupComplete when done
  }

  void _onSetupComplete() {
    setState(() => _setupDone = true);
    _startSidecar().then((_) => _waitForSidecar());
  }

  Future<void> _waitForSidecar() async {
    const messages = [
      'Warming up...',
      'Loading voice engine...',
      'Preparing microphone...',
      'Calibrating speech model...',
      'Setting up dictation...',
      'Almost there...',
      'Finishing setup...',
    ];
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      // Update loading message every 2 seconds
      if (i % 4 == 0 && mounted) {
        _loadingStep = (i ~/ 4) % messages.length;
        setState(() => _loadingMsg = messages[_loadingStep]);
      }
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:8179/health'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 2));
        final body = await resp.transform(utf8.decoder).join();
        client.close();
        if (body.contains('"ok"')) {
          if (mounted) setState(() => _sidecarReady = true);
          return;
        }
      } catch (_) {}
      // Check if sidecar process died
      if (_sidecar != null) {
        final exitCode = _sidecar!.exitCode;
        // exitCode is a Future — check if it's already completed
        bool died = false;
        exitCode.then((_) => died = true);
        await Future.delayed(Duration.zero);
        if (died) {
          LogBuffer.add('SIDECAR: process died during startup');
          break;
        }
      }
    }
    // Timeout or crash — show dictate screen anyway (will show offline banner)
    if (mounted) setState(() => _sidecarReady = true);
  }

  // ── Python Sidecar ──

  Future<void> _startSidecar({bool skipHealthCheck = false}) async {
    final exe = Platform.resolvedExecutable;
    final projectRoot = exe.contains('/build/')
        ? exe.substring(0, exe.indexOf('/app/build'))
        : exe.substring(0, exe.lastIndexOf('/'));

    // TALKYE_SIDECAR_DIR is set by AppRun in AppImage
    final envSidecar = Platform.environment['TALKYE_SIDECAR_DIR'];
    final candidates = [
      if (envSidecar case final dir?) dir,
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
          // Kill orphaned sidecar from previous run — it may have stale paths
          LogBuffer.add('SIDECAR: killing orphaned instance on :8179');
          try {
            await Process.run('pkill', ['-f', 'uvicorn.*server:app.*8179']);
            await Future.delayed(const Duration(seconds: 1));
          } catch (_) {}
        }
      } catch (_) {}
    }

    // Use bundled Python if available (TALKYE_PYTHON set by AppRun)
    final bundledPython = Platform.environment['TALKYE_PYTHON'];
    final isAppImage = Platform.environment['APPIMAGE'] != null;

    String uvicornBin;
    List<String> uvicornArgs;

    if (isAppImage && bundledPython != null) {
      // AppImage: deps are pre-installed in bundled Python, no venv needed
      LogBuffer.add('SIDECAR: AppImage mode, using bundled Python');
      uvicornBin = bundledPython;
      uvicornArgs = [
        '-m',
        'uvicorn',
        'server:app',
        '--host',
        '127.0.0.1',
        '--port',
        '8179',
      ];
    } else {
      // Dev mode: use local venv
      final venvDir = '$sidecarDir/venv';
      final venvPython = '$venvDir/bin/python';

      LogBuffer.add('SIDECAR: dev mode, running setup...');
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
      uvicornBin = '$venvDir/bin/uvicorn';
      uvicornArgs = ['server:app', '--host', '127.0.0.1', '--port', '8179'];
    }

    LogBuffer.add('SIDECAR: starting on :8179...');
    try {
      final sidecarEnv = Map<String, String>.from(Platform.environment);
      sidecarEnv['TALKYE_SIDECAR_DIR'] = sidecarDir;
      _sidecar = await Process.start(
        uvicornBin,
        uvicornArgs,
        workingDirectory: sidecarDir,
        environment: sidecarEnv,
      );
      // Write sidecar output to log file for debugging
      final home = Platform.environment['HOME'] ?? '/tmp';
      final logFile = File('$home/.config/talkye/sidecar.log');
      final logSink = logFile.openWrite(mode: FileMode.write);
      logSink.writeln(
        '[${DateTime.now()}] Sidecar starting (PID ${_sidecar!.pid})',
      );
      logSink.writeln('[${DateTime.now()}] sidecarDir: $sidecarDir');
      _sidecar!.stdout.transform(utf8.decoder).listen((line) {
        for (final l in line.split('\n')) {
          if (l.trim().isNotEmpty) {
            LogBuffer.add('SIDECAR: $l');
            logSink.writeln(l);
          }
        }
      });
      _sidecar!.stderr.transform(utf8.decoder).listen((line) {
        for (final l in line.split('\n')) {
          if (l.trim().isNotEmpty) {
            LogBuffer.add('SIDECAR ERR: $l');
            logSink.writeln('[ERR] $l');
          }
        }
      });
      _sidecar!.exitCode.then((code) {
        logSink.writeln('[${DateTime.now()}] Sidecar exited with code $code');
        logSink.close();
        LogBuffer.add('SIDECAR: exited with code $code');
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
    // Detect system theme: dark panel needs light icon, light panel needs dark icon
    final useDark = await _isDesktopDarkTheme();
    _trayIconIdle = useDark
        ? '${dir.path}/tray-light.png'
        : '${dir.path}/tray-dark.png';
  }

  static Future<bool> _isDesktopDarkTheme() async {
    try {
      final r = await Process.run('gsettings', [
        'get',
        'org.gnome.desktop.interface',
        'color-scheme',
      ]);
      if (r.exitCode == 0) {
        final val = (r.stdout as String).trim();
        if (val.contains('dark')) return true;
        if (val.contains('light')) return false;
      }
    } catch (_) {}
    try {
      final r = await Process.run('gsettings', [
        'get',
        'org.gnome.desktop.interface',
        'gtk-theme',
      ]);
      if (r.exitCode == 0) {
        return (r.stdout as String).toLowerCase().contains('dark');
      }
    } catch (_) {}
    return true; // default: assume dark panel
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
          try {
            _lockHandle?.unlockSync();
            _lockHandle?.closeSync();
          } catch (_) {}
          try {
            _pidFile.deleteSync();
          } catch (_) {}
          try {
            _lockFile.deleteSync();
          } catch (_) {}
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

  Widget _loadingScreen() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Lottie.asset('assets/vui-animation.json'),
          ),
          const SizedBox(height: 24),
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
          Text(
            _loadingMsg,
            style: const TextStyle(fontSize: 13, color: C.textSub),
          ),
        ],
      ),
    );
  }

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
                  child: !_setupDone
                      ? SetupScreen(onSetupComplete: _onSetupComplete)
                      : !_sidecarReady
                      ? _loadingScreen()
                      : DictateScreen(
                          settings: _settings,
                          onRestartSidecar: restartSidecar,
                        ),
                ),
                if (_setupDone) const StatusBar(),
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
    try {
      _lockHandle?.unlockSync();
      _lockHandle?.closeSync();
    } catch (_) {}
    try {
      _pidFile.deleteSync();
    } catch (_) {}
    try {
      _lockFile.deleteSync();
    } catch (_) {}
    windowManager.removeListener(this);
    super.dispose();
  }
}
