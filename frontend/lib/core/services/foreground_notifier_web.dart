// ─────────────────────────────────────────────
// core/services/foreground_notifier_web.dart
//
// Web foreground popup (tab visible). Only compiled on web builds (see
// the conditional import in foreground_notifier.dart) — dart:html
// doesn't exist on Android/iOS.
//
// Hidden / closed tabs are NOT handled here: those go through
// web/firebase-messaging-sw.js, the single place that displays
// background web notifications.
// ─────────────────────────────────────────────
import 'dart:html' as html;

void Function(Map<String, dynamic> data)? _onTap;

Future<void> initForegroundNotifier({
  void Function(Map<String, dynamic> data)? onTap,
  void Function(Map<String, dynamic> data)? onView, // Android-only action
}) async {
  // Permission is requested by FirebaseMessaging.requestPermission()
  // in fcm_service.dart — nothing additional needed here.
  _onTap = onTap;
}

Future<void> showForegroundNotification({
  required String title,
  required String body,
  Map<String, dynamic>? data,
  String? tag, // Android conversation slot — not used on web
}) async {
  if (html.Notification.permission != 'granted') return;

  // Same tag scheme as the service worker, so several open tabs (each
  // receiving the foreground message) collapse to ONE notification.
  final notifId = data?['notif_id'];
  final tag = notifId == null ? null : 'gms-n-$notifId';

  try {
    final n = html.Notification(title,
        body: body, icon: '/icons/Icon-192.png', tag: tag);
    n.onClick.listen((_) {
      n.close();
      // No window.focus() needed (and dart:html's Window has none): this
      // popup only exists while the tab is VISIBLE — FCM hands hidden
      // tabs to the service worker instead, which focuses on click.
      final cb = _onTap;
      if (cb != null && data != null) cb(data);
    });
  } catch (_) {
    // Android Chrome rejects `new Notification()` from a page; it must
    // be shown through a service-worker registration instead.
    await _showViaServiceWorker(title, body, tag, data);
  }
}

Future<void> _showViaServiceWorker(String title, String body, String? tag,
    Map<String, dynamic>? data) async {
  try {
    // The FCM worker's scope — its notificationclick handler is the
    // one that routes taps (see firebase-messaging-sw.js).
    final reg = await html.window.navigator.serviceWorker
        ?.getRegistration('/firebase-cloud-messaging-push-scope');
    await reg?.showNotification(title, {
      'body': body,
      'icon': '/icons/Icon-192.png',
      if (tag != null) 'tag': tag,
      if (data != null) 'data': data,
    });
  } catch (_) {
    // Nothing more we can do; the in-app badge still updates.
  }
}

/// Web has no equivalent: a tapped web notification is routed by the
/// service worker (URL deep link / postMessage), see
/// web_notification_bridge_web.dart. Same signature as the mobile file.
Future<Map<String, dynamic>?> takeLaunchNotificationData() async => null;

/// Android-only (conversation slot); web notifications are managed by the
/// service worker. Same signature as the mobile file.
Future<void> cancelConversationNotification(String tag) async {}

/// Android-only (FCM background isolate / conversation notifications).
Future<void> initNotifierInBackground() async {}
Future<void> showConversationNotification(Map<String, dynamic> data) async {}
Future<void> showEventNotification(Map<String, dynamic> data,
    {required String title, required String body}) async {}
