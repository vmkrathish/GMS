// ─────────────────────────────────────────────
// presentation/screens/auth/login_screen.dart
//
// Sign In: phone number OR email (single smart field).
// Success → session saved → Home.
// No account → nudged to Sign Up (prefills identifier).
// Network / server failure → error message + "Try again". There is
// deliberately NO way into the app without signing in (the old
// "Continue in demo mode" fallback was removed in app 1.0.1).
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';

import '../../../core/api/auth_api.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/request_outcome.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/connection_error_banner.dart';
import '../../../core/services/fcm_service.dart';
import '../../../main.dart';
import 'auth_widgets.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  /// Optional one-line explanation shown above the form, e.g. when the
  /// app returned here because the saved session expired.
  final String? notice;

  const LoginScreen({super.key, this.notice});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePassword = true;

  bool _loading = false;
  String? _serverError;
  bool _canRetry = false; // connection / timeout / server error only

  @override
  void initState() {
    super.initState();
    // Wake the server (and its DB connections) while the person types.
    ApiService.warmUp();
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  bool _looksLikePhone(String v) =>
      RegExp(r'^\+?[0-9\s-]{10,15}$').hasMatch(v.trim());
  bool _looksLikeEmail(String v) => RegExp(
          r'^[a-zA-Z0-9.\_%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$')
      .hasMatch(v.trim());

  Future<void> _signIn() async {
    // The keyboard's Done key also calls this — ignore it while a
    // request is already running instead of sending a second login.
    if (_loading) return;
    setState(() {
      _serverError = null;
      _canRetry = false;
    });
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    final res = await AuthApi.login(
        _identifierCtrl.text.trim(), _passwordCtrl.text);
    if (!mounted) return;
    setState(() => _loading = false);

    final problem = res.problem;
    if (res.success) {
      // Only here — a real, successful sign-in (never app start with a
      // saved session): ask for the FCM "Welcome back to GMS" push, sent
      // to this device once its push token is registered.
      FcmService().welcomeAfterNextRegistration();
      _goHome();
    } else if (problem == RequestProblem.rejected &&
        res.data is Map &&
        res.data['notRegistered'] == true) {
      // Friendly redirect to signup with the identifier pre-filled
      _showSnack('No account found — let\'s create one!');
      _goSignup(prefill: _identifierCtrl.text.trim());
    } else {
      // Network down, timeout, 5xx → explain + offer "Try again".
      // Wrong password / invalid input → the server's own message.
      setState(() {
        _canRetry = RequestOutcome.isRetryable(problem);
        _serverError =
            RequestOutcome.message(problem, serverMessage: res.message);
      });
      if (_canRetry) ApiService.warmUp();
    }
  }

  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const GMSMainPage()),
      (route) => false,
    );
  }

  void _goSignup({String? prefill}) {
    Navigator.of(context)
        .push(authRoute(SignupScreen(prefillIdentifier: prefill)));
  }

  /// UI only in this phase — no reset flow exists in the backend yet.
  void _forgotPassword() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Password reset isn\'t available yet'),
        content: const Text(
            'Resetting your password from the app is coming soon. For now, '
            'please contact GMS support to reset it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const AuthHeader(),
              AuthBody(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Welcome back 👋',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      const Text('Sign in to book or provide services',
                          style: TextStyle(color: Colors.black54)),
                      if (widget.notice != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(widget.notice!,
                              style: TextStyle(
                                  color: Colors.brown.shade700, fontSize: 13)),
                        ),
                      ],
                      const SizedBox(height: 28),

                      const Text('Phone number or email',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _identifierCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _signIn(),
                        decoration: const InputDecoration(
                          hintText: '98765 43210  or  you@email.com',
                          prefixIcon: Icon(Icons.person_outline,
                              color: AppTheme.primaryBlue),
                        ),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (t.isEmpty) {
                            return 'Enter your phone number or email';
                          }
                          if (!_looksLikePhone(t) && !_looksLikeEmail(t)) {
                            return 'Enter a valid phone number or email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),

                      const Text('Password',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _signIn(),
                        decoration: InputDecoration(
                          hintText: 'Enter your password',
                          prefixIcon: const Icon(Icons.lock_outline,
                              color: AppTheme.primaryBlue),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: Colors.black45,
                            ),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (v) {
                          if ((v ?? '').isEmpty) return 'Enter your password';
                          return null;
                        },
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('forgot-password'),
                          onPressed: _forgotPassword,
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.black45),
                          // Placeholder: clearly marked as not working yet.
                          child: const Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('Forgot password?',
                                  style: TextStyle(fontWeight: FontWeight.w600)),
                              SoonTag(),
                            ],
                          ),
                        ),
                      ),

                      if (_serverError != null) ...[
                        const SizedBox(height: 14),
                        ConnectionErrorBanner(
                          message: _serverError!,
                          onRetry: _canRetry && !_loading ? _signIn : null,
                        ),
                      ],

                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          key: const ValueKey('signin-button'),
                          onPressed: _loading ? null : _signIn,
                          child: _loading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5, color: Colors.white))
                              : const Text('Sign In',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),

                      const OrDivider(),
                      const GoogleButton(),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('New to GMS?',
                              style: TextStyle(color: Colors.black54)),
                          TextButton(
                            onPressed: () => _goSignup(),
                            child: const Text('Create an account',
                                style:
                                    TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),

                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
