// ─────────────────────────────────────────────
// core/services/foreground_notifier_mobile.dart
//
// Android notifications drawn by the app (flutter_local_notifications
// 22.x, named-parameter API). Selected via conditional import; web uses
// foreground_notifier_web.dart / the service worker instead.
//
// Every notification uses the SAME slot as the FCM tray entry the backend
// sends (id 0 + tag — notify.py), so the app's richer version replaces the
// plain one instead of duplicating it; if the app's code can't run
// (force-stopped app) the plain FCM entry still shows.
//
// Chats — WhatsApp-style conversation: MessagingStyle with the sender's
// recent unread lines (`recent` in the push), their photo in the circle
// (`sender_avatar`; downloaded AFTER the notification is shown, initial as
// fallback), one slot per person (tag gms-chat-<id>). Tapping opens that
// chat. (The inline Reply action was removed in V14 — not reliable
// enough; replies are sent from the chat screen.)
//
// Booking & payment events — tag gms-n-<notif_id>, a "View" action. Only
// View marks THAT notification read (server-side, once) and dismisses it;
// tapping the body opens the booking without marking anything read.
// ─────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'chat_push.dart';

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

// High importance is required for a heads-up popup on Android. The id
// must match AndroidManifest.xml's
// com.google.firebase.messaging.default_notification_channel_id and the
// backend's android channel_id (notify.py) — all three are
// 'gms_default_channel'.
const AndroidNotificationChannel _channel = AndroidNotificationChannel(
  'gms_default_channel',
  'GMS Notifications',
  description: 'Chat, booking, and payment updates',
  importance: Importance.high,
);

const _initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'));

Map<String, dynamic>? _decode(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // A malformed payload must never crash the tap handler.
  }
  return null;
}

Future<void> _createChannel() async {
  await _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_channel);
}

void Function(Map<String, dynamic> data)? _onView;

/// UI isolate (app running). [onTap] = body tap (opens, marks nothing
/// read); [onView] = the View action (opens + marks that one read).
Future<void> initForegroundNotifier({
  void Function(Map<String, dynamic> data)? onTap,
  void Function(Map<String, dynamic> data)? onView,
}) async {
  _onView = onView;
  await _plugin.initialize(
    settings: _initSettings,
    onDidReceiveNotificationResponse: (response) {
      final data = _decode(response.payload);
      if (response.actionId == ChatPush.viewActionId) {
        if (data != null) _onView?.call(data);
        return;
      }
      if (onTap != null && data != null) onTap(data);
    },
  );
  await _createChannel();
}

/// FCM background isolate: the plugin must be initialised in THIS isolate
/// before it can post. (Taps and View open the app, so they arrive in the
/// UI isolate.)
Future<void> initNotifierInBackground() async {
  await _plugin.initialize(settings: _initSettings);
  await _createChannel();
}

// ── avatars ───────────────────────────────────────────────────────────
final Map<String, Uint8List> _avatarCache = {};

Future<Uint8List?> _downloadAvatar(String url) async {
  final cached = _avatarCache[url];
  if (cached != null) return cached;
  try {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 4));
    final bytes = res.bodyBytes;
    if (res.statusCode == 200 && bytes.isNotEmpty && bytes.length < 600000) {
      if (_avatarCache.length > 50) _avatarCache.clear();
      _avatarCache[url] = bytes;
      return bytes;
    }
  } catch (_) {
    // offline / 404 / timeout → keep the initial
  }
  return null;
}

/// Shows (or updates) the conversation notification. Never waits for the
/// avatar: it is shown with the initial (or a cached photo) first, then
/// re-posted silently once the photo has downloaded.
Future<void> showConversationNotification(Map<String, dynamic> data) async {
  final url = ChatPush.avatarUrl(data, ApiConfig.serverRoot);
  final cached = url == null ? null : _avatarCache[url];
  await _postConversation(data, avatar: cached);
  if (url != null && cached == null) {
    final bytes = await _downloadAvatar(url);
    if (bytes != null) {
      await _postConversation(data, avatar: bytes, silent: true);
    }
  }
}

Future<void> _postConversation(
  Map<String, dynamic> data, {
  Uint8List? avatar,
  bool silent = false,
}) async {
  final tag = ChatPush.conversationTag(data);
  if (tag == null) return;
  final sender = ChatPush.senderName(data);
  final senderPerson = Person(
    name: sender,
    key: 'gms-user-${ChatPush.partnerId(data) ?? ''}',
    icon: avatar == null ? null : ByteArrayAndroidIcon(avatar),
  );
  const me = Person(name: 'You', key: 'gms-me');
  final lines = ChatPush.recentLines(data);
  final messages = <Message>[
    for (final l in lines) Message(l.text, l.time, senderPerson),
  ];
  await _plugin.show(
    id: ChatPush.notificationId,
    title: sender,
    body: messages.isEmpty ? '' : messages.last.text,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
        tag: tag,
        // Lock screen: Android hides the content when the user chose to
        // hide sensitive notification content; otherwise it's shown.
        visibility: NotificationVisibility.private,
        category: AndroidNotificationCategory.message,
        // The photo re-post must not buzz again.
        onlyAlertOnce: silent,
        styleInformation: MessagingStyleInformation(
          me,
          groupConversation: false,
          messages: messages,
        ),
      ),
    ),
    payload: jsonEncode(data),
  );
}

/// Booking / payment event with a View action. Body tap opens the booking
/// (marks nothing); only View marks this notification read and dismisses
/// it (autoCancel off, so a body tap leaves it in the shade).
Future<void> showEventNotification(Map<String, dynamic> data,
    {required String title, required String body}) async {
  final tag = ChatPush.eventTag(data);
  await _plugin.show(
    id: tag == null
        ? (DateTime.now().millisecondsSinceEpoch & 0x7fffffff)
        : ChatPush.notificationId,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
        tag: tag,
        visibility: NotificationVisibility.private,
        autoCancel: false,
        styleInformation: BigTextStyleInformation(body),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            ChatPush.viewActionId,
            'View',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
    ),
    payload: jsonEncode(data),
  );
}

/// If the app was launched (from terminated) by tapping one of OUR
/// notifications, returns its data (`_action: gms_view` for View).
Future<Map<String, dynamic>?> takeLaunchNotificationData() async {
  try {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final r = details.notificationResponse;
    final data = _decode(r?.payload);
    if (data != null && r?.actionId == ChatPush.viewActionId) {
      data['_action'] = ChatPush.viewActionId;
    }
    return data;
  } catch (_) {
    return null;
  }
}

Future<void> showForegroundNotification({
  required String title,
  required String body,
  Map<String, dynamic>? data,
  String? tag,
}) async {
  if (data != null && tag != null && ChatPush.isChat(data)) {
    await showConversationNotification(data);
    return;
  }
  if (data != null && ChatPush.isBookingEvent(data)) {
    await showEventNotification(data, title: title, body: body);
    return;
  }
  // Other: the server's notification id — the same push shown twice
  // REPLACES itself, and two different ones never collide.
  final id = int.tryParse('${data?['notif_id'] ?? ''}') ??
      (DateTime.now().millisecondsSinceEpoch & 0x7fffffff);
  await _plugin.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
      ),
    ),
    payload: data == null ? null : jsonEncode(data),
  );
}

/// Clears a notification slot (system tray or ours) — a chat when it is
/// opened, a booking event when its View is pressed.
Future<void> cancelConversationNotification(String tag) async {
  try {
    await _plugin.cancel(id: ChatPush.notificationId, tag: tag);
  } catch (_) {}
}
