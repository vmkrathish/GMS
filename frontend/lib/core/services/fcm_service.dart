// ─────────────────────────────────────────────
// core/services/fcm_service.dart
//
// Firebase Cloud Messaging — client side.
//
// Two separate concerns (this split is the multi-user fix):
//
//   1. INFRASTRUCTURE — initialize(): Firebase, permission, message
//      listeners. Runs ONCE per app process.
//   2. REGISTRATION   — syncRegistration(): tells the server "this
//      device's token belongs to the signed-in user". Runs for EVERY
//      session: first login, logout → login, account switch, token
//      refresh. The decisions (retry/backoff/cancel/dedupe) live in
//      PushRegistrar so they're unit-testable.
//
// Previously both lived in one run-once initialize(), so after logout
// (which deactivates the token) the next login never re-registered it.
//
// Logout also deletes this device's FCM token, so even if the server
// call fails (offline / expired session) FCM stops delivering the
// previous user's notifications here; the next login mints a new one.
//
// iOS is deliberately left untouched — no APNs entitlement exists yet.
// ─────────────────────────────────────────────
import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/notification_api.dart';
import '../api/user_api.dart';
import '../models/notification_service.dart' show NotificationService;
import 'api_service.dart';
import 'app_navigation.dart';
import 'chat_push.dart';
import 'delivery_receipts.dart';
import 'device_identity.dart';
import 'foreground_notifier.dart';
import 'push_registrar.dart';
import 'session_manager.dart';
import 'web_notification_bridge.dart';
import '../../presentation/screens/chat_screen.dart';
import '../../presentation/screens/notifications_screen.dart';

/// Must be a top-level (or static) function — background message
/// handling runs in its own isolate, separate from the running app,
/// so it can't close over any app state.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // The notification history record already exists in Postgres
  // (created server-side before the push was sent), and Android shows the
  // tray notification itself for a message with a `notification` payload
  // — tagged per conversation, so it updates that chat's entry. (Not used
  // on web — the service worker does that job.)
  //
  // The one thing done here: acknowledge a chat message as DELIVERED to
  // this device. Runs in a background isolate, so plugins are registered
  // first. Android does not run this for a force-stopped app.
  DartPluginRegistrant.ensureInitialized();
  await DeliveryReceipts.ackFromPush(message.data);
  // Replace the plain FCM tray entry (same tag, id 0) with the
  // conversation notification: recent lines + Reply. If this fails, the
  // plain one simply stays.
  if (ChatPush.isChat(message.data)) {
    try {
      final data = Map<String, dynamic>.from(message.data);
      data['title'] ??= message.notification?.title;
      data['body'] ??= message.notification?.body;
      await initNotifierInBackground();
      await showConversationNotification(data);
    } catch (_) {}
  } else if (ChatPush.isBookingEvent(message.data)) {
    // Booking / payment event: same slot as the FCM entry, plus "View".
    try {
      final data = Map<String, dynamic>.from(message.data);
      await initNotifierInBackground();
      await showEventNotification(data,
          title: message.notification?.title ?? '${data['title'] ?? 'GMS'}',
          body: message.notification?.body ?? '${data['body'] ?? ''}');
    } catch (_) {}
  }
}

class FcmService {
  FcmService._private();
  static final FcmService _instance = FcmService._private();
  factory FcmService() => _instance;

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  bool _infraReady = false;
  Future<void>? _infraFuture;
  bool _permissionDenied = false;
  bool _startupLinksHandled = false;
  String? _currentToken;

  late final PushRegistrar _registrar = PushRegistrar(
    fetchToken: _ensureToken,
    register: _registerOnServer,
    deviceId: DeviceIdentity.deviceId,
    sessionId: ApiService.getToken,
    onLog: (m) => debugPrint('FCM: $m'),
  );

  bool get _iosNotReady =>
      !kIsWeb &&
      defaultTargetPlatform ==
          TargetPlatform.iOS; // see file header — paused until APNs exists

  // ───────────────── public API ─────────────────

  /// Call when the signed-in UI is on screen (GMSMainPage.initState).
  /// Safe to call repeatedly: infrastructure starts once, registration
  /// is deduplicated, startup deep links are consumed once.
  Future<void> start() async {
    await initialize();
    if (!_startupLinksHandled && _infraReady) {
      _startupLinksHandled = true;
      await _handleStartupLinks();
    }
    await syncRegistration();
  }

  /// One-time infrastructure. Idempotent; concurrent calls share a run;
  /// a failed attempt (e.g. Firebase init) can be retried later.
  Future<void> initialize() {
    if (_infraReady || _iosNotReady) return Future.value();
    return _infraFuture ??= _initializeInfra().whenComplete(() {
      if (!_infraReady) _infraFuture = null;
    });
  }

