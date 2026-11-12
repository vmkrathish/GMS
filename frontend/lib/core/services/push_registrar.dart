// ─────────────────────────────────────────────
// core/services/push_registrar.dart
//
// Decides WHEN this device's push token gets registered with the
// server, and keeps that correct across logout / login / account
// switches / flaky networks. Deliberately free of Firebase and Flutter
// imports so the logic is unit-testable (see test/push_registrar_test.dart);
// FcmService supplies the real token source and network call.
//
// What it guarantees
//   • Registration is tied to the CURRENT SESSION, not to the app
//     process. After logout → login (same or different user) the token
//     is registered again without an app restart — reset() starts a new
//     "generation" and sync() registers under the new session.
//   • A retry loop belonging to an old session (user logged out or
//     switched while a request was failing) is cancelled: every await
//     re-checks the generation, so a stale loop can never register the
//     token for the previous user.
//   • Failures retry with capped exponential backoff + jitter, long
//     enough to outlast a Render cold start (~30-90s); permanent errors
//     (401/403/400…) stop immediately instead of hammering the server.
//   • Concurrent sync() calls share ONE in-flight attempt, and a token
//     already registered for this session is not re-sent.
// ─────────────────────────────────────────────
import 'dart:async';
import 'dart:math';

enum RegisterStatus {
  /// Server accepted the token.
  success,

  /// Network error, timeout, 408/429/5xx — worth retrying.
  retry,

  /// 4xx the server will keep rejecting (bad request, not signed in…).
  fatal,
}

typedef TokenFetcher = Future<String?> Function();
typedef RegisterCall = Future<RegisterStatus> Function(
    String token, String deviceId);
typedef DeviceIdFn = Future<String> Function();

/// Identifies the signed-in session (e.g. the JWT); null = signed out.
typedef SessionIdFn = Future<String?> Function();
typedef DelayFn = Future<void> Function(Duration d);

class PushRegistrar {
  PushRegistrar({
    required this.fetchToken,
    required this.register,
    required this.deviceId,
    required this.sessionId,
    DelayFn? delay,
    Random? random,
    this.maxAttempts = 6,
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 60),
    this.onLog,
  })  : _delay = delay ?? ((d) => Future<void>.delayed(d)),
        _random = random ?? Random();

  final TokenFetcher fetchToken;
  final RegisterCall register;
  final DeviceIdFn deviceId;
  final SessionIdFn sessionId;
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final void Function(String message)? onLog;

  final DelayFn _delay;
  final Random _random;

  int _generation = 0;
  String? _registeredKey;
  Future<bool>? _inFlight;

  /// Bumped by [reset]; exposed for tests/diagnostics.
  int get generation => _generation;

  /// True once the current session's token is known to be on the server.
  bool get isRegistered => _registeredKey != null;

  /// Maps an HTTP outcome to a [RegisterStatus].
  static RegisterStatus classify(int statusCode, bool success) {
    if (success) return RegisterStatus.success;
    if (statusCode == 0 ||
        statusCode == 408 ||
        statusCode == 429 ||
        statusCode >= 500) {
      return RegisterStatus.retry; // offline / timeout / server waking up
    }
    return RegisterStatus.fatal; // 400, 401, 403, 404, 422 …
  }

  /// capped exponential: base, 2·base, 4·base … up to [maxDelay].
  Duration nominalBackoff(int attempt) {
    final ms = baseDelay.inMilliseconds * pow(2, attempt).toInt();
    return Duration(milliseconds: min(ms, maxDelay.inMilliseconds));
  }

  /// nominal + up to 250 ms jitter, so many clients don't retry in lockstep.
  Duration backoffFor(int attempt) =>
      nominalBackoff(attempt) + Duration(milliseconds: _random.nextInt(250));

  /// Forget everything and cancel in-flight work. Call on logout AND on
  /// login — the next [sync] then registers for the new session.
  void reset() {
    _generation++;
    _registeredKey = null;
    _inFlight = null;
  }

  /// Registers the current token for the signed-in user. Safe to call
  /// often and concurrently. Pass [token] for a token-refresh event.
  /// Completes true when the server has the token, false otherwise.
  Future<bool> sync({String? token}) {
    if (token == null) {
      final running = _inFlight;
      if (running != null) return running;
    }
    final gen = _generation;
    late final Future<bool> flight;
    flight = _run(gen, token).whenComplete(() {
      if (identical(_inFlight, flight)) _inFlight = null;
    });
    if (token == null) _inFlight = flight;
    return flight;
  }

  Future<bool> _run(int gen, String? tokenOverride) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (gen != _generation) return _cancelled();

      final session = await sessionId();
      if (gen != _generation) return _cancelled();
      if (session == null) {
        onLog?.call('not signed in — nothing to register');
        return false;
      }

      final token = tokenOverride ?? await fetchToken();
      if (gen != _generation) return _cancelled();

      if (token == null || token.isEmpty) {
        // Permission still pending, or the browser's service worker /
        // FCM isn't ready yet — same treatment as a network failure.
        onLog?.call('no token available yet (attempt ${attempt + 1})');
      } else {
        final dev = await deviceId();
        if (gen != _generation) return _cancelled();

        final key = '$session|$token|$dev';
        if (_registeredKey == key) return true; // already done this session

        final status = await register(token, dev);
        // The user may have logged out / switched while the request was
        // in flight. Do NOT record it as registered for the new session;
        // logout deletes the FCM token and the server sweeps the device
        // when the next user registers, so a late landing is harmless.
        if (gen != _generation) return _cancelled();

        switch (status) {
          case RegisterStatus.success:
            _registeredKey = key;
            onLog?.call('token registered');
            return true;
          case RegisterStatus.fatal:
            onLog?.call('registration rejected — not retrying');
            return false;
          case RegisterStatus.retry:
            onLog?.call('registration failed (attempt ${attempt + 1}); '
                'will retry');
        }
      }

      if (attempt == maxAttempts - 1) break;
      await _delay(backoffFor(attempt));
    }
    if (gen == _generation) {
      onLog?.call('gave up registering after $maxAttempts attempts');
    }
    return false;
  }

  bool _cancelled() {
    onLog?.call('registration cancelled (session changed)');
    return false;
  }
}
