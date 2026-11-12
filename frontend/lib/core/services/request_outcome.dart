// ─────────────────────────────────────────────
// core/services/request_outcome.dart
//
// Pure-Dart rules (no Flutter imports, unit-tested in
// test/request_outcome_test.dart) for two decisions:
//
//  1. What a failed login/sign-up should tell the person, and whether
//     a "Try again" button makes sense. A network problem, timeout or
//     server error is ALWAYS shown as an error with a retry — never as
//     a way into the app without signing in (the old "demo mode"
//     fallback was removed in app 1.0.1).
//
//  2. Whether a 401 response means the saved session is no longer
//     valid (expired / revoked token → back to Sign In), as opposed to
//     an endpoint that uses 401 for "wrong password".
// ─────────────────────────────────────────────
import '../config/api_endpoints.dart';

enum RequestProblem {
  /// Request succeeded.
  none,

  /// No network / DNS / connection refused / CORS — nothing came back.
  offline,

  /// Sent, but no answer in time (e.g. a sleeping server still waking).
  timeout,

  /// The server answered with a 5xx (crashed, restarting, overloaded).
  server,

  /// The server answered and said no (wrong password, invalid input…).
  rejected,
}

class RequestOutcome {
  static RequestProblem classify({
    required bool success,
    required int statusCode,
    bool timedOut = false,
  }) {
    if (success) return RequestProblem.none;
    if (statusCode == 0) {
      return timedOut ? RequestProblem.timeout : RequestProblem.offline;
    }
    if (statusCode >= 500) return RequestProblem.server;
    return RequestProblem.rejected;
  }

  /// Retrying only helps when the problem was on the way to/at the server.
  static bool isRetryable(RequestProblem p) =>
      p == RequestProblem.offline ||
      p == RequestProblem.timeout ||
      p == RequestProblem.server;

  /// User-facing text for a failure. [serverMessage] is used as-is for
  /// [RequestProblem.rejected] (it's the backend's own explanation,
  /// e.g. "Incorrect password.").
  static String message(RequestProblem p, {String serverMessage = ''}) {
    switch (p) {
      case RequestProblem.offline:
        return "Can't reach the GMS server. Check your internet "
            'connection and try again.';
      case RequestProblem.timeout:
        return 'The server is taking too long to respond — it may be '
            'starting up. Please try again in a few seconds.';
      case RequestProblem.server:
        // A specific server explanation (e.g. the 503 "database is
        // unavailable") beats the generic text; FastAPI's bare
        // "Server error." does not.
        return serverMessage.isNotEmpty && serverMessage != 'Server error.'
            ? serverMessage
            : 'The GMS server ran into a problem. Please try again in '
                'a moment.';
      case RequestProblem.rejected:
        return serverMessage.isNotEmpty
            ? serverMessage
            : 'Something went wrong. Please check your details and try again.';
      case RequestProblem.none:
        return '';
    }
  }

  /// Endpoints where 401 is an answer about the CREDENTIALS just sent
  /// (wrong password), not about the saved session.
  static const Set<String> credentialEndpoints = {
    ApiEndpoints.login,
    ApiEndpoints.signup,
    ApiEndpoints.register,
    ApiEndpoints.verifyOtp,
    ApiEndpoints.changePassword,
    ApiEndpoints.verifyPassword,
  };

  /// True when a response proves the session's token is no longer
  /// accepted: a 401 to a request that actually carried a token, from an
  /// endpoint that doesn't use 401 for wrong credentials.
  static bool endsSession({
    required int statusCode,
    required bool sentToken,
    required String endpoint,
  }) =>
      statusCode == 401 &&
      sentToken &&
      !credentialEndpoints.contains(endpoint);
}
