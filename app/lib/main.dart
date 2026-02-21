import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'package:talkye_app/src/rust/api/engine.dart';
import 'package:talkye_app/src/rust/api/simple.dart';
import 'package:talkye_app/src/rust/frb_generated.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await RustLib.init();

  await windowManager.setSize(const Size(400, 700));
  await windowManager.setMinimumSize(const Size(400, 700));
  await windowManager.setMaximumSize(const Size(400, 700));
  await windowManager.setResizable(false);
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setTitle('Talkye Meet');
  await windowManager.setPreventClose(true);

  // Position top-right
  final screen = await windowManager.getBounds();
  // We set position from GTK side, but ensure it's visible
  await windowManager.show();

  runApp(const TalkyeApp());
}

// ── Theme ──

final _darkTheme = ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  scaffoldBackgroundColor: const Color(0xFF0E0E0E),
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFF4ADE80),
    surface: Color(0xFF0E0E0E),
    onSurface: Colors.white,
    error: Color(0xFFEF4444),
  ),
);

final _lightTheme = ThemeData(
  brightness: Brightness.light,
  useMaterial3: true,
  scaffoldBackgroundColor: const Color(0xFFF8F8F8),
  colorScheme: const ColorScheme.light(
    primary: Color(0xFF16A34A),
    surface: Color(0xFFF8F8F8),
    onSurface: Color(0xFF1A1A1A),
    error: Color(0xFFDC2626),
  ),
);

class TalkyeApp extends StatefulWidget {
  const TalkyeApp({super.key});
  @override
  State<TalkyeApp> createState() => _TalkyeAppState();
}

class _TalkyeAppState extends State<TalkyeApp> {
  bool _isDark = true;
  void _toggleTheme() => setState(() => _isDark = !_isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talkye Meet',
      debugShowCheckedModeBanner: false,
      theme: _isDark ? _darkTheme : _lightTheme,
      home: HomePage(isDark: _isDark, onToggleTheme: _toggleTheme),
    );
  }
}

// ── Data models ──

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

// ── Home Page ──

class HomePage extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  const HomePage({super.key, required this.isDark, required this.onToggleTheme});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener {
  bool _running = false;
  String _status = 'Idle';
  final EngineSettings _settings = EngineSettings();
  final List<TranscriptEntry> _transcript = [];
  final List<LogEntry> _logs = [];
  final ScrollController _scrollCtrl = ScrollController();
  final ScrollController _logScrollCtrl = ScrollController();
  String? _error;
  bool _showLogs = false;

