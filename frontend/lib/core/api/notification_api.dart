// ─────────────────────────────────────────────
// core/api/notification_api.dart
//
// Real backend calls for /api/notifications — replaces the
// hardcoded mock data that notification_service.dart used to run
// on entirely. Matches the actual response shape from
// app/routers/notifications.py (cursor pagination, unread-count,
// mark-read, read-all, delete).
// ─────────────────────────────────────────────
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

  static Future<ApiResult> removePushToken(String token) =>
      ApiService.delete(
          '/notifications/push-token?token=${Uri.encodeQueryComponent(token)}');
}
