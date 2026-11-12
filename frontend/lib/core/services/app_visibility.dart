// ─────────────────────────────────────────────
// core/services/app_visibility.dart
//
// Is the app on screen? Fast polling (bookings, badges — every 3 s) runs
// only while it is; when the app goes to the background it pauses, and
// on return everything refreshes immediately. Works the same on Android
// and Web (a hidden browser tab reports `hidden`/`paused`).
// ─────────────────────────────────────────────
import 'package:flutter/widgets.dart';

class AppVisibility with WidgetsBindingObserver {
  AppVisibility._();
  static final AppVisibility _i = AppVisibility._();

  /// true while the app is in the foreground (resumed).
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  static bool _started = false;

  static void init() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(_i);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    visible.value = state == AppLifecycleState.resumed;
  }
}
