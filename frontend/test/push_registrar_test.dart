// Unit tests for PushRegistrar (multi-user token registration logic).
// Run:  flutter test test/push_registrar_test.dart
//
// No Firebase, network or real timers: every dependency is injected and
// "delays" are recorded instead of waited.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/push_registrar.dart';

class Harness {
  String? session = 'jwt-A';
  String? token = 'tok-1';
  String device = 'device-aaaaaaaa';
  final List<RegisterStatus> script = [];
  final List<({String token, String device, String? session})> calls = [];
  final List<Duration> delays = [];
  Completer<void>? holdDelay; // when set, delays block until completed
  Future<void> Function(Duration)? onDelay;

  late final PushRegistrar r = PushRegistrar(
    fetchToken: () async => token,
    register: (t, d) async {
      calls.add((token: t, device: d, session: session));
      return script.isEmpty ? RegisterStatus.success : script.removeAt(0);
    },
    deviceId: () async => device,
    sessionId: () async => session,
    delay: (d) async {
      delays.add(d);
      if (onDelay != null) await onDelay!(d);
      if (holdDelay != null) await holdDelay!.future;
    },
    random: Random(1),
  );
}

void main() {
  group('classify', () {
    test('2xx is success', () {
      expect(PushRegistrar.classify(200, true), RegisterStatus.success);
    });
    test('offline, timeout, throttling and 5xx are retryable', () {
      for (final c in [0, 408, 429, 500, 502, 503, 504]) {
        expect(PushRegistrar.classify(c, false), RegisterStatus.retry,
            reason: '$c');
      }
    });
    test('other 4xx are fatal (never hammer the server)', () {
      for (final c in [400, 401, 403, 404, 422]) {
        expect(PushRegistrar.classify(c, false), RegisterStatus.fatal,
            reason: '$c');
      }
    });
  });

  group('backoff', () {
    test('doubles from 2s and is capped at 60s', () {
      final h = Harness();
      final secs = [for (var i = 0; i < 8; i++) h.r.nominalBackoff(i).inSeconds];
      expect(secs, [2, 4, 8, 16, 32, 60, 60, 60]);
    });
    test('jitter stays under 250ms', () {
      final h = Harness();
      for (var i = 0; i < 20; i++) {
        final extra = h.r.backoffFor(2) - h.r.nominalBackoff(2);
        expect(extra.inMilliseconds, inInclusiveRange(0, 249));
      }
    });
    test('default schedule outlasts a Render cold start (>= 60s of waiting)', () {
      final h = Harness();
      final total = [for (var i = 0; i < h.r.maxAttempts - 1; i++)
        h.r.nominalBackoff(i)].fold<Duration>(Duration.zero, (a, b) => a + b);
      expect(total.inSeconds, greaterThanOrEqualTo(60));
    });
  });

  group('registration', () {
    test('registers once with the persistent device id', () async {
      final h = Harness();
      expect(await h.r.sync(), isTrue);
      expect(h.calls.length, 1);
      expect(h.calls.single.device, 'device-aaaaaaaa');
      expect(h.r.isRegistered, isTrue);
    });

    test('is idempotent within a session', () async {
      final h = Harness();
      await h.r.sync();
      await h.r.sync();
      expect(h.calls.length, 1);
    });

    test('concurrent syncs share one in-flight attempt', () async {
      final h = Harness();
      final results = await Future.wait([h.r.sync(), h.r.sync(), h.r.sync()]);
      expect(results, [true, true, true]);
      expect(h.calls.length, 1);
    });

    test('does nothing (and does not retry) when signed out', () async {
      final h = Harness()..session = null;
      expect(await h.r.sync(), isFalse);
      expect(h.calls, isEmpty);
      expect(h.delays, isEmpty);
    });
  });

  group('multi-user: logout -> login without restart (the original bug)', () {
    test('re-registers after reset() even with the same user and token', () async {
      final h = Harness();
      await h.r.sync();
      h.r.reset(); // logout / login
      expect(h.r.isRegistered, isFalse);
      await h.r.sync();
      expect(h.calls.length, 2);
    });

    test('account switch registers under the NEW session', () async {
      final h = Harness();
      await h.r.sync();
      h.session = 'jwt-B';
      h.r.reset();
      await h.r.sync();
      expect(h.calls.map((c) => c.session), ['jwt-A', 'jwt-B']);
    });

    test('a retry loop from the old session is cancelled by reset()', () async {
      final h = Harness();
      h.script.add(RegisterStatus.retry); // A's first attempt fails
      final gate = Completer<void>();
      h.holdDelay = gate; // A is now waiting to retry

      final aFlight = h.r.sync();
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.length, 1);

      h.session = 'jwt-B'; // user switches while A is backing off
      h.r.reset();
      h.holdDelay = null;
      final bFlight = h.r.sync();
      gate.complete(); // A's backoff finishes — it must NOT register again

      expect(await bFlight, isTrue);
      expect(await aFlight, isFalse);
      expect(h.calls.map((c) => c.session), ['jwt-A', 'jwt-B']);
    });

    test('a request in flight during logout is not recorded as registered', () async {
      final finish = Completer<RegisterStatus>();
      final r = PushRegistrar(
        fetchToken: () async => 'tok-1',
        register: (t, d) => finish.future,
        deviceId: () async => 'device-aaaaaaaa',
        sessionId: () async => 'jwt-A',
        delay: (_) async {},
      );
      final flight = r.sync();
      await Future<void>.delayed(Duration.zero);
      r.reset(); // logout while the request is on the wire
      finish.complete(RegisterStatus.success);
      expect(await flight, isFalse);
      expect(r.isRegistered, isFalse);
    });
  });

  group('failure handling', () {
    test('retries with growing delays, then succeeds', () async {
      final h = Harness();
      h.script.addAll([RegisterStatus.retry, RegisterStatus.retry]);
      expect(await h.r.sync(), isTrue);
      expect(h.calls.length, 3);
      expect(h.delays.length, 2);
      expect(h.delays[0].inMilliseconds, inInclusiveRange(2000, 2249));
      expect(h.delays[1].inMilliseconds, inInclusiveRange(4000, 4249));
    });

    test('gives up after maxAttempts', () async {
      final h = Harness();
      h.script.addAll(List.filled(20, RegisterStatus.retry));
      expect(await h.r.sync(), isFalse);
      expect(h.calls.length, h.r.maxAttempts);
      expect(h.delays.length, h.r.maxAttempts - 1);
      expect(h.r.isRegistered, isFalse);
    });

    test('a fatal response is not retried', () async {
      final h = Harness();
      h.script.add(RegisterStatus.fatal);
      expect(await h.r.sync(), isFalse);
      expect(h.calls.length, 1);
      expect(h.delays, isEmpty);
    });

    test('waits for a token that is not available yet', () async {
      final h = Harness()..token = null;
      var polls = 0;
      h.onDelay = (_) async {
        if (++polls == 2) h.token = 'tok-late';
      };
      expect(await h.r.sync(), isTrue);
      expect(h.calls.single.token, 'tok-late');
    });

    test('failed registration can be retried by a later sync', () async {
      final h = Harness();
      h.script.addAll(List.filled(6, RegisterStatus.retry));
      expect(await h.r.sync(), isFalse);
      expect(await h.r.sync(), isTrue);
    });
  });

  group('token refresh', () {
    test('a rotated token is registered even though the old one was', () async {
      final h = Harness();
      await h.r.sync();
      expect(await h.r.sync(token: 'tok-rotated'), isTrue);
      expect(h.calls.map((c) => c.token), ['tok-1', 'tok-rotated']);
      expect(h.calls.map((c) => c.device).toSet().length, 1); // same device
    });

    test('refresh while signed out registers nothing', () async {
      final h = Harness()..session = null;
      expect(await h.r.sync(token: 'tok-rotated'), isFalse);
      expect(h.calls, isEmpty);
    });
  });
}
