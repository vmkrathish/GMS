// ─────────────────────────────────────────────
// core/services/api_service.dart
//
// Single HTTP client for the whole app.
//  • Attaches JWT (saved after login) automatically
//  • 15s timeout + one retry for transient network errors
//  • Returns a typed ApiResult instead of raw http.Response
// ─────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';

/// Typed wrapper so screens never parse raw responses.
class ApiResult {
  final bool success;
  final int statusCode;
  final dynamic data; // decoded JSON (Map or List) or null
  final String message;

  const ApiResult({
    required this.success,
    required this.statusCode,
    this.data,
    this.message = '',
  });

  bool get isOffline => statusCode == 0;
}

class ApiService {
  static const _tokenKey = 'gms_jwt';

  // ── Token handling ──────────────────────────
  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  static Future<Map<String, String>> _headers() async {
    final token = await getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ── Core request with timeout + 1 retry ─────
  static Future<ApiResult> _send(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    var uri = Uri.parse(ApiConfig.baseUrl + endpoint);
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final headers = await _headers();
        late http.Response res;

        switch (method) {
          case 'GET':
            res = await http.get(uri, headers: headers).timeout(ApiConfig.timeout);
            break;
          case 'POST':
            res = await http
                .post(uri, headers: headers, body: jsonEncode(body ?? {}))
                .timeout(ApiConfig.timeout);
            break;
          case 'PUT':
            res = await http
                .put(uri, headers: headers, body: jsonEncode(body ?? {}))
                .timeout(ApiConfig.timeout);
            break;
          case 'DELETE':
            res = await http.delete(uri, headers: headers).timeout(ApiConfig.timeout);
            break;
          default:
            throw UnsupportedError(method);
        }

        dynamic decoded;
        try {
          decoded = res.body.isEmpty ? null : jsonDecode(res.body);
        } catch (_) {
          decoded = null;
        }

        final ok = res.statusCode >= 200 && res.statusCode < 300;
        return ApiResult(
          success: ok && (decoded is! Map || decoded['success'] != false),
          statusCode: res.statusCode,
          data: decoded,
          message: (decoded is Map && decoded['message'] != null)
              ? decoded['message'].toString()
              : (ok ? 'OK' : 'Request failed (${res.statusCode})'),
        );
      } on TimeoutException {
        if (attempt == 1) {
          return const ApiResult(
              success: false, statusCode: 0, message: 'Request timed out');
        }
      } on SocketException {
        if (attempt == 1) {
          return const ApiResult(
              success: false, statusCode: 0, message: 'No connection to server');
        }
      } catch (e) {
        return ApiResult(success: false, statusCode: 0, message: 'Error: $e');
      }
      await Future.delayed(const Duration(milliseconds: 600));
    }
    return const ApiResult(success: false, statusCode: 0, message: 'Unreachable');
  }

  // ── Public verbs ────────────────────────────
  static Future<ApiResult> get(String endpoint, {Map<String, String>? query}) =>
      _send('GET', endpoint, query: query);

  static Future<ApiResult> post(String endpoint, Map<String, dynamic> body) =>
      _send('POST', endpoint, body: body);

  static Future<ApiResult> put(String endpoint, Map<String, dynamic> body) =>
      _send('PUT', endpoint, body: body);

  static Future<ApiResult> delete(String endpoint) => _send('DELETE', endpoint);
}
