// ─────────────────────────────────────────────
// core/services/app_version.dart
//
// Reads the version of the build that is actually running:
//  • Android: the installed APK's versionName/versionCode (from
//    PackageManager) — an installed APK keeps showing its own version
//    until a rebuilt APK is installed over it.
//  • Web: version.json, which `flutter build web` writes next to
//    index.html from pubspec.yaml (fetched with a cache-buster).
// Release workflow: edit `version:` in frontend/pubspec.yaml by hand,
// then rebuild. Nothing here (or anywhere) increments it automatically.
// ─────────────────────────────────────────────
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:package_info_plus/package_info_plus.dart';

import 'app_version_text.dart';

class AppVersion {
  static Future<String>? _label;

  /// Display label, e.g. "1.0.0 (build 1)". Read once per app run
  /// (package_info_plus caches it too); never throws.
  static Future<String> label() => _label ??= _load();

  static Future<String> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return AppVersionText.format(info.version, info.buildNumber);
    } catch (e) {
      debugPrint('AppVersion: could not read package info — $e');
      _label = null; // allow a later retry
      return AppVersionText.format('', '');
    }
  }
}
