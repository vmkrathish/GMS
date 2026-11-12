// ─────────────────────────────────────────────
// core/services/foreground_notifier.dart
//
// Selects the correct platform implementation at compile time —
// Dart's standard conditional-import pattern, used here because
// dart:html (needed for web) doesn't exist on Android/iOS, and
// flutter_local_notifications (needed for Android) doesn't
// officially support web. Importing either one unconditionally
// would break the OTHER platform's build.
// ─────────────────────────────────────────────
export 'foreground_notifier_mobile.dart'
    if (dart.library.html) 'foreground_notifier_web.dart';