  final SystemTray _tray = SystemTray();
  String _trayIconIdle = 'assets/tray-dark.png';
  String _trayIconLive = 'assets/tray-live.png';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _extractTrayIcons().then((_) => _initTray());
    _addLog('INFO', 'Talkye Core v${engineVersion()} ready');
  }

  /// Extract tray PNGs from Flutter assets to temp dir (system_tray needs file paths).
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
    _tray.setImage(_running ? _trayIconLive : _trayIconIdle);
  }

  Future<void> _initTray() async {
    await _tray.initSystemTray(
      title: 'Talkye Meet',
      iconPath: _trayIconIdle,
      toolTip: 'Talkye Meet — Live Translation',
    );

    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show / Hide', onClicked: (item) async {
        if (await windowManager.isVisible()) {
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      }),
      MenuSeparator(),
      MenuItemLabel(label: 'Quit', onClicked: (item) async {
        if (_running) stopEngine();
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

  // Window close → hide to tray
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  void _addLog(String level, String message) {
    setState(() {
      _logs.add(LogEntry(level: level, message: message));
      if (_logs.length > 500) _logs.removeRange(0, 100);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _toggleEngine() {
    if (_running) { _stopEngine(); } else { _startEngine(); }
  }

  void _startEngine() {
    setState(() { _running = true; _status = 'Loading...'; _error = null; });
    _updateTrayIcon();
    _addLog('INFO', 'Starting engine (STT=${_settings.sttBackend})...');

    final config = FfiEngineConfig(
      sttBackend: _settings.sttBackend,
      sttLanguage: '',
      translateFrom: '',
      translateTo: '',
      voicePath: '', ttsSpeed: 0, groqApiKey: '', deepgramApiKey: '',
      hfToken: '', parakeetModelDir: '', vadModelPath: '',
      audioOutput: '',
    );

    startEngine(config: config).listen(
      (event) {
        event.when(
          statusChanged: (status) {
            setState(() => _status = status);
            _addLog('INFO', '● Status: $status');
            if (status == 'Stopped' || status == 'Idle') {
              setState(() => _running = false);
              _updateTrayIcon();
            }
          },
          transcript: (original, translated) {
            setState(() {
              _transcript.add(TranscriptEntry(original: original, translated: translated));
            });
            _addLog('INFO', '🎤 $original');
            _addLog('INFO', '🔊 $translated');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollCtrl.hasClients) {
                _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
              }
            });
          },
          error: (message) {
            setState(() => _error = message);
            _addLog('ERROR', message);
          },
          log: (level, message) => _addLog(level, message),
        );
      },
      onError: (e) {
        setState(() { _error = e.toString(); _running = false; _status = 'Error'; });
        _updateTrayIcon();
        _addLog('ERROR', e.toString());
      },
      onDone: () {
        setState(() { _running = false; _status = 'Idle'; });
        _updateTrayIcon();
        _addLog('INFO', 'Engine stopped');
      },
    );
  }

  void _stopEngine() {
    stopEngine();
    setState(() { _running = false; _status = 'Idle'; });
    _updateTrayIcon();
    _addLog('INFO', 'Stop requested');
  }

  void _copyLogs() {
    final text = _logs.map((l) =>
      '${l.timestamp.toIso8601String().substring(11, 23)} [${l.level}] ${l.message}'
    ).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs copied'), duration: Duration(seconds: 1)),
    );
  }

  void _openSettings() async {
    if (_running) return; // Can't change settings while running
    final result = await showSettingsSheet(
      context,
      current: _settings,
      isDark: widget.isDark,
    );
    if (result != null) {
      setState(() {
        _settings.sttBackend = result.sttBackend;
      });
      _addLog('INFO', '⚙️ Settings: STT=${result.sttBackend}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = widget.isDark;
    final cardColor = isDark ? const Color(0xFF161616) : Colors.white;
    final subtleColor = isDark ? const Color(0xFF888888) : const Color(0xFF666666);
    final borderColor = isDark ? const Color(0xFF222222) : const Color(0xFFE0E0E0);

    return Scaffold(
      body: Column(
        children: [
          _buildHeader(cs, isDark, subtleColor),
          if (_error != null) _buildError(cs),
          Expanded(
            child: _showLogs
                ? _buildLogPanel(cardColor, borderColor, subtleColor)
                : _buildTranscript(cs, isDark, subtleColor),
          ),
          _buildStatusBar(cs),
          _buildActionButton(cs, isDark),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs, bool isDark, Color subtleColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SvgPicture.asset('assets/navbar-icon.svg',
              width: 24, height: 24,
              colorFilter: ColorFilter.mode(
                _running ? const Color(0xFFF97316) : (isDark ? Colors.white : Colors.black),
                BlendMode.srcIn,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('Talkye Meet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const Spacer(),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 18, color: subtleColor),
            tooltip: isDark ? 'Light mode' : 'Dark mode',
            onPressed: widget.onToggleTheme,
            splashRadius: 18,
          ),
          IconButton(
            icon: Icon(Icons.tune_rounded, size: 18,
              color: _running ? subtleColor.withAlpha(60) : subtleColor),
            tooltip: 'Settings',
            onPressed: _running ? null : _openSettings,
            splashRadius: 18,
          ),
          IconButton(
            icon: Icon(
              _showLogs ? Icons.terminal : Icons.terminal_outlined,
              size: 18, color: _showLogs ? cs.primary : subtleColor,
            ),
            tooltip: _showLogs ? 'Transcript' : 'Dev Logs',
            onPressed: () => setState(() => _showLogs = !_showLogs),
            splashRadius: 18,
          ),
          if (_showLogs)
            IconButton(
              icon: Icon(Icons.copy_rounded, size: 16, color: subtleColor),
              tooltip: 'Copy Logs',
              onPressed: _copyLogs,
              splashRadius: 18,
            ),
        ],
      ),
    );
  }

  Widget _buildError(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.error.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withAlpha(60)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: cs.error, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!,
            style: TextStyle(color: cs.error, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis)),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 14),
            onPressed: () => setState(() => _error = null),
            splashRadius: 14,
          ),
        ],
      ),
    );
  }

  Widget _buildTranscript(ColorScheme cs, bool isDark, Color subtleColor) {
    if (_transcript.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_running ? Icons.mic_rounded : Icons.translate_rounded,
              size: 40, color: subtleColor.withAlpha(60)),
            const SizedBox(height: 10),
            Text(
              _running ? 'Listening...' : 'Press Start to begin',
              style: TextStyle(color: subtleColor.withAlpha(120), fontSize: 13),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: _transcript.length,
      itemBuilder: (context, index) {
        final entry = _transcript[index];
        final isRecent = index >= _transcript.length - 3;
        return Opacity(
          opacity: isRecent ? 1.0 : 0.5,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.original,
                  style: TextStyle(color: subtleColor, fontSize: 12, height: 1.4)),
                const SizedBox(height: 2),
                Text(entry.translated,
                  style: TextStyle(color: cs.onSurface, fontSize: 14,
                    fontWeight: FontWeight.w500, height: 1.4)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogPanel(Color cardColor, Color borderColor, Color subtleColor) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: ListView.builder(
        controller: _logScrollCtrl,
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          final time = log.timestamp.toIso8601String().substring(11, 23);
          Color color = subtleColor;
          if (log.level == 'ERROR') color = const Color(0xFFEF4444);
          if (log.level == 'WARN') color = const Color(0xFFF59E0B);
          if (log.message.contains('[STT]')) color = const Color(0xFF60A5FA);
          if (log.message.contains('[TRANSLATE]')) color = const Color(0xFFFBBF24);
          if (log.message.contains('[TTS]')) color = const Color(0xFF4ADE80);
          if (log.message.contains('🎤') || log.message.contains('🔊')) {
            color = widget.isDark ? Colors.white70 : Colors.black87;
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 0.5),
            child: SelectableText('$time ${log.message}',
              style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: color, height: 1.4)),
          );
        },
      ),
    );
  }

  Widget _buildStatusBar(ColorScheme cs) {
    Color dotColor;
    switch (_status) {
      case 'Listening': dotColor = cs.primary; break;
      case 'Translating': dotColor = Colors.amber; break;
      case 'Speaking': dotColor = const Color(0xFF60A5FA); break;
      case 'Loading': case 'Loading...': dotColor = Colors.orange; break;
      default: dotColor = const Color(0xFF666666);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(children: [
        Container(width: 7, height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor)),
        const SizedBox(width: 8),
        Text(_status, style: TextStyle(color: dotColor, fontSize: 12, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _buildActionButton(ColorScheme cs, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity, height: 46,
        child: ElevatedButton(
          onPressed: _toggleEngine,
          style: ElevatedButton.styleFrom(
            backgroundColor: (_running ? cs.error : cs.primary).withAlpha(isDark ? 30 : 20),
            foregroundColor: _running ? cs.error : cs.primary,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            side: BorderSide(color: (_running ? cs.error : cs.primary).withAlpha(40)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_running ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 20),
              const SizedBox(width: 8),
              Text(_running ? 'Stop' : 'Start',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    if (_running) stopEngine();
    _scrollCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }
}
