// ─────────────────────────────────────────────
// core/api/notification_api.dart
//
// Real backend calls for /api/notifications — replaces the
// hardcoded mock data that notification_service.dart used to run
// on entirely. Matches the actual response shape from
// app/routers/notifications.py (cursor pagination, unread-count,
// mark-read, read-all, delete).
// ─────────────────────────────────────────────
import '../config/api_endpoints.dart';
import '../services/api_service.dart';

class NotificationApi {
  static Future<ApiResult> list({String? cursor}) => ApiService.get(
        '/notifications',
        query: cursor != null ? {'cursor': cursor} : null,
      );

  static Future<ApiResult> unreadCount() =>
      ApiService.get('/notifications/unread-count');

  static Future<ApiResult> markRead(int id) =>
      ApiService.put('/notifications/$id/read', {});

  static Future<ApiResult> markAllRead() =>
      ApiService.put('/notifications/read-all', {});

  static Future<ApiResult> delete(int id) =>
      ApiService.delete('/notifications/$id');

  static Future<ApiResult> registerPushToken({
    required String token,
    required String platform,
    String? deviceId,
  }) =>
      ApiService.post('/notifications/push-token', {
        'token': token,
        'platform': platform,
        if (deviceId != null) 'device_id': deviceId,
      });

  /// Deactivates THIS device for the signed-in user. Matches by token
  /// and/or device id (the id still works if the cached token was lost).
  static Future<ApiResult> removePushToken({String? token, String? deviceId}) {
    final q = <String, String>{
      if (token != null && token.isNotEmpty) 'token': token,
      if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
    };
    if (q.isEmpty) {
      return Future.value(const ApiResult(
          success: false, statusCode: 400, message: 'nothing to remove'));
    }
    final qs = q.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return ApiService.delete('/notifications/push-token?$qs');
  }

  /// Login-only welcome push to THIS device (backend: one device, at most
  /// once per two minutes). Called by FcmService after registration.
  static Future<ApiResult> requestLoginWelcome(String deviceId) =>
      ApiService.post(ApiEndpoints.loginWelcome, {'device_id': deviceId});

  /// Bookings badge + per-booking "New" markers (server state, same on
  /// every device). Reading it never marks anything seen.
  static Future<ApiResult> bookingUnseen() =>
      ApiService.get('/notifications/booking-unseen');

  /// The user opened THIS booking's details: its unseen events are seen.
  static Future<ApiResult> markBookingSeen(int bookingId) =>
      ApiService.put('/notifications/booking/$bookingId/seen', {});
}
