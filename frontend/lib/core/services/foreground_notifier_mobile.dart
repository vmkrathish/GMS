// ─────────────────────────────────────────────
// core/services/foreground_notifier_mobile.dart
//
// Android (and other native platforms) foreground popup — using
// flutter_local_notifications, which does NOT officially support
// Web (that's why this is a separate file from the web version,
// selected via conditional import rather than one shared package
// call — using it unconditionally would break the web build).
// ─────────────────────────────────────────────
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

// High importance is required for a heads-up popup on Android — the
// default/low importance channels only show silently in the
// notification shade, easy to miss, which isn't the "popup" being
// asked for here.
const AndroidNotificationChannel _channel = AndroidNotificationChannel(
  'gms_default_channel',
  'GMS Notifications',
  description: 'Chat, booking, and payment updates',
  importance: Importance.high,
);

Future<void> initForegroundNotifier() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _plugin.initialize(
    const InitializationSettings(android: androidInit),
  );
  await _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_channel);
}

Future<void> showForegroundNotification(
    {required String title, required String body}) async {
  await _plugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000, // unique-enough id
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}
