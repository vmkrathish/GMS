// ─────────────────────────────────────────────
// presentation/screens/auth/login_screen.dart
//
// Sign In: phone number OR email (single smart field).
// Success → session saved → Home.
// No account → nudged to Sign Up (prefills identifier).
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';

import '../../../core/api/auth_api.dart';
import '../../../core/theme/app_theme.dart';
import '../../../main.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

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
  bool _serverUnreachable = false;

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
    setState(() {
      _serverError = null;
      _serverUnreachable = false;
    });
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    final res = await AuthApi.login(
        _identifierCtrl.text.trim(), _passwordCtrl.text);
    if (!mounted) return;
    setState(() => _loading = false);

    if (res.success) {
      _goHome();
    } else if (res.isOffline) {
      setState(() {
        _serverUnreachable = true;
        _serverError =
            'Unable to connect. Please check your connection and try again.';
      });
    } else if (res.data is Map && res.data['notRegistered'] == true) {
      // Friendly redirect to signup with the identifier pre-filled
      _showSnack('No account found — let\'s create one!');
      _goSignup(prefill: _identifierCtrl.text.trim());
    } else {
      setState(() => _serverError = res.message);
    }
  }

  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const GMSMainPage()),
      (route) => false,
    );
  }

  void _goSignup({String? prefill}) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SignupScreen(prefillIdentifier: prefill)),
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
              _header(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
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

                      if (_serverError != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(_serverError!,
                              style: TextStyle(
                                  color: Colors.red.shade700, fontSize: 13)),
                        ),
                      ],

                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
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

                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
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

                      // Dev helper: only shows when backend is unreachable,
                      // so UI flows can still be demoed before MySQL is
                      // connected. Remove before production.
                      if (_serverUnreachable) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton.icon(
                            icon: const Icon(Icons.bug_report_outlined,
                                size: 18),
                            label: const Text(
                                'Continue in demo mode (dev only)'),
                            onPressed: () async {
                              // Local-only fake session for UI testing.
                              await AuthApi.logout();
                              if (!context.mounted) return;
                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(
                                    builder: (_) => const GMSMainPage()),
                                (route) => false,
                              );
                            },
                          ),
                        ),
                      ],
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

  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: const BoxDecoration(
        gradient: AppTheme.gmsGradient,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(36),
          bottomRight: Radius.circular(36),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 14,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: Image.asset('assets/images/gms_logo.png', height: 56),
          ),
          const SizedBox(height: 14),
          const Text('Get My Service',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Any service. Any time. One app.',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}
