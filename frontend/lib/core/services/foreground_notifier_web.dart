// ─────────────────────────────────────────────
// core/services/foreground_notifier_web.dart
//
// Web foreground popup — uses the browser's own Notification API
// directly via dart:html, since flutter_local_notifications doesn't
// officially cover web. This file only ever gets compiled in on
// web builds (see the conditional import in fcm_service.dart) —
// dart:html doesn't exist on Android/iOS, so this must never be
// imported unconditionally.
// ─────────────────────────────────────────────
import 'dart:html' as html;

Future<void> initForegroundNotifier() async {
  // Permission was already requested by FirebaseMessaging's own
  // requestPermission() call in fcm_service.dart — nothing
  // additional needed here.
}

Future<void> showForegroundNotification(
    {required String title, required String body}) async {
  if (html.Notification.permission != 'granted') return;
  html.Notification(title, body: body, icon: '/icons/Icon-192.png');
}
