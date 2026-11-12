// Auth endpoints — mirrors gms_backend /api/auth
import 'package:flutter/foundation.dart' show debugPrint;

import '../config/api_endpoints.dart';
import '../services/api_service.dart';
import '../services/session_manager.dart';

class AuthApi {
  // ── Simple auth (MVP path — no OTP yet) ─────

  /// Sign up with the basics: name, phone, email, password.
  /// On success the JWT + user profile are saved locally.
  static Future<ApiResult> signup({
    required String name,
    required String phone,
    required String password,
    String? email,
  }) async {
    final res = await ApiService.post(ApiEndpoints.signup, {
      'name': name,
      'phone': phone,
      'password': password,
      if (email != null && email.isNotEmpty) 'email': email,
    });
    await _persistIfSuccess(res);
    return res;
  }

  /// Sign in with phone number OR email + password.
  static Future<ApiResult> login(String identifier, String password) async {
    final sw = Stopwatch()..start();
    final res = await ApiService.post(ApiEndpoints.login, {
      'identifier': identifier,
      'password': password,
    });
    final httpMs = sw.elapsedMilliseconds;
    await _persistIfSuccess(res);
    // Shows in `flutter run` / browser console — compare with the
    // backend's "login ok total=…" log line to see network vs server time.
    debugPrint('[perf] login: ${sw.elapsedMilliseconds} ms '
        '(http $httpMs ms, status ${res.statusCode}, problem ${res.problem.name})');
    return res;
  }

  /// Change password from Settings — requires the current password.
  static Future<ApiResult> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      ApiService.put(ApiEndpoints.changePassword, {
        'current_password': currentPassword,
        'new_password': newPassword,
      });

  /// Side-effect-free check used while typing the "Current password"
  /// field — tells the person immediately if it's wrong, rather than
  /// waiting until the whole form is submitted.
  static Future<bool?> verifyPassword(String password) async {
    final res = await ApiService.post(
        ApiEndpoints.verifyPassword, {'password': password});
    if (res.success && res.data is Map && res.data['valid'] is bool) {
      return res.data['valid'] as bool;
    }
    return null; // couldn't check (offline etc.) — caller should not block on this
  }

  static Future<void> _persistIfSuccess(ApiResult res) async {
    if (res.success && res.data is Map && res.data['token'] != null) {
      await SessionManager.saveSession(
        token: res.data['token'],
        user: Map<String, dynamic>.from(res.data['user'] ?? {}),
      );
    }
  }

  // ── Firebase OTP path (production upgrade) ──

  /// Step 2 of OTP login: Flutter verified OTP with Firebase → send idToken.
  static Future<ApiResult> verifyOtp({
    required String idToken,
    String? name,
    String? role,
    String? fcmToken,
  }) async {
    final res = await ApiService.post(ApiEndpoints.verifyOtp, {
      'idToken': idToken,
      if (name != null) 'name': name,
      if (role != null) 'role': role,
      if (fcmToken != null) 'fcm_token': fcmToken,
    });
    await _persistIfSuccess(res);
    return res;
  }

  static Future<ApiResult> register(Map<String, dynamic> body) =>
      ApiService.post(ApiEndpoints.register, body);

  static Future<void> logout() => SessionManager.logout();
}
