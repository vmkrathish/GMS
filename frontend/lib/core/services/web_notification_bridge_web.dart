// ─────────────────────────────────────────────
// core/services/web_notification_bridge_web.dart
//
// Connects the browser service worker to the Flutter app so a click on
// a background notification lands on the right chat/booking:
//
//  • Tab already open → firebase-messaging-sw.js focuses it and posts
//    {type: 'GMS_NOTIFICATION_CLICK', data}. [listenForNotificationClicks]
//    receives that.
//  • No tab open → the worker opens the app at
//    /?gms_screen=chat&gms_partner_id=9 …; [takeInitialDeepLink] reads
//    it once at start and removes it from the address bar, so a page
//    reload doesn't route again.
// ─────────────────────────────────────────────
import 'dart:html' as html;

const _clickType = 'GMS_NOTIFICATION_CLICK';

void listenForNotificationClicks(
    void Function(Map<String, dynamic> data) onClick) {
  final sw = html.window.navigator.serviceWorker;
  if (sw == null) return;
  sw.onMessage.listen((event) {
    final msg = event.data;
    if (msg is! Map || msg['type'] != _clickType) return;
    final data = msg['data'];
    if (data is! Map) return;
    onClick({for (final e in data.entries) '${e.key}': e.value});
  });
}

Map<String, dynamic>? takeInitialDeepLink() {
  final u = Uri.base;
  final q = u.queryParameters;
  final screen = q['gms_screen'];
  if (screen == null || screen.isEmpty) return null;

  final data = <String, dynamic>{
    'screen': screen,
    if (q['gms_partner_id'] != null) 'partner_id': q['gms_partner_id'],
    if (q['gms_booking_id'] != null) 'booking_id': q['gms_booking_id'],
    if (q['gms_recipient_id'] != null) 'recipient_id': q['gms_recipient_id'],
  };

  try {
    final remaining = Map<String, String>.from(q)
      ..removeWhere((k, _) => k.startsWith('gms_'));
    final cleaned = Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path,
      queryParameters: remaining.isEmpty ? null : remaining,
      fragment: u.hasFragment ? u.fragment : null,
    );
    html.window.history.replaceState(null, '', cleaned.toString());
  } catch (_) {}
  return data;
}
