// Unit tests for the pure-Dart login/session rules (no Flutter widgets).
// Run with:  flutter test test/request_outcome_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/config/api_endpoints.dart';
import 'package:GMS/core/services/request_outcome.dart';

void main() {
  group('classify', () {
    test('success is none', () {
      expect(RequestOutcome.classify(success: true, statusCode: 200),
          RequestProblem.none);
    });
    test('status 0 is offline, or timeout when flagged', () {
      expect(RequestOutcome.classify(success: false, statusCode: 0),
          RequestProblem.offline);
      expect(
          RequestOutcome.classify(
              success: false, statusCode: 0, timedOut: true),
          RequestProblem.timeout);
    });
    test('5xx is server, 4xx is rejected', () {
      for (final c in [500, 502, 503, 504]) {
        expect(RequestOutcome.classify(success: false, statusCode: c),
            RequestProblem.server);
      }
      for (final c in [400, 401, 404, 422]) {
        expect(RequestOutcome.classify(success: false, statusCode: c),
            RequestProblem.rejected);
      }
    });
    test('2xx with success:false body is rejected, not none', () {
      expect(RequestOutcome.classify(success: false, statusCode: 200),
          RequestProblem.rejected);
    });
  });

  group('retry + messages', () {
    test('only connection/server problems are retryable', () {
      expect(RequestOutcome.isRetryable(RequestProblem.offline), isTrue);
      expect(RequestOutcome.isRetryable(RequestProblem.timeout), isTrue);
      expect(RequestOutcome.isRetryable(RequestProblem.server), isTrue);
      expect(RequestOutcome.isRetryable(RequestProblem.rejected), isFalse);
      expect(RequestOutcome.isRetryable(RequestProblem.none), isFalse);
    });
    test('rejected shows the server message; others never mention demo', () {
      expect(
          RequestOutcome.message(RequestProblem.server,
              serverMessage: 'The GMS database is unavailable right now.'),
          'The GMS database is unavailable right now.');
      expect(
          RequestOutcome.message(RequestProblem.server,
                  serverMessage: 'Server error.')
              .startsWith('The GMS server ran into a problem'),
          isTrue);
      expect(
          RequestOutcome.message(RequestProblem.rejected,
              serverMessage: 'Incorrect password.'),
          'Incorrect password.');
      for (final p in RequestProblem.values) {
        expect(RequestOutcome.message(p).toLowerCase().contains('demo'),
            isFalse);
      }
      expect(RequestOutcome.message(RequestProblem.offline).isNotEmpty, isTrue);
      expect(RequestOutcome.message(RequestProblem.rejected).isNotEmpty, isTrue);
    });
  });

  group('endsSession', () {
    test('401 with a token on a normal endpoint ends the session', () {
      expect(
          RequestOutcome.endsSession(
              statusCode: 401, sentToken: true, endpoint: '/users/me'),
          isTrue);
    });
    test('wrong-password 401s on credential endpoints do not', () {
      for (final e in [
        ApiEndpoints.login,
        ApiEndpoints.signup,
        ApiEndpoints.changePassword,
        ApiEndpoints.verifyPassword,
      ]) {
        expect(
            RequestOutcome.endsSession(
                statusCode: 401, sentToken: true, endpoint: e),
            isFalse);
      }
    });
    test('no token, or not 401, never ends the session', () {
      expect(
          RequestOutcome.endsSession(
              statusCode: 401, sentToken: false, endpoint: '/users/me'),
          isFalse);
      for (final c in [200, 403, 500, 0]) {
        expect(
            RequestOutcome.endsSession(
                statusCode: c, sentToken: true, endpoint: '/users/me'),
            isFalse);
      }
    });
  });
}
