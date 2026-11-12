// ─────────────────────────────────────────────
// core/services/api_service.dart
//
// Single HTTP client for the whole app.
//  • Attaches JWT (saved after login) automatically
//  • 15s timeout + one retry for transient network errors
//  • Returns a typed ApiResult instead of raw http.Response
//  • Reports a rejected session (401 on a token-carrying request) via
//    [onSessionInvalid] so the app can return to Sign In
//  • [warmUp] wakes the server + its DB pool while Sign In is shown
// ─────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import 'device_identity.dart';
import 'request_outcome.dart';

/// Typed wrapper so screens never parse raw responses.
class ApiResult {
  final bool success;
  final int statusCode;
  final dynamic data; // decoded JSON (Map or List) or null
  final String message;

  /// True when no answer arrived within [ApiConfig.timeout] (both tries).
  final bool timedOut;

  const ApiResult({
    required this.success,
    required this.statusCode,
    this.data,
    this.message = '',
    this.timedOut = false,
  });

  bool get isOffline => statusCode == 0;

  /// offline / timeout / server error / rejected — see RequestOutcome.
  RequestProblem get problem => RequestOutcome.classify(
      success: success, statusCode: statusCode, timedOut: timedOut);
}

class ApiService {
  static const tokenKey = 'gms_jwt'; // also read by delivery_receipts.dart
  static const _tokenKey = tokenKey;

  /// Set once in main.dart. Called (not awaited) with the token that the
  /// server just rejected, so a stale reply can't log out a NEWER session.
  static void Function(String rejectedToken)? onSessionInvalid;

  static Future<void>? _warmUp;

  /// Fire-and-forget: GET /health?db=1 once per app run (again after a
  /// failure). A sleeping free-tier server starts waking — and opens its
  /// database connections — while the person is still typing, instead
  /// of after they tap Sign In. Never shows anything, never throws.
  static void warmUp() {
    _warmUp ??= () async {
      try {
        final res = await http
            .get(Uri.parse('${ApiConfig.serverRoot}/health?db=1'))
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != 200) _warmUp = null;
      } catch (_) {
        _warmUp = null; // allow another attempt (e.g. from Retry)
      }
    }();
  }

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

    // ONE key per user action, REUSED on the automatic retry below. If
    // the first attempt times out but the server (e.g. a Render instance
    // that was still waking up) processes it anyway, the retry carries
    // the same key and the server returns the first result instead of
    // creating a duplicate message/booking and a second push.
    final idempotencyKey =
        (method == 'POST' || method == 'PUT') ? DeviceIdentity.randomId() : null;

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final headers = await _headers();
        final sentToken = headers['Authorization']?.substring(7);
        if (idempotencyKey != null) {
          headers['Idempotency-Key'] = idempotencyKey;
        }
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

        if (sentToken != null &&
            RequestOutcome.endsSession(
                statusCode: res.statusCode,
                sentToken: true,
                endpoint: endpoint)) {
          onSessionInvalid?.call(sentToken);
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
              success: false,
              statusCode: 0,
              message: 'Request timed out',
              timedOut: true);
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
