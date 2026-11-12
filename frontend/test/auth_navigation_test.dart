// Run with:  flutter test test/auth_navigation_test.dart
//
// Real auth screens + real AuthApi/ApiService/SessionManager, with the
// HTTP layer replaced by a MockClient (package:http's runWithClient), so
// nothing reaches a server and no real account is used.
//   • no saved session: Intro → Sign In
//   • Sign In success → main app (GMSMainPage); session token saved
//   • Sign In wrong password → stays on Sign In with the server's message
//   • unknown account → Sign Up (identifier carried over)
//   • Sign Up email flow success → main app; failure stays with message;
//     back navigation keeps what was typed
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:GMS/core/services/booking_badge_service.dart';
import 'package:GMS/core/services/chat_badge_service.dart';
import 'package:GMS/main.dart';
import 'package:GMS/presentation/screens/auth/login_screen.dart';
import 'package:GMS/presentation/screens/auth/signup_screen.dart';
import 'package:GMS/presentation/screens/intro_screen.dart';

const _user = {
  'id': 7,
  'name': 'Test User',
  'phone': '9876543210',
  'email': 'test.user@example.test',
  'role': 'customer',
};

/// Fake API: login/signup as configured, everything else an empty success.
class FakeApi {
  int loginStatus = 200;
  int signupStatus = 201;
  Map<String, dynamic>? loginBody;
  Map<String, dynamic>? signupBody;
  final requests = <String>[];

  Future<http.Response> handle(http.Request r) async {
    requests.add('${r.method} ${r.url.path}');
    final p = r.url.path;
    if (r.method == 'POST' && p.endsWith('/auth/login')) {
      final ok = loginStatus == 200;
      return http.Response(
          jsonEncode(loginBody ??
              (ok
                  ? {'success': true, 'token': 'test-token', 'user': _user}
                  : {'success': false, 'message': 'Incorrect password.'})),
          loginStatus,
          headers: {'content-type': 'application/json'});
    }
    if (r.method == 'POST' && p.endsWith('/auth/signup')) {
      final ok = signupStatus == 201 || signupStatus == 200;
      return http.Response(
          jsonEncode(signupBody ??
              (ok
                  ? {'success': true, 'isNewUser': true, 'token': 'test-token', 'user': _user}
                  : {'success': false, 'message': 'This phone number is already registered.'})),
          signupStatus,
          headers: {'content-type': 'application/json'});
    }
    return http.Response(jsonEncode({'success': true}), 200,
        headers: {'content-type': 'application/json'});
  }
}

Future<void> _run(WidgetTester t, FakeApi api, Future<void> Function() body) async {
  // Wide logical window: the main app's own header/home rows overflow
  // with the square test font at phone width (not part of this task).
  t.view.physicalSize = const Size(1400, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await http.runWithClient(body, () => MockClient(api.handle));
}

/// Leave no app timers/pollers running after a test that reached the app.
Future<void> _teardownApp(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  BookingBadgeService.stopPolling();
  ChatBadgeService.stopPolling();
  // The home ad slider schedules a one-shot 4 s timer; let it run out.
  await t.pump(const Duration(seconds: 5));
}

Future<void> _settle(WidgetTester t, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('no saved session: Intro → Sign In', (t) async {
    final api = FakeApi();
    await _run(t, api, () async {
      await t.pumpWidget(const MaterialApp(home: IntroScreen()));
      await t.pump(const Duration(seconds: 3));
      await _settle(t);
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  testWidgets('Sign In success → main app, session saved', (t) async {
    final api = FakeApi();
    await _run(t, api, () async {
      await t.pumpWidget(const MaterialApp(home: LoginScreen()));
      await _settle(t, frames: 3);
      await t.enterText(find.byType(TextFormField).at(0), '9876543210');
      await t.enterText(find.byType(TextFormField).at(1), 'secret-pw');
      await t.tap(find.byKey(const ValueKey('signin-button')));
      await _settle(t);
      expect(api.requests, contains('POST /api/auth/login'));
      expect(find.byType(GMSMainPage), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gms_jwt'), 'test-token');
      await _teardownApp(t);
    });
  });

  testWidgets('wrong password → stays on Sign In with the message', (t) async {
    final api = FakeApi()..loginStatus = 401;
    await _run(t, api, () async {
      await t.pumpWidget(const MaterialApp(home: LoginScreen()));
      await _settle(t, frames: 3);
      await t.enterText(find.byType(TextFormField).at(0), 'test.user@example.test');
      await t.enterText(find.byType(TextFormField).at(1), 'wrong');
      await t.tap(find.byKey(const ValueKey('signin-button')));
      await _settle(t);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.byType(GMSMainPage), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gms_jwt'), isNull);
    });
  });

  testWidgets('unknown account → Sign Up with the phone carried over', (t) async {
    final api = FakeApi()
      ..loginStatus = 404
      ..loginBody = {'success': false, 'message': 'No account found.', 'notRegistered': true};
    await _run(t, api, () async {
      await t.pumpWidget(const MaterialApp(home: LoginScreen()));
      await _settle(t, frames: 3);
      await t.enterText(find.byType(TextFormField).at(0), '9123456780');
      await t.enterText(find.byType(TextFormField).at(1), 'x');
      await t.tap(find.byKey(const ValueKey('signin-button')));
      await _settle(t);
      expect(find.byType(SignupScreen), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('signup-email-button')));
      await _settle(t);
      expect(find.text('9123456780'), findsOneWidget);
    });
  });

  Future<void> fillSignup(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('signup-email-button')));
    await _settle(t);
    await t.enterText(find.byKey(const ValueKey('signup-name')), 'Test User');
    await t.enterText(find.byKey(const ValueKey('signup-phone')), '9876543210');
    await t.enterText(find.byKey(const ValueKey('signup-email')), 'test.user@example.test');
    await t.tap(find.byKey(const ValueKey('signup-next')));
    await _settle(t);
    await t.enterText(find.byKey(const ValueKey('signup-password')), 'abcd');
    await t.enterText(find.byKey(const ValueKey('signup-confirm')), 'abcd');
  }

  testWidgets('Sign Up (email) success → main app', (t) async {
    final api = FakeApi();
    await _run(t, api, () async {
      await t.pumpWidget(const MaterialApp(home: LoginScreen()));
      await _settle(t, frames: 3);
      await t.tap(find.text('Create an account'));
      await _settle(t);
      await fillSignup(t);
      await t.tap(find.byKey(const ValueKey('signup-create')));
      await _settle(t);
      expect(api.requests, contains('POST /api/auth/signup'));
      expect(find.byType(GMSMainPage), findsOneWidget);
      expect(find.byType(SignupPasswordScreen), findsNothing);
      await _teardownApp(t);
    });
  });

  testWidgets('Sign Up failure stays on the password step; back keeps details', (t) async {
    final api = FakeApi()..signupStatus = 409;
    await _run(t, api, () async {
      await t.pumpWidget(const MaterialApp(home: SignupScreen()));
      await _settle(t, frames: 3);
      await fillSignup(t);
      await t.tap(find.byKey(const ValueKey('signup-create')));
      await _settle(t);
      expect(find.byType(SignupPasswordScreen), findsOneWidget);
      expect(find.text('This phone number is already registered.'), findsOneWidget);
      // back to the details step: what was typed is still there
      await t.tap(find.byTooltip('Back'));
      await _settle(t);
      expect(find.byType(SignupDetailsScreen), findsOneWidget);
      expect(find.text('9876543210'), findsOneWidget);
      expect(find.text('Test User'), findsOneWidget);
    });
  });
}
