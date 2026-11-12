// ─────────────────────────────────────────────
// core/services/app_version_text.dart
//
// Pure-Dart formatting of the app version for display (no Flutter
// imports, unit-tested in test/app_version_text_test.dart).
//
// The values come from package_info_plus at runtime (see
// app_version.dart), which in turn come from ONE place:
// frontend/pubspec.yaml → `version: <name>+<build>`, e.g. 1.0.0+1.
//   name  → Android versionName / web version.json "version"
//   build → Android versionCode / web version.json "build_number"
// Never hard-code a version anywhere else.
// ─────────────────────────────────────────────

class AppVersionText {
  /// "1.0.0 (build 1)"; "1.0.0" when the platform reports no build
  /// number; "unavailable" when nothing could be read.
  static String format(String version, String buildNumber) {
    final v = version.trim();
    final b = buildNumber.trim();
    if (v.isEmpty) return 'unavailable';
    if (b.isEmpty || b == v) return v;
    return '$v (build $b)';
  }
}
