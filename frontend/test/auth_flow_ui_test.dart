// Run with:  flutter test test/auth_flow_ui_test.dart
// Sign In / Sign Up screens: content, navigation between them, field
// validation and password rules. No network: the screens' warm-up call
// fails silently in tests, and nothing here submits to the server.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/presentation/screens/auth/login_screen.dart';
import 'package:GMS/presentation/screens/auth/signup_screen.dart';

Future<void> _pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: home));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Sign In shows every element of the design', (t) async {
    await _pump(t, const LoginScreen());
    expect(find.text('Get My Service'), findsOneWidget);       // GMS header
    expect(find.text('Welcome back 👋'), findsOneWidget);
    expect(find.text('Phone number or email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.byKey(const ValueKey('forgot-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('signin-button')), findsOneWidget);
    expect(find.text('OR'), findsOneWidget);
    expect(find.byKey(const ValueKey('google-button')), findsOneWidget);
    expect(find.text('Create an account'), findsOneWidget);
  });

  testWidgets('password show/hide toggles', (t) async {
    await _pump(t, const LoginScreen());
    final field = find.byType(EditableText).at(1);
    expect(t.widget<EditableText>(field).obscureText, isTrue);
    await t.tap(find.byIcon(Icons.visibility_outlined));
    await t.pump();
    expect(t.widget<EditableText>(field).obscureText, isFalse);
  });

  testWidgets('Google and Forgot password are UI only (no sign-in)', (t) async {
    await _pump(t, const LoginScreen());
    await t.tap(find.byKey(const ValueKey('google-button')));
    await t.pump();
    expect(find.textContaining("isn't available yet"), findsOneWidget);
    expect(find.text('Coming soon'), findsNWidgets(2)); // Google + Forgot password tags
    await t.tap(find.byKey(const ValueKey('forgot-password')));
    await t.pumpAndSettle();
    expect(find.text('Forgot password?'), findsWidgets);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
  });

  testWidgets('Sign In → Create an account → Sign In (back)', (t) async {
    await _pump(t, const LoginScreen());
    await t.ensureVisible(find.text('Create an account')); // below the fold on a phone
    await t.tap(find.text('Create an account'));
    await t.pumpAndSettle();
    expect(find.byType(SignupScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('signup-email-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('google-button')), findsOneWidget);
    await t.tap(find.text('Sign In'));
    await t.pumpAndSettle();
    expect(find.byType(SignupScreen), findsNothing);
    expect(find.text('Welcome back 👋'), findsOneWidget);
  });

  testWidgets('Sign up with Email → details → password screen', (t) async {
    await _pump(t, const SignupScreen(prefillIdentifier: '9876543210'));
    await t.tap(find.byKey(const ValueKey('signup-email-button')));
    await t.pumpAndSettle();
    expect(find.byType(SignupDetailsScreen), findsOneWidget);
    // phone prefilled from Sign In
    expect(find.text('9876543210'), findsOneWidget);

    // empty → stays, shows validation
    await t.tap(find.byKey(const ValueKey('signup-next')));
    await t.pumpAndSettle();
    expect(find.text('Enter your name'), findsOneWidget);
    expect(find.byType(SignupPasswordScreen), findsNothing);

    await t.enterText(find.byKey(const ValueKey('signup-name')), 'Priya Raman');
    await t.enterText(find.byKey(const ValueKey('signup-email')), 'priya@example.com');
    await t.tap(find.byKey(const ValueKey('signup-next')));
    await t.pumpAndSettle();
    expect(find.byType(SignupPasswordScreen), findsOneWidget);
    expect(find.text('Create Password'), findsOneWidget);
    expect(find.byKey(const ValueKey('signup-create')), findsOneWidget);
  });

  testWidgets('password rules: length and match, checked before submit', (t) async {
    await _pump(t, const SignupPasswordScreen(
        name: 'Priya Raman', phone: '9876543210', email: 'priya@example.com'));
    Icon ruleIcon(String text) => t.widget<Icon>(find.descendant(
        of: find.ancestor(of: find.text(text), matching: find.byType(Row)).first,
        matching: find.byType(Icon)));
    expect(ruleIcon('At least 4 characters').icon, Icons.radio_button_unchecked);

    await t.enterText(find.byKey(const ValueKey('signup-password')), 'abcd');
    await t.enterText(find.byKey(const ValueKey('signup-confirm')), 'abce');
    await t.pump();
    expect(ruleIcon('At least 4 characters').icon, Icons.check_circle);
    expect(ruleIcon('Passwords must match').icon, Icons.radio_button_unchecked);

    // mismatch → validation error, no request sent (no spinner)
    await t.tap(find.byKey(const ValueKey('signup-create')));
    await t.pump();
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await t.enterText(find.byKey(const ValueKey('signup-confirm')), 'abcd');
    await t.pump();
    expect(ruleIcon('Passwords must match').icon, Icons.check_circle);
  });

  testWidgets('layout stays within 480 px on a wide web window', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: LoginScreen()));
    await t.pumpAndSettle();
    final w = t.getSize(find.byKey(const ValueKey('signin-button'))).width;
    expect(w, lessThanOrEqualTo(480));
  });
}
