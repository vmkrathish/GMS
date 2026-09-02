// Chat endpoints — mirrors /api/chats (HTTP polling MVP)
import '../config/api_endpoints.dart';
import '../services/api_service.dart';

class ChatApi {
  /// My conversation list: partner, last message, unread count.
  static Future<ApiResult> getConversations() =>
      ApiService.get(ApiEndpoints.chats);

  /// Full thread with one user (their messages get marked read).
  static Future<ApiResult> getThread(int userId, {int limit = 50}) =>
      ApiService.get(ApiEndpoints.chatThread(userId),
          query: {'limit': '$limit'});

  static Future<ApiResult> sendMessage(int userId, String body) =>
      ApiService.post(ApiEndpoints.chatThread(userId), {'body': body});
}
