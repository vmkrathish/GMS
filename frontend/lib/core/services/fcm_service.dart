// ─────────────────────────────────────────────
// core/services/fcm_service.dart
//
// Firebase Cloud Messaging — client side. Handles permission
// request, token registration (multi-device, via NotificationApi's
// real /push-token endpoints), token refresh, foreground/
// background/terminated message handling, and tap-to-navigate.
//
// iOS is deliberately left untouched here — no APNs entitlement
// exists yet, so calling getToken() on iOS would either throw or
// return null depending on platform state. This file only runs its
// real logic on Android and Web; iOS silently no-ops so the rest of
// the app is unaffected and this activates later with zero redesign
// once APNs is available.
// ─────────────────────────────────────────────
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/notification_api.dart';
import '../api/user_api.dart';
import '../models/notification_service.dart' show NotificationService;
import 'foreground_notifier.dart';
import '../../presentation/screens/chat_screen.dart';
import '../../presentation/screens/notifications_screen.dart';
import '../../presentation/screens/bookings_screen.dart';

/// Must be a top-level (or static) function — background message
/// handling runs in its own isolate, separate from the running app,
/// so it can't close over any app state.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Deliberately minimal: the notification history record already
  // exists in Postgres (created server-side by notify() before the
  // push was even sent — see app/services/notify.py), so there's
  // nothing to persist here. This handler exists so Android doesn't
  // log a warning about a missing background handler; the system
  // tray notification itself is shown automatically by FCM/Android
  // for a message with a `notification` payload.
}

class FcmService {
  FcmService._private();
  static final FcmService _instance = FcmService._private();
  factory FcmService() => _instance;

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  bool _initialized = false;
  String? _currentToken;

  bool get _iosNotReady =>
      !kIsWeb &&
      defaultTargetPlatform ==
          TargetPlatform.iOS; // see file header — paused until APNs exists

  Future<void> initialize() async {
    if (_initialized || _iosNotReady) return;
    _initialized = true;

    try {
      if (kIsWeb) {
        // Web has no equivalent of google-services.json's
        // auto-detection — needs explicit config. See
        // web/firebase-messaging-sw.js's header for where to get
        // these exact values (they must match).
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: _webApiKey,
            appId: _webAppId,
            messagingSenderId: '585041395098', // known — matches google-services.json
            projectId: 'gms---get-my-service', // known — matches google-services.json
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

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await initForegroundNotifier();

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true, badge: true, sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      // Handled gracefully — in-app notification history keeps
      // working regardless (see NotificationService); we simply
      // never register a token, and never ask again this session.
      debugPrint('FCM: notification permission denied');
      return;
    }

    if (kIsWeb) {
      // Web needs the VAPID public key to fetch a token — see
      // web/firebase-messaging-sw.js and the vapidKey placeholder
      // below, which must be filled in once available.
      _currentToken = await messaging.getToken(
        vapidKey: _webVapidKey.isEmpty ? null : _webVapidKey,
      );
    } else {
      _currentToken = await messaging.getToken();
    }

    if (_currentToken != null) {
      await _registerToken(_currentToken!);
    }

    messaging.onTokenRefresh.listen((newToken) async {
      _currentToken = newToken;
      await _registerToken(newToken);
    });

    // Foreground: FCM does NOT show a system tray notification by
    // itself while the app is open (this is normal, documented FCM
    // behavior, not a bug) — refresh the in-app badge instead, since
    // the person is already looking at the app.
    FirebaseMessaging.onMessage.listen((message) {
      NotificationService().refreshUnreadCount();
      // THE FIX: FCM does not auto-display a system popup while the
      // app is in the foreground — on Android or in a browser, that
      // auto-display only happens for background/terminated apps.
      // This was previously entirely missing, which is exactly why
      // "open the app, send a message, no popup appears" happened —
      // the notification history updated correctly (that part was
      // never broken), but nothing ever told the OS to actually show
      // a visible alert while the app was in front of the person.
      final title = message.notification?.title ?? 'GMS';
      final body = message.notification?.body ?? '';
      if (body.isNotEmpty) {
        showForegroundNotification(title: title, body: body);
      }
    });

    // Tapped while app was in background (not terminated).
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _handleTap(message.data);
    });

    // App was fully terminated, launched BY tapping the notification.
    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      // Wait a beat for the navigator to actually be mounted.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleTap(initialMessage.data);
      });
    }
  }

  // Web app's Firebase config (from Project Settings -> your Web
  // app -> SDK setup and configuration). Separate from
  // google-services.json, which is Android-only.
  static const String _webApiKey = 'AIzaSyDGetZsU0ydKz5ws4ONS0zg9rAIMJhvGSg';
  static const String _webAppId =
      '1:585041395098:web:7cad9fa106146e11264e23';
  static const String _webAuthDomain =
      'gms---get-my-service.firebaseapp.com';

  // Provided earlier (Firebase Console -> Cloud Messaging tab ->
  // Web Push certificates).
  static const String _webVapidKey =
      'BEEKCGWUWr5Bpb9vNAVInD9AYrZn4L98v1DPpCHuVFTcDGqrD0BI_54L_lpkSfnP-gRnHO36O-kiTwONUHYIG7g';

  Future<void> _registerToken(String token) async {
    await NotificationApi.registerPushToken(
      token: token,
      platform: kIsWeb ? 'web' : 'android',
      deviceId: kIsWeb ? null : null, // no reliable cross-platform
      // device id without an extra plugin; token uniqueness alone
      // is already enough to identify this device server-side.
    );
  }

  /// Call on logout — deactivates only THIS device's token, never
  /// another device's (see notifications.py's remove_push_token,
  /// which is already scoped to token+user_id).
  Future<void> deactivateCurrentToken() async {
    if (_currentToken != null) {
      await NotificationApi.removePushToken(_currentToken!);
    }
  }

  /// Routes a tapped notification to the right screen, using the
  /// same `data` shape notify() already attaches server-side (see
  /// app/routers/chats.py, app/services/booking_engine.py):
  /// {"screen": "chat", "partner_id": N} or
  /// {"screen": "booking", "booking_id": N}.
  Future<void> _handleTap(Map<String, dynamic> data) async {
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
        // No single-booking deep screen exists yet — the Bookings
        // list is the correct, honest target rather than guessing
        // at a route that isn't there.
        nav.push(MaterialPageRoute(builder: (_) => const BookingsScreen()));
        break;

      default:
        nav.push(
            MaterialPageRoute(builder: (_) => const NotificationsScreen()));
    }
  }
}