  /// Registers THIS device's token for the signed-in user (with retry/
  /// backoff). Idempotent per session.
  Future<bool> syncRegistration() async {
    await initialize();
    if (!_infraReady) return false;
    if (_permissionDenied) {
      // The person may have allowed notifications in system/browser
      // settings since the prompt was denied — re-check instead of
      // staying silent until the next app restart.
      try {
        final s = await FirebaseMessaging.instance.getNotificationSettings();
        _permissionDenied =
            s.authorizationStatus == AuthorizationStatus.denied;
      } catch (_) {}
      if (_permissionDenied) return false;
    }
    final ok = await _registrar.sync();
    if (ok && _welcomeAfterRegistration) {
      _welcomeAfterRegistration = false;
      unawaited(_sendLoginWelcome());
    }
    return ok;
  }

  /// Set ONLY by a successful interactive sign-in (LoginScreen). The
  /// welcome push is requested once this device's token is registered —
  /// never on app start with a saved session, never on token refresh.
  bool _welcomeAfterRegistration = false;

  void welcomeAfterNextRegistration() => _welcomeAfterRegistration = true;

  Future<void> _sendLoginWelcome() async {
    try {
      await NotificationApi.requestLoginWelcome(await DeviceIdentity.deviceId());
    } catch (_) {
      // Best effort; a missed welcome is harmless.
    }
  }

  /// SessionManager.saveSession() calls this after every successful
  /// login/signup. Starts a new registration "generation" — cancelling
  /// any retry loop left over from the previous session — and, if push
  /// is already running, registers right away. (On the very first login
  /// push isn't started yet; GMSMainPage.start() does it.)
  void onLogin() {
    _registrar.reset();
    if (_infraFuture != null || _infraReady) {
      unawaited(syncRegistration());
    }
  }

  /// Call on logout, BEFORE the auth token is cleared (the server call
  /// is authenticated). Kept under its original name for SessionManager.
  Future<void> deactivateCurrentToken() async {
    _registrar.reset(); // stop any in-flight/retrying registration first
    try {
      final deviceId = await DeviceIdentity.deviceId();
      await NotificationApi.removePushToken(
              token: _currentToken, deviceId: deviceId)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('FCM: server-side token removal failed ($e) — relying on '
          'FCM token deletion + device sweep');
    }
    if (_infraReady) {
      try {
        // Invalidate the token on the device itself, so the previous
        // user's pushes stop here even if the call above failed.
        await FirebaseMessaging.instance.deleteToken();
      } catch (e) {
        debugPrint('FCM: deleteToken failed — $e');
      }
    }
    _currentToken = null;
  }

  // ───────────────── infrastructure ─────────────────

