import 'dart:io';
import 'package:flutter/services.dart';

/// Install desktop entry + icon so the app appears in Linux app launcher.
/// Only runs when launched as AppImage and not already installed.
Future<void> installDesktopEntry() async {
  final appImagePath = Platform.environment['APPIMAGE'];
  if (appImagePath == null || appImagePath.isEmpty) return; // not AppImage

  final home = Platform.environment['HOME'] ?? '/tmp';
  final desktopDir = '$home/.local/share/applications';
  final iconDir = '$home/.local/share/icons/hicolor/256x256/apps';
  final desktopFile = '$desktopDir/talkye-scriber.desktop';
  final iconFile = '$iconDir/talkye-scriber.png';

  // Skip if already installed with same AppImage path
  final existing = File(desktopFile);
  if (await existing.exists()) {
    final content = await existing.readAsString();
    if (content.contains(appImagePath)) return; // already installed
  }

  // Create directories
  await Directory(desktopDir).create(recursive: true);
  await Directory(iconDir).create(recursive: true);

  // Write icon from bundled asset
  try {
    final iconData = await rootBundle.load('assets/talkye-meet.png');
    await File(iconFile).writeAsBytes(iconData.buffer.asUint8List());
  } catch (_) {}

  // Write .desktop file
  final desktop =
      '''[Desktop Entry]
Name=Talkye Scriber
Comment=Voice-to-text dictation tool
Exec=$appImagePath
Icon=talkye-scriber
Type=Application
Categories=Utility;Accessibility;Audio;
StartupWMClass=com.talkye.meet
''';
  await File(desktopFile).writeAsString(desktop);

  // Update desktop database (non-blocking, best-effort)
  try {
    Process.run('update-desktop-database', [desktopDir]);
  } catch (_) {}
}
