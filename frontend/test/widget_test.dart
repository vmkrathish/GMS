// App smoke test (replaces the Flutter template "Counter increments"
// test, which never matched GMS — the app has no counter — and always
// failed). Starts the real GMSApp with no saved session and a mocked HTTP
// layer: the intro screen hands over to Sign In.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:GMS/main.dart';
import 'package:GMS/presentation/screens/auth/login_screen.dart';

void main() {
  testWidgets('GMSApp starts and, without a session, shows Sign In',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(const GMSApp());
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Welcome back 👋'), findsOneWidget);
    }, () => MockClient((_) async => http.Response(jsonEncode({'success': true}), 200)));
  });
}