  Future<void> _initializeInfra() async {
    try {
      if (kIsWeb) {
        // Web has no equivalent of google-services.json's
        // auto-detection — needs explicit config. See
        // web/firebase-messaging-sw.js (the values must match).
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: _webApiKey,
            appId: _webAppId,
            messagingSenderId: '585041395098',
            projectId: 'gms---get-my-service',
            authDomain: _webAuthDomain,
            storageBucket: 'gms---get-my-service.firebasestorage.app',
          ),
        );
      } else {
        await Firebase.initializeApp();
      }
    } catch (e) {
      debugPrint('FCM: Firebase.initializeApp failed — $e');
      return;
    }

    // Web background messages are handled by the service worker, not by
    // a Dart isolate.
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }
    await initForegroundNotifier(onTap: _handleTap, onView: _handleView);
    if (kIsWeb) listenForNotificationClicks(_handleTap);

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      // In-app notification history keeps working regardless; we just
      // never register a token.
      debugPrint('FCM: notification permission denied');
      _permissionDenied = true;
    }

    // Token rotated by FCM. If signed out this is a no-op (the cached
    // value is simply used at the next login).
    messaging.onTokenRefresh.listen((newToken) {
      _currentToken = newToken;
      unawaited(_registrar.sync(token: newToken));
    });

    // Foreground: FCM does NOT show a system notification while the app
    // is open — show our own popup, but only for the signed-in user.
    FirebaseMessaging.onMessage.listen((message) async {
      if (!await _isForCurrentUser(message.data)) return;
      // Device received it → "delivered" (two grey ticks) for the sender.
      unawaited(DeliveryReceipts.ackFromPush(message.data));
      NotificationService().refreshUnreadCount();
      // Android messages carry a `notification` block; web messages are
      // data-only (title/body in data) so the service worker is the only
      // place that ever displays them — see notify.py build_message.
      final title = message.notification?.title ??
          message.data['title']?.toString() ??
          'GMS';
      final body = message.notification?.body ??
          message.data['body']?.toString() ??
          '';
      if (body.isNotEmpty) {
        await showForegroundNotification(
          title: title,
          body: body,
          data: Map<String, dynamic>.from(message.data),
          // Same slot as the system tray notification for this chat.
          tag: ChatPush.conversationTag(message.data),
        );
      }
    });

    // Tapped while the app was in the background (not terminated).
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _handleTap(message.data);
    });

    _infraReady = true;
  }

  /// Notification that launched the app (terminated → tapped), plus a
  /// web deep link carried in the URL. Consumed once, after the signed-in
  /// UI exists — never while the login screen is showing.
  Future<void> _handleStartupLinks() async {
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _handleTap(initial.data));
      }
    } catch (_) {}
    // Our own foreground popup (a local notification) tapped after the
    // app was killed — FCM's getInitialMessage() never sees those.
    final launched = await takeLaunchNotificationData();
    if (launched != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _handleTap(launched));
    }
    final link = takeInitialDeepLink();
    if (link != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleTap(link));
    }
  }

  // ───────────────── token plumbing ─────────────────

  Future<String?> _ensureToken() async {
    final cached = _currentToken;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final messaging = FirebaseMessaging.instance;
      final token = kIsWeb
          ? await messaging.getToken(
              vapidKey: _webVapidKey.isEmpty ? null : _webVapidKey)
          : await messaging.getToken();
      _currentToken = token;
      return token;
    } catch (e) {
      debugPrint('FCM: getToken failed — $e');
      return null; // PushRegistrar treats this as "not ready yet" and retries
    }
  }

  Future<RegisterStatus> _registerOnServer(
      String token, String deviceId) async {
    final res = await NotificationApi.registerPushToken(
      token: token,
      platform: kIsWeb ? 'web' : 'android',
      deviceId: deviceId,
    );
    return PushRegistrar.classify(res.statusCode, res.success);
  }

  // Web app's Firebase config (from Project Settings -> your Web
  // app -> SDK setup and configuration). Separate from
  // google-services.json, which is Android-only.
  static const String _webApiKey = 'AIzaSyDGetZsU0ydKz5ws4ONS0zg9rAIMJhvGSg';
  static const String _webAppId = '1:585041395098:web:7cad9fa106146e11264e23';
  static const String _webAuthDomain = 'gms---get-my-service.firebaseapp.com';

  // Firebase Console -> Cloud Messaging -> Web Push certificates.
  static const String _webVapidKey = 'BEEKCGWUWr5Bpb9vNAVInD9AYrZn4L98v1DPpCHuVFTcDGqrD0BI_54L_lpkSfnP-gRnHO36O-kiTwONUHYIG7g';

  // ───────────────── routing ─────────────────

  /// A push is for the account it was addressed to. If this device has
  /// since switched to someone else (or is signed out), drop it rather
  /// than show/route another user's notification.
  Future<bool> _isForCurrentUser(Map<String, dynamic> data) async {
    final recipient = data['recipient_id']?.toString();
    if (recipient == null || recipient.isEmpty) return true; // older payloads
    final me = await SessionManager.getUser();
    return me != null && '${me['id']}' == recipient;
  }

  /// Routes a tapped notification using the `data` notify() attaches:
  /// {"screen": "chat", "partner_id": N} or
  /// {"screen": "booking", "booking_id": N}.
  /// "View" on a booking/payment notification: mark exactly that
  /// notification read on the server (idempotent — the unread count drops
  /// once, on every device), dismiss it, open that booking.
  Future<void> _handleView(Map<String, dynamic> data) async {
    if (!await _isForCurrentUser(data)) return;
    final id = ChatPush.notifId(data);
    if (id != null) {
      unawaited(NotificationApi.markRead(id)
          .then((_) => NotificationService().refreshUnreadCount()));
    }
    final tag = ChatPush.eventTag(data);
    if (tag != null) unawaited(cancelConversationNotification(tag));
    _openBookingInShell(data, fromView: true);
  }

  /// Booking notifications open INSIDE the normal app (Bookings tab of
  /// GMSMainPage, right sub-tab, booking highlighted + details) — never a
  /// bare pushed screen (that rendered without Material styling) and
  /// never a browser/API URL.
  void _openBookingInShell(Map<String, dynamic> data, {bool fromView = false}) {
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    AppNavigation.openBooking(ChatPush.bookingId(data), fromView: fromView);
  }

  Future<void> _handleTap(Map<String, dynamic> data) async {
    if (!await _isForCurrentUser(data)) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    final screen = data['screen']?.toString();
    switch (screen) {
      case 'chat':
        final partnerId = int.tryParse('${data['partner_id']}');
        if (partnerId == null) break;
        // The push payload only carries the id — fetch the name so
        // the thread header shows something real, not a blank.
        final res = await UserApi.getUserById(partnerId);
        final partnerName = (res.success && res.data is Map)
            ? (res.data['user']?['name'] ?? 'Chat').toString()
            : 'Chat';
        nav.push(MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
              partnerId: partnerId, partnerName: partnerName),
        ));
        break;

      case 'booking':
        if (data['_action'] == ChatPush.viewActionId) {
          await _handleView(data); // View pressed while the app was killed
          return;
        }
        // Body tap: open the booking, mark NOTHING read.
        _openBookingInShell(data);
        break;

      default:
        nav.push(
            MaterialPageRoute(builder: (_) => const NotificationsScreen()));
    }
  }
}
