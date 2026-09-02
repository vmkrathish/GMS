// User endpoints — mirrors gms_backend /api/users
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../config/api_config.dart';
import '../config/api_endpoints.dart';
import '../services/api_service.dart';

class UserApi {
  static Future<ApiResult> getMe() => ApiService.get(ApiEndpoints.me);

  static Future<ApiResult> updateMe({String? name, String? city}) =>
      ApiService.put(ApiEndpoints.me, {
        if (name != null) 'name': name,
        if (city != null) 'city': city,
      });

  /// Full profile update (You-page model: identity, dial code,
  /// live location text, complete address, coordinates, avatar_url…).
  static Future<ApiResult> updateProfile(Map<String, dynamic> fields) =>
      ApiService.put(ApiEndpoints.me, fields);

  // Note: FCM token registration lives in NotificationApi
  // (registerPushToken/removePushToken) — those target the real
  // multi-device user_push_tokens table. An older single-token
  // method used to live here, writing to the now-deprecated
  // users.fcm_token column; removed since nothing called it.

  static Future<ApiResult> getUserById(int id) =>
      ApiService.get(ApiEndpoints.userById(id));

  /// Individual customer reviews for a provider, newest first —
  /// what a rating summary ("4.8 (12)") can't show on its own.
  static Future<ApiResult> getProviderReviews(int providerId,
          {int limit = 20, int offset = 0}) =>
      ApiService.get('/users/$providerId/reviews', query: {
        'limit': '$limit',
        'offset': '$offset',
      });

  /// Uploads a profile photo — the ONLY way avatar_url ever changes.
  /// [bytes] is the already-cropped image; [filename] just needs a
  /// recognizable extension (jpg/png/webp).
  ///
  /// IMPORTANT: http.MultipartFile.fromBytes defaults to
  /// application/octet-stream when no contentType is given — the
  /// backend strictly rejects anything that isn't image/jpeg,
  /// image/png, or image/webp, so this must be set explicitly or
  /// every single upload fails with a 400 the caller may never see.
  static Future<ApiResult> uploadAvatar(
      List<int> bytes, String filename) async {
    try {
      final token = await ApiService.getToken();
      final uri = Uri.parse('${ApiConfig.baseUrl}${ApiEndpoints.meAvatar}');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: MediaType('image', 'png'),
        ));

      final streamed = await request.send().timeout(ApiConfig.timeout);
      final body = await streamed.stream.bytesToString();
      final decoded = body.isEmpty ? null : jsonDecode(body);
      final ok = streamed.statusCode >= 200 && streamed.statusCode < 300;

      return ApiResult(
        success: ok && (decoded is! Map || decoded['success'] != false),
        statusCode: streamed.statusCode,
        data: decoded,
        message: (decoded is Map && decoded['message'] != null)
            ? decoded['message'].toString()
            : (ok ? 'OK' : 'Upload failed'),
      );
    } catch (e) {
      return ApiResult(success: false, statusCode: 0, message: 'Error: $e');
    }
  }

  /// Removes the profile photo server-side (sets avatar_url to null).
  static Future<ApiResult> deleteAvatar() =>
      ApiService.delete(ApiEndpoints.meAvatar);
}
